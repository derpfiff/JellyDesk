import Foundation

/// Merkmale eines Titels, nach denen „Local Intros“ besondere Intros auswählt.
/// Bei Folgen sind Staffel und Serie eingerechnet, wie es das Plugin tut.
struct IntroCriteria: Codable, Equatable, Sendable {
    var tags: [String] = []
    var genres: [String] = []
    var studios: [String] = []
}

/// Abbild der Konfiguration des Plugins „Local Intros“ (IntroPluginConfiguration).
struct LocalIntrosConfig: Codable, Equatable {
    struct Special: Codable, Equatable {
        var introId: String
        /// Tag, Genre oder Studio; bei Datumsregeln leer.
        var name: String = ""
        var precedence: Int = 0
        var prevalence: Int = 0
        var dateStart: String?
        var dateEnd: String?
        /// None, Weekly, Monthly, Yearly
        var repeatType: String = "None"
    }

    /// Der Intro-Ordner ist im Plugin gesetzt.
    var enabled = false
    var moviesOnly = false
    /// Alle vom Plugin erkannten Videos: Kennung → Name.
    var detected: [String: String] = [:]
    var defaults: [String] = []
    var tagIntros: [Special] = []
    var genreIntros: [Special] = []
    var studioIntros: [Special] = []
    var currentDateIntros: [Special] = []
    var fetchedAt = Date()
}

/// Hält die Einstellungen von „Local Intros“ und die Intro-Videos offline bereit.
///
/// Die Konfiguration wird bei jeder Verbindung zum Server neu gelesen (App-Start, Abgleich,
/// neuer Download) und alle erkannten Intros werden einmalig geladen. Vor jeder Wiedergabe
/// wendet `pick(for:)` die Auswahlregel des Plugins auf den zuletzt gelesenen Stand an –
/// Änderungen an den Plugin-Einstellungen wirken also, sobald die App den Server wieder sieht.
///
/// Die Konfiguration darf nur ein Administratorkonto lesen. Ohne dieses Recht fragt die App
/// ersatzweise je Titel mehrfach `/Items/{id}/Intros` ab und merkt sich die Antworten.
@MainActor
final class IntroLibrary: ObservableObject {
    @Published private(set) var status = "Einstellungen von „Local Intros“ noch nicht gelesen."

    private let store: OfflineStore
    private let credentials: CredentialStore
    private let api: JellyfinAPIService
    private let session: URLSession
    private let fileURL = AppPaths.offlineMedia.appendingPathComponent("local-intros.json")

    private var configs: [String: LocalIntrosConfig] = [:]
    private var lastRefresh: [String: Date] = [:]
    private var running: [String: Task<Void, Never>] = [:]

    init(store: OfflineStore, credentials: CredentialStore, api: JellyfinAPIService) {
        self.store = store
        self.credentials = credentials
        self.api = api
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([String: LocalIntrosConfig].self, from: data) {
            configs = saved
            describe()
        }
    }

    private func key(_ server: URL) -> String { server.absoluteString }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(configs) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func describe() {
        guard let (server, config) = configs.max(by: { $0.value.fetchedAt < $1.value.fetchedAt }) else { return }
        let time = DateFormatter.localizedString(from: config.fetchedAt, dateStyle: .short, timeStyle: .short)
        let host = URL(string: server)?.host ?? server
        if !config.enabled {
            status = "\(host), gelesen \(time): im Plugin ist kein Intro-Ordner gesetzt."
            return
        }
        let special = config.tagIntros.count + config.genreIntros.count + config.studioIntros.count + config.currentDateIntros.count
        status = "\(host), gelesen \(time): \(config.detected.count) Intros, davon \(Set(config.defaults).count) Standard, "
            + "\(special) Sonderregeln, " + (config.moviesOnly ? "nur vor Filmen." : "vor Filmen und Folgen.")
    }

    // MARK: Abgleich mit dem Server

    /// Liest die Einstellungen aller Server, von denen Downloads stammen, und ergänzt fehlende
    /// Merkmale der Titel.
    func refreshAll() {
        var seen: Set<String> = []
        for item in store.items where seen.insert(key(item.serverUrl)).inserted {
            Task { await refresh(for: item.id, force: false) }
        }
        for item in store.items where item.introCriteria == nil || (configs[key(item.serverUrl)] == nil && item.introCandidates == nil) {
            Task { await prepare(itemID: item.id) }
        }
    }

    /// Für einen neuen Download: Einstellungen auffrischen, Merkmale des Titels holen und – falls
    /// die Konfiguration nicht lesbar ist – die Antworten des Servers für diesen Titel sammeln.
    func prepare(itemID: String) async {
        await refresh(for: itemID, force: false)
        guard let item = store.item(itemID),
              let credential = credentials.credential(ref: item.credentialRef) else { return }

        if item.introCriteria == nil,
           let criteria = try? await api.introCriteria(server: item.serverUrl, itemId: item.itemId,
                                                       userId: credential.userId, token: credential.accessToken) {
            store.update(itemID) { $0.introCriteria = criteria }
        }
        if configs[key(item.serverUrl)] == nil, item.introCandidates == nil {
            await sampleCandidates(itemID: itemID)
        }
    }

    /// Liest die Plugin-Konfiguration (höchstens einmal pro Minute je Server) und lädt neue Intros.
    private func refresh(for itemID: String, force: Bool) async {
        guard let item = store.item(itemID),
              let credential = credentials.credential(ref: item.credentialRef) else { return }
        let server = item.serverUrl
        let serverKey = key(server)
        if let task = running[serverKey] {
            await task.value
            return
        }
        if !force, let last = lastRefresh[serverKey], Date().timeIntervalSince(last) < 60 { return }

        let token = credential.accessToken
        let task = Task { [weak self] in
            guard let self else { return }
            guard let data = await self.api.localIntrosConfigurationData(server: server, token: token),
                  let config = Self.parse(data) else {
                if self.configs[serverKey] == nil {
                    self.status = "Die Einstellungen von „Local Intros“ sind nicht lesbar (dafür braucht es ein Administratorkonto oder eine Verbindung zum Server). Ersatzweise gilt, was der Server je Titel antwortet."
                }
                return
            }
            self.lastRefresh[serverKey] = Date()
            self.configs[serverKey] = config
            self.save()
            self.describe()
            for introId in config.detected.keys.sorted() {
                await self.download(introId: introId, server: server, token: token)
            }
            self.prune()
        }
        running[serverKey] = task
        await task.value
        running[serverKey] = nil
    }

    private static func parse(_ data: Data) -> LocalIntrosConfig? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func id(_ value: Any?) -> String? {
            guard let text = value as? String, !text.isEmpty else { return nil }
            return text.replacingOccurrences(of: "-", with: "").lowercased()
        }
        func specials(_ listKey: String, _ nameKey: String?) -> [LocalIntrosConfig.Special] {
            (root[listKey] as? [[String: Any]] ?? []).compactMap { entry in
                guard let introId = id(entry["IntroId"]) else { return nil }
                var special = LocalIntrosConfig.Special(introId: introId)
                if let nameKey { special.name = entry[nameKey] as? String ?? "" }
                special.precedence = (entry["Precedence"] as? NSNumber)?.intValue ?? 0
                special.prevalence = (entry["Prevalence"] as? NSNumber)?.intValue ?? 0
                special.dateStart = entry["DateStart"] as? String
                special.dateEnd = entry["DateEnd"] as? String
                if let text = entry["RepeatType"] as? String {
                    special.repeatType = text
                } else if let number = entry["RepeatType"] as? NSNumber {
                    special.repeatType = ["None", "Weekly", "Monthly", "Yearly"][min(3, max(0, number.intValue))]
                }
                return special
            }
        }

        var config = LocalIntrosConfig()
        config.enabled = !((root["Local"] as? String) ?? "").isEmpty
        config.moviesOnly = root["IntrosForMoviesOnly"] as? Bool ?? false
        for entry in root["DetectedLocalVideos"] as? [[String: Any]] ?? [] {
            if let introId = id(entry["ItemId"]) { config.detected[introId] = entry["Name"] as? String ?? "" }
        }
        config.defaults = (root["DefaultLocalVideos"] as? [Any] ?? []).compactMap { id($0) }
        config.tagIntros = specials("TagIntros", "TagName")
        config.genreIntros = specials("GenreIntros", "GenreName")
        config.studioIntros = specials("StudioIntros", "StudioName")
        config.currentDateIntros = specials("CurrentDateIntros", nil)
        config.fetchedAt = Date()
        return config
    }

    // MARK: Dateien

    private func localFile(for introId: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.intros.path)) ?? []
        return names.first { $0.hasPrefix(introId + ".") }.map { AppPaths.intros.appendingPathComponent($0) }
    }

    /// Lädt ein Intro einmalig: erst die Datei wie auf dem Server, sonst den unveränderten Strom.
    @discardableResult
    private func download(introId: String, server: URL, token: String, fileExtension: String? = nil) async -> URL? {
        if let existing = localFile(for: introId) { return existing }
        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.intros, withIntermediateDirectories: true)
        let routes: [(String, [URLQueryItem])] = [
            ("Items/\(introId)/Download", []),
            ("Videos/\(introId)/stream", [URLQueryItem(name: "static", value: "true")]),
        ]
        for (path, query) in routes {
            var url = server
            for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            if !query.isEmpty { components.queryItems = query }
            guard let final = components.url else { continue }
            var request = URLRequest(url: final)
            request.setValue(JellyfinAuth.header(token: token), forHTTPHeaderField: "Authorization")
            guard let (temp, response) = try? await session.download(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { continue }
            var ext = fileExtension ?? ((http.suggestedFilename ?? "") as NSString).pathExtension.lowercased()
            if ext.isEmpty || ext.count > 5 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) { ext = "mkv" }
            let target = AppPaths.intros.appendingPathComponent("\(introId).\(ext)")
            try? fm.removeItem(at: target)
            if (try? fm.moveItem(at: temp, to: target)) != nil { return target }
        }
        return nil
    }

    /// Ersatzweg ohne Administratorkonto: der Server würfelt bei jeder Anfrage neu, also
    /// mehrfach fragen und die Antworten sammeln.
    private func sampleCandidates(itemID: String) async {
        guard let item = store.item(itemID),
              let credential = credentials.credential(ref: item.credentialRef) else { return }
        var found: [String: String] = [:]
        var answered = false
        for _ in 0..<8 {
            guard let intros = try? await api.intros(server: item.serverUrl, itemId: item.itemId,
                                                     userId: credential.userId, token: credential.accessToken) else { break }
            answered = true
            if intros.isEmpty { break }
            for intro in intros {
                found[intro.id.replacingOccurrences(of: "-", with: "").lowercased()] = intro.fileExtension
            }
        }
        guard answered else { return }
        var files: [String] = []
        for (introId, ext) in found.sorted(by: { $0.key < $1.key }) {
            if let file = await download(introId: introId, server: item.serverUrl, token: credential.accessToken, fileExtension: ext) {
                files.append(file.lastPathComponent)
            }
        }
        store.update(itemID) { $0.introCandidates = files }
    }

    /// Löscht Intro-Dateien, die weder in einer Konfiguration noch bei einem Titel vorkommen.
    func prune() {
        var keep = Set(store.items.flatMap { $0.introCandidates ?? [] }.map { ($0 as NSString).deletingPathExtension })
        for config in configs.values { keep.formUnion(config.detected.keys) }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: AppPaths.intros.path)) ?? []
        where !keep.contains((name as NSString).deletingPathExtension) {
            try? fm.removeItem(at: AppPaths.intros.appendingPathComponent(name))
        }
    }

    // MARK: Auswahl wie im Plugin

    /// Wählt den Vorspann für einen Titel nach den zuletzt gelesenen Einstellungen, nach derselben
    /// Regel wie `IntroProvider.Local` im Plugin. nil: kein Vorspann.
    func pick(for item: OfflineItem) -> URL? {
        guard let config = configs[key(item.serverUrl)] else {
            // Konfiguration nie gelesen: zufällig aus den Antworten des Servers für diesen Titel.
            return item.introURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.randomElement()
        }
        guard config.enabled else { return nil }
        let isMovie = item.itemType == "Movie"
        if config.moviesOnly, !isMovie { return nil }

        // Merkmale kennt das Plugin nur für Filme und Folgen.
        let criteria = (isMovie || item.isEpisode) ? (item.introCriteria ?? IntroCriteria()) : IntroCriteria()
        func matches(_ list: [String], _ name: String) -> Bool {
            list.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let now = Date()
        var selectable: [LocalIntrosConfig.Special] = []
        selectable += config.tagIntros.filter { matches(criteria.tags, $0.name) }
        selectable += config.genreIntros.filter { matches(criteria.genres, $0.name) }
        selectable += config.studioIntros.filter { matches(criteria.studios, $0.name) }
        selectable += config.currentDateIntros.filter { Self.isDateInRange($0, now) }

        var pool: [String] = []
        if let highest = selectable.map(\.precedence).max() {
            // Unter den Regeln mit höchstem Vorrang wird nach Gewicht gelost. Wie im Plugin
            // läuft das Los über die Summe aller Gewichte; trifft es keine, gilt die letzte.
            let selected = selectable.filter { $0.precedence == highest }
            let total = selectable.reduce(0) { $0 + $1.prevalence }
            var index = total > 0 ? Int.random(in: 0..<total) : 0
            var chosen: String?
            for special in selected {
                if index < special.prevalence {
                    chosen = special.introId
                    break
                }
                index -= special.prevalence
            }
            if let final = chosen ?? selected.last?.introId { pool = [final] }
        } else {
            var seen: Set<String> = []
            pool = config.defaults.filter { seen.insert($0).inserted }
        }

        // Das Plugin lost genau eines; fehlt es in der Bibliothek, gibt es keinen Vorspann.
        guard let introId = pool.randomElement(), config.detected[introId] != nil else { return nil }
        return localFile(for: introId)
    }

    /// Entspricht DateRangeIntro.IsDateInRange. Die Angaben des Servers sind Ortszeit ohne Zone.
    private static func isDateInRange(_ special: LocalIntrosConfig.Special, _ now: Date) -> Bool {
        guard let start = localDate(special.dateStart), let end = localDate(special.dateEnd) else { return false }
        let calendar = Calendar.current
        switch special.repeatType.lowercased() {
        case "weekly":
            let day = calendar.component(.weekday, from: now)
            return day >= calendar.component(.weekday, from: start) && day <= calendar.component(.weekday, from: end)
        case "monthly":
            let day = calendar.component(.day, from: now)
            return day >= calendar.component(.day, from: start) && day <= calendar.component(.day, from: end)
        case "yearly":
            func monthDay(_ date: Date) -> Int { calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date) }
            return monthDay(now) >= monthDay(start) && monthDay(now) <= monthDay(end)
        default:
            return now >= start && now <= end
        }
    }

    private static func localDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let numbers = text.prefix(19).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers.count > 3 ? numbers[3] : 0
        components.minute = numbers.count > 4 ? numbers[4] : 0
        components.second = numbers.count > 5 ? numbers[5] : 0
        return Calendar.current.date(from: components)
    }
}
