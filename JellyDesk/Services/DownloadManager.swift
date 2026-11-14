import Foundation

/// Lädt Titel in die Offline-Mediathek: höchstens zwei gleichzeitig, davon höchstens
/// eine vom Server umgerechnete Fassung; der Rest wartet in der Schlange.
@MainActor
final class DownloadManager: ObservableObject {
    struct Progress: Equatable {
        var received: Int64
        /// Erwartete Gesamtgröße; bei umgerechneten Fassungen die Schätzung des Themes.
        var expected: Int64
        var fraction: Double
        /// true: `expected` ist nur geschätzt (kein Content-Length).
        var isEstimate: Bool
    }

    static let maxConcurrent = 2
    static let maxConcurrentTranscodes = 1
    private static let maxAutomaticRetries = 3

    @Published private(set) var progress: [String: Progress] = [:]
    /// Eingegangene Downloads, die auf eine Bestätigung warten (Einstellung „immer nachfragen“
    /// oder Qualität weicht vom Standard ab).
    @Published var pendingConfirmation: [DownloadRequest] = []

    private let store: OfflineStore
    private let credentials: CredentialStore
    private let keychain: KeychainStore
    private let notices: Notices
    /// Hält Einstellungen und Videos von „Local Intros“ bereit; wird von AppServices gesetzt.
    var introLibrary: IntroLibrary?
    /// Für die Vorschaubilder der Zeitleiste; wird von AppServices gesetzt.
    var api: JellyfinAPIService?
    private var trickplayRunning: Set<String> = []

    private let sessionDelegate = DownloadSessionDelegate()
    private var session: URLSession!
    private var artworkSession: URLSession!

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var attempts: [String: Int] = [:]
    private var notBefore: [String: Date] = [:]
    private var failedOffline: Set<String> = []

    init(store: OfflineStore, credentials: CredentialStore, keychain: KeychainStore, notices: Notices) {
        self.store = store
        self.credentials = credentials
        self.keychain = keychain
        self.notices = notices

        // Kein Cache, keine Cookies, keine gespeicherten Anmeldedaten: die Adressen
        // enthalten das Token und sollen in keiner Cache-Datenbank landen.
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.httpMaximumConnectionsPerHost = Self.maxConcurrent
        config.timeoutIntervalForRequest = 120            // Leerlauf; der Server braucht beim Umrechnen Anlauf
        config.timeoutIntervalForResource = 7 * 24 * 3600 // große Dateien über langsame Leitungen
        config.waitsForConnectivity = false

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "JellyDesk.Downloads"
        session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: queue)

        let artworkConfig = URLSessionConfiguration.ephemeral
        artworkConfig.timeoutIntervalForRequest = 30
        artworkSession = URLSession(configuration: artworkConfig)

        sessionDelegate.onEvent = { [weak self] event in
            // DispatchQueue statt Task, damit die Reihenfolge der Ereignisse erhalten bleibt.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    // MARK: Eingang von der Weboberfläche

    /// Nimmt eine Nachricht der Brücke an. Die Qualität hat der Nutzer in der Weboberfläche
    /// gewählt; die App lädt genau die übergebene Adresse. Die Einstellungen entscheiden nur,
    /// ob vorher noch einmal nachgefragt wird.
    func receive(_ request: DownloadRequest) {
        let defaults = UserDefaults.standard
        let alwaysAsk = defaults.bool(forKey: SettingsKeys.alwaysAsk)
        let defaultQuality = defaults.string(forKey: SettingsKeys.defaultQuality) ?? "orig"
        // Schon vorhandene Titel brauchen keine Rückfrage; enqueue meldet oder setzt sie fort.
        if existingItem(for: request) == nil, alwaysAsk || request.quality != defaultQuality {
            pendingConfirmation.append(request)
        } else {
            enqueue(request)
        }
    }

    /// Derselbe Titel in derselben Qualität vom selben Server.
    private func existingItem(for request: DownloadRequest) -> OfflineItem? {
        store.items.first {
            $0.itemId == request.itemId && $0.quality == request.quality
                && $0.serverUrl.hasSameOrigin(as: request.serverUrl)
        }
    }

    func confirmPending() {
        let requests = pendingConfirmation
        pendingConfirmation = []
        requests.forEach(enqueue)
    }

    func discardPending() {
        pendingConfirmation = []
    }

    func enqueue(_ request: DownloadRequest) {
        // Zugangsdaten immer auffrischen, auch wenn der Titel schon da ist.
        let ref = credentials.upsert(serverId: request.serverId, serverUrl: request.serverUrl,
                                     userId: request.userId, accessToken: request.accessToken)

        if let existing = existingItem(for: request) {
            switch existing.state {
            case .completed:
                notices.post("„\(existing.displayTitle)“ ist in dieser Qualität schon geladen.")
            case .queued, .downloading:
                break
            case .paused, .failed:
                // Neue Adresse übernehmen (frisches Token, neue Sitzungskennung) und weitermachen.
                store.update(existing.id) {
                    $0.credentialRef = ref
                    $0.urlTemplate = TokenTemplate.redact(request.url.absoluteString, token: request.accessToken)
                }
                resume(existing.id)
            }
            return
        }

        let id = UUID().uuidString
        let item = OfflineItem(
            id: id,
            itemId: request.itemId,
            itemType: request.itemType,
            serverId: request.serverId,
            serverUrl: request.serverUrl,
            credentialRef: ref,
            title: request.title,
            filename: request.filename,
            relativePath: uniqueRelativePath(for: request),
            seriesName: request.seriesName,
            seasonNumber: request.seasonNumber,
            episodeNumber: request.episodeNumber,
            year: request.year,
            runTimeTicks: request.runTimeTicks,
            quality: request.quality,
            estimatedBytes: request.estimatedBytes,
            container: request.container,
            urlTemplate: TokenTemplate.redact(request.url.absoluteString, token: request.accessToken),
            imageUrlTemplate: request.imageUrl.map { TokenTemplate.redact($0.absoluteString, token: request.accessToken) },
            backdropUrlTemplate: request.backdropUrl.map { TokenTemplate.redact($0.absoluteString, token: request.accessToken) },
            state: .queued,
            addedAt: Date(),
            positionTicks: request.positionTicks,
            positionUpdatedAt: nil
        )
        store.add(item)
        fetchArtwork(for: id)
        fetchTrickplay(for: id)
        if let introLibrary { Task { await introLibrary.prepare(itemID: id) } }
        schedule()
    }

    private func uniqueRelativePath(for request: DownloadRequest) -> String {
        let name = FileNameSanitizer.component(request.filename, isFileName: true)
        let directory: String
        if request.isEpisode || !request.seriesName.isEmpty {
            let series = FileNameSanitizer.component(request.seriesName, fallback: "Unbekannte Serie")
            let season = request.seasonNumber.map { String(format: "Staffel %02d", $0) } ?? "Ohne Staffel"
            directory = "Serien/\(series)/\(season)"
        } else {
            let folder = request.year.map { "\(request.title) (\($0))" } ?? request.title
            directory = "Filme/\(FileNameSanitizer.component(folder))"
        }

        let taken = Set(store.items.map(\.relativePath))
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = "\(directory)/\(name)"
        var counter = 2
        while taken.contains(candidate)
                || FileManager.default.fileExists(atPath: AppPaths.offlineMedia.appendingPathComponent(candidate).path) {
            candidate = "\(directory)/\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: Schlange

    /// Startet wartende Downloads, solange die Grenzen es erlauben.
    func schedule() {
        var running = store.items.filter { $0.state == .downloading }
        let now = Date()
        let waiting = store.items
            .filter { $0.state == .queued }
            .sorted { $0.addedAt < $1.addedAt }

        for item in waiting {
            if running.count >= Self.maxConcurrent { break }
            if let earliest = notBefore[item.id], earliest > now { continue }
            // Umgerechnete Fassungen belasten den Server: nur eine gleichzeitig.
            if !item.isOriginal,
               running.filter({ !$0.isOriginal }).count >= Self.maxConcurrentTranscodes { continue }
            if start(item) {
                running.append(item)
            }
        }
    }

    @discardableResult
    private func start(_ item: OfflineItem) -> Bool {
        guard let credential = credentials.credential(ref: item.credentialRef),
              let url = TokenTemplate.fill(item.urlTemplate, token: credential.accessToken) else {
            fail(item.id, message: "Zugangsdaten fehlen. Den Download in der Weboberfläche erneut anstoßen.")
            return false
        }

        let task: URLSessionDownloadTask
        if item.isOriginal, let resumeData = keychain.data(account: resumeAccount(item.id)) {
            // Fortsetzen über resumeData (Range-Anfrage auf die angefangene Datei).
            task = session.downloadTask(withResumeData: resumeData)
            keychain.delete(account: resumeAccount(item.id))
        } else {
            // Die Adresse bleibt genau die übergebene (mit api_key). Zusätzlich geht das Token in der
            // Authorization-Kopfzeile mit: neuere Server (ohne „Legacy Authorization“) lehnen api_key
            // in der Adresse mit 401 ab.
            var request = URLRequest(url: url)
            request.setValue(JellyfinAuth.header(token: credential.accessToken), forHTTPHeaderField: "Authorization")
            task = session.downloadTask(with: request)
            progress[item.id] = makeProgress(item: item, received: 0, expected: -1)
        }

        sessionDelegate.register(task: task, itemID: item.id, destination: item.fileURL)
        tasks[item.id] = task
        notBefore[item.id] = nil
        failedOffline.remove(item.id)
        store.update(item.id) {
            $0.state = .downloading
            $0.errorMessage = nil
        }
        task.resume()
        return true
    }

    private func resumeAccount(_ id: String) -> String { "resume.\(id)" }

    private func makeProgress(item: OfflineItem, received: Int64, expected: Int64) -> Progress {
        if expected > 0 {
            return Progress(received: received, expected: expected,
                            fraction: min(1, Double(received) / Double(expected)), isEstimate: false)
        }
        // Kein Content-Length: gegen die Schätzung rechnen und bei 100 % deckeln, bis der Strom endet.
        let estimate = item.estimatedBytes
        let fraction = estimate > 0 ? min(1, Double(received) / Double(estimate)) : 0
        return Progress(received: received, expected: estimate, fraction: fraction, isEstimate: true)
    }

    // MARK: Ereignisse der Session

    private func handle(_ event: DownloadSessionDelegate.Event) {
        switch event {
        case .progress(let id, let written, let expected):
            guard tasks[id] != nil, let item = store.item(id) else { return }
            progress[id] = makeProgress(item: item, received: written, expected: expected)

        case .finished(let id, let size):
            guard tasks[id] != nil else { return }
            tasks[id] = nil
            attempts[id] = nil
            progress[id] = nil
            keychain.delete(account: resumeAccount(id))
            store.update(id) {
                $0.state = .completed
                $0.fileSize = size
                $0.bytesReceived = size
                $0.bytesExpected = size
                $0.completedAt = Date()
                $0.errorMessage = nil
            }
            if let item = store.item(id) {
                notices.post("„\(item.displayTitle)“ ist fertig geladen.")
            }
            schedule()

        case .failed(let id, let failure, let resumeData):
            guard tasks[id] != nil, let item = store.item(id) else { return }
            tasks[id] = nil
            let last = progress[id]

            if item.isOriginal, let resumeData {
                keychain.set(resumeData, account: resumeAccount(id))
            } else {
                // Umgerechneter Strom oder keine Fortsetzungsdaten: von vorn.
                keychain.delete(account: resumeAccount(id))
                progress[id] = nil
            }
            // 416: die angefangene Datei passt nicht mehr zum Server – verwerfen und neu beginnen.
            if case .http(416) = failure {
                keychain.delete(account: resumeAccount(id))
                progress[id] = nil
            }

            let attempt = (attempts[id] ?? 0) + 1
            attempts[id] = attempt
            let retryable = failure.isTransient || { if case .http(416) = failure { return true } else { return false } }()

            if retryable, attempt <= Self.maxAutomaticRetries {
                let delay = TimeInterval(5 * (1 << (attempt - 1)))   // 5 s, 10 s, 20 s
                notBefore[id] = Date().addingTimeInterval(delay)
                store.update(id) {
                    $0.state = .queued
                    $0.bytesReceived = item.isOriginal ? (last?.received ?? $0.bytesReceived) : 0
                    $0.bytesExpected = last?.isEstimate == false ? (last?.expected ?? 0) : $0.bytesExpected
                    $0.errorMessage = "Unterbrochen, neuer Versuch folgt: \(failure.message)"
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((delay + 0.2) * 1_000_000_000))
                    self?.schedule()
                }
            } else {
                if failure.isOffline { failedOffline.insert(id) }
                store.update(id) {
                    $0.bytesReceived = item.isOriginal ? (last?.received ?? $0.bytesReceived) : 0
                }
                fail(id, message: failure.message)
            }
            schedule()
        }
    }

    private func fail(_ id: String, message: String) {
        store.update(id) {
            $0.state = .failed
            $0.errorMessage = message
        }
    }

    // MARK: Bedienung

    /// Original: anhalten und Fortsetzungsdaten sichern. Umgerechnet: abbrechen, später von vorn.
    func pause(_ id: String) {
        guard let item = store.item(id), item.isActive else { return }
        notBefore[id] = nil
        let last = progress[id]

        if let task = tasks.removeValue(forKey: id) {
            sessionDelegate.unregister(task: task)
            if item.isOriginal {
                let account = resumeAccount(id)
                let keychain = self.keychain
                task.cancel(byProducingResumeData: { data in
                    if let data { keychain.set(data, account: account) }
                })
            } else {
                task.cancel()
                progress[id] = nil
            }
        }
        store.update(id) {
            $0.state = .paused
            $0.errorMessage = nil
            if item.isOriginal {
                if let last {
                    $0.bytesReceived = last.received
                    if !last.isEstimate { $0.bytesExpected = last.expected }
                }
            } else {
                $0.bytesReceived = 0
            }
        }
        schedule()
    }

    /// Setzt einen angehaltenen oder gescheiterten Download wieder in die Schlange.
    func resume(_ id: String) {
        guard let item = store.item(id), item.state == .paused || item.state == .failed else { return }
        attempts[id] = nil
        notBefore[id] = nil
        failedOffline.remove(id)
        store.update(id) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        schedule()
    }

    /// Löscht Download, Datei, Bilder und Fortsetzungsdaten.
    func remove(_ id: String) {
        guard let item = store.item(id) else { return }
        if let task = tasks.removeValue(forKey: id) {
            sessionDelegate.unregister(task: task)
            task.cancel()
        }
        progress[id] = nil
        attempts[id] = nil
        notBefore[id] = nil
        failedOffline.remove(id)
        keychain.delete(account: resumeAccount(id))

        let fm = FileManager.default
        try? fm.removeItem(at: item.fileURL)
        if let poster = item.posterURL { try? fm.removeItem(at: poster) }
        if let backdrop = item.backdropURL { try? fm.removeItem(at: backdrop) }
        try? fm.removeItem(at: AppPaths.trickplay(for: id))
        removeEmptyParents(of: item.fileURL)

        store.remove(id)
        introLibrary?.prune()
        credentials.prune(keeping: Set(store.items.map(\.credentialRef)))
        schedule()
    }

    /// Räumt leere Ordner bis hinauf zu OfflineMedia weg.
    private func removeEmptyParents(of file: URL) {
        let fm = FileManager.default
        let root = AppPaths.offlineMedia.standardizedFileURL.path
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root + "/") {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    // MARK: Lebenszyklus

    /// Nach dem Start: was beim letzten Lauf noch lud, kommt zurück in die Schlange.
    /// Originale setzen über die gesicherten Fortsetzungsdaten fort, umgerechnete beginnen neu.
    func restoreAfterLaunch() {
        for item in store.items where item.state == .downloading {
            store.update(item.id) { $0.state = .queued }
        }
        for item in store.items where item.state == .completed {
            if !FileManager.default.fileExists(atPath: item.fileURL.path) {
                fail(item.id, message: "Die Datei fehlt auf der Festplatte. Erneut laden oder den Eintrag löschen.")
            }
        }
        for item in store.items where item.posterFile == nil || (item.backdropFile == nil && item.backdropUrlTemplate != nil) {
            fetchArtwork(for: item.id)
        }
        // Auch ältere Downloads bekommen ihre Vorschaubilder nachgereicht.
        for item in store.items where item.trickplay == nil { fetchTrickplay(for: item.id) }
        introLibrary?.refreshAll()
        schedule()
    }

    /// Das Netz ist wieder da: wegen fehlender Verbindung Gescheitertes neu versuchen.
    func networkBecameAvailable() {
        for id in failedOffline { resume(id) }
        notBefore.removeAll()
        schedule()
    }

    /// Vor dem Beenden: laufende Originale mit Fortsetzungsdaten anhalten, damit sie
    /// beim nächsten Start weiterladen. Umgerechnete Ströme lassen sich nicht fortsetzen.
    func prepareForTermination() async {
        let running = tasks
        tasks = [:]
        for (id, task) in running {
            sessionDelegate.unregister(task: task)
            guard let item = store.item(id) else { task.cancel(); continue }
            let last = progress[id]
            if item.isOriginal {
                let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                    task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
                }
                if let data { keychain.set(data, account: resumeAccount(id)) }
            } else {
                task.cancel()
            }
            store.update(id) {
                $0.state = .queued
                if item.isOriginal, let last {
                    $0.bytesReceived = last.received
                    if !last.isEstimate { $0.bytesExpected = last.expected }
                } else {
                    $0.bytesReceived = 0
                }
            }
        }
        store.saveNow()
    }

    // MARK: Poster und Hintergrund

    private func fetchArtwork(for id: String) {
        guard let item = store.item(id),
              let credential = credentials.credential(ref: item.credentialRef) else { return }
        let token = credential.accessToken
        let jobs: [(template: String?, suffix: String, isPoster: Bool)] = [
            (item.posterFile == nil ? item.imageUrlTemplate : nil, "poster", true),
            (item.backdropFile == nil ? item.backdropUrlTemplate : nil, "backdrop", false),
        ]
        for job in jobs {
            guard let template = job.template, let url = TokenTemplate.fill(template, token: token) else { continue }
            let session = artworkSession!
            Task { [weak self] in
                var request = URLRequest(url: url)
                request.setValue(JellyfinAuth.header(token: token), forHTTPHeaderField: "Authorization")
                guard let (data, response) = try? await session.data(for: request),
                      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      !data.isEmpty, data.count < 30_000_000 else { return }
                let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                let ext = mime.contains("png") ? "png" : mime.contains("webp") ? "webp" : "jpg"
                let name = "\(id)-\(job.suffix).\(ext)"
                do {
                    try FileManager.default.createDirectory(at: AppPaths.artwork, withIntermediateDirectories: true)
                    try data.write(to: AppPaths.artwork.appendingPathComponent(name), options: .atomic)
                } catch { return }
                await MainActor.run {
                    guard let self, self.store.item(id) != nil else {
                        try? FileManager.default.removeItem(at: AppPaths.artwork.appendingPathComponent(name))
                        return
                    }
                    self.store.update(id) {
                        if job.isPoster { $0.posterFile = name } else { $0.backdropFile = name }
                    }
                }
            }
        }
    }

    // MARK: Vorschaubilder der Zeitleiste

    /// Lädt die Vorschaubilder („Trickplay“), die der Server für den Titel erzeugt hat, damit der
    /// Player sie auch ohne Netz über der Zeitleiste zeigen kann. Hat der Server keine, wird das
    /// vermerkt und erst beim nächsten Start wieder gefragt.
    private func fetchTrickplay(for id: String) {
        guard let api, !trickplayRunning.contains(id), let item = store.item(id), item.trickplay == nil,
              let credential = credentials.credential(ref: item.credentialRef) else { return }
        trickplayRunning.insert(id)
        let server = item.serverUrl, itemId = item.itemId
        Task { [weak self] in
            defer { Task { @MainActor in self?.trickplayRunning.remove(id) } }
            guard let info = await api.trickplayInfo(server: server, itemId: itemId, userId: credential.userId,
                                                     token: credential.accessToken, mediaSourceId: nil) else {
                await MainActor.run { self?.store.update(id) { $0.trickplayChecked = true } }
                return
            }
            let folder = AppPaths.trickplay(for: id)
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<info.sheetCount {
                let file = folder.appendingPathComponent("\(index).jpg")
                if fm.fileExists(atPath: file.path) { continue }
                guard let data = await api.trickplaySheet(server: server, itemId: itemId, info: info, index: index,
                                                          token: credential.accessToken) else {
                    return   // unvollständig: beim nächsten Start geht es an derselben Stelle weiter
                }
                try? data.write(to: file, options: .atomic)
            }
            await MainActor.run {
                guard let self, self.store.item(id) != nil else {
                    try? fm.removeItem(at: folder)
                    return
                }
                self.store.update(id) {
                    $0.trickplay = info
                    $0.trickplayChecked = true
                }
            }
        }
    }

    // MARK: Anzeige

    var activeCount: Int {
        store.items.filter(\.isActive).count
    }

    /// Fortschritt für die Liste: live, sonst der zuletzt gespeicherte Stand.
    func displayProgress(for item: OfflineItem) -> Progress? {
        if let live = progress[item.id] { return live }
        guard item.state != .completed else { return nil }
        if item.bytesExpected > 0 {
            return makeProgress(item: item, received: item.bytesReceived, expected: item.bytesExpected)
        }
        return makeProgress(item: item, received: item.bytesReceived, expected: -1)
    }
}
