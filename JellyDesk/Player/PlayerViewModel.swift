import AppKit
import MediaPlayer

extension Notification.Name {
    /// Die App wird beendet: offene Player sichern ihren Stand.
    static let jellyDeskWillTerminate = Notification.Name("JellyDeskWillTerminate")
}

/// Qualität für Streams: die Datei unverändert oder vom Server auf eine Bitrate heruntergerechnet.
/// Die Stufen entsprechen denen des Web-Players; die Auflösung wählt der Server passend zur Bitrate.
enum StreamQuality: String, CaseIterable, Identifiable {
    case original = "orig"
    case p1080High = "1080-20"
    case p1080 = "1080-10"
    case p720 = "720-4"
    case p480 = "480-1.5"

    var id: String { rawValue }

    var maxBitrate: Int? {
        switch self {
        case .original: return nil
        case .p1080High: return 20_000_000
        case .p1080: return 10_000_000
        case .p720: return 4_000_000
        case .p480: return 1_500_000
        }
    }

    var label: String {
        switch self {
        case .original: return "Original"
        case .p1080High: return "1080p – 20 Mbit/s"
        case .p1080: return "1080p – 10 Mbit/s"
        case .p720: return "720p – 4 Mbit/s"
        case .p480: return "480p – 1,5 Mbit/s"
        }
    }

    static var saved: StreamQuality {
        UserDefaults.standard.string(forKey: SettingsKeys.streamQuality).flatMap(StreamQuality.init(rawValue:)) ?? .original
    }
}

/// Steuert die Wiedergabe im eigenen Player.
///
/// Downloads: spielt beim Start von vorn zuerst den Vorspann, wählt den Player nach Container,
/// setzt an der gemerkten Stelle fort, merkt die Spurwahl und schreibt die Position alle zehn
/// Sekunden zurück.
///
/// Streams: spielt die Warteschlange ab, die die Weboberfläche abspielen wollte, lädt die
/// Dateien unverändert vom Server und meldet ihm Beginn, Stand und Ende wie jeder andere Client.
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var engine: PlayerEngine?
    /// Große Zeile über der Bedienung: Serie oder Filmtitel.
    @Published private(set) var headline = ""
    /// Kleine Zeile darüber: „S1 · F4 · Folgentitel“ bzw. das Jahr.
    @Published private(set) var subline = ""
    @Published private(set) var windowTitle = ""
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPaused = true
    @Published private(set) var isLoaded = false
    /// Gerade läuft ein Vorspann, nicht der Titel selbst.
    @Published private(set) var isIntro = false
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?
    @Published private(set) var errorMessage: String?
    /// Vorschaubilder für die Zeitleiste, sofern es für den Titel welche gibt.
    @Published private(set) var trickplay: TrickplayProvider?
    /// Für den gerade laufenden Film liegt eine Bewertungs-Frage vor; die Oberfläche zeigt
    /// dann das Sheet. Wird gesetzt, sobald der Film zu Ende ist oder ~90 % erreicht wurden.
    @Published var pendingRatingPrompt: RatingContext?
    /// Wiedergabegeschwindigkeit, 1 = normal. Gilt für das Fenster, auch über Titelwechsel hinweg.
    @Published private(set) var speed: Double = 1
    /// Gewählte Qualität für Streams; Downloads und Vorspänne laufen immer im Original.
    @Published private(set) var streamQuality: StreamQuality = .saved
    /// Der laufende Titel kommt umgerechnet vom Server (HLS), nicht als Originaldatei.
    @Published private(set) var isTranscoding = false
    /// Das Bild läuft gerade im Bild-in-Bild-Fenster.
    @Published private(set) var isPictureInPicture = false
    @Published var volume: Double {
        didSet {
            engine?.volume = volume
            UserDefaults.standard.set(volume, forKey: SettingsKeys.playerVolume)
        }
    }

    let itemID: String
    private let store: OfflineStore
    private let sync: ProgressSyncService
    private let intros: IntroLibrary
    private let api: JellyfinAPIService
    private let streams: StreamSessions
    private let ratings: RatingStore
    private let credentials: CredentialStore

    /// Für den aktuell laufenden Hauptfilm schon einmal angeboten; verhindert doppelte Sheets.
    private var ratingOffered = false

    /// Auftrag der Weboberfläche; nil bei einem Download.
    private var stream: StreamRequest?
    private var streamIndex = 0
    private var streamSource: JellyfinAPIService.PlaybackSource?
    /// Zählt die Ladevorgänge, damit eine verspätete Antwort keinen neueren Titel überschreibt.
    private var streamLoad = 0
    /// Der Beginn des laufenden Titels ist dem Server gemeldet.
    private var streamReported = false
    private var lastReportedPause: Bool?

    /// Spurwahl in der Zählung des Servers, die beim nächsten Laden des laufenden Titels gilt
    /// (nach einem Wechsel der Qualität oder einer Spur während der Umrechnung). Untertitel -1: aus.
    private var overrideAudioIndex: Int?
    private var overrideSubtitleIndex: Int?
    /// Spuren, mit denen der Server gerade umrechnet.
    private var activeAudioIndex: Int?
    private var activeSubtitleIndex: Int?

    private let pictureInPicture = PictureInPicture()
    private var fullscreenExitObserver: NSObjectProtocol?

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var introQueue: [URL] = []
    private var mainKind = PlayerEngineKind.mpv
    private var mainHeadline = ""
    private var mainSubline = ""
    private var volumeBeforeMute: Double = 1

    private var saveTimer: Timer?
    private var keyMonitor: Any?
    private var terminateObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var sleepActivity: NSObjectProtocol?
    private var lastSavedTicks: Int64 = -1
    private var preferencesApplied = false
    private var started = false
    private var closed = false

    init(itemID: String, store: OfflineStore, sync: ProgressSyncService, intros: IntroLibrary,
         api: JellyfinAPIService, streams: StreamSessions, ratings: RatingStore, credentials: CredentialStore) {
        self.intros = intros
        self.api = api
        self.streams = streams
        self.itemID = itemID
        self.store = store
        self.sync = sync
        self.ratings = ratings
        self.credentials = credentials
        self.volume = UserDefaults.standard.double(forKey: SettingsKeys.playerVolume)
        pictureInPicture.onPlay = { [weak self] in self?.engine?.play() }
        pictureInPicture.onPause = { [weak self] in self?.engine?.pause() }
        pictureInPicture.onStop = { [weak self] in self?.engine?.pause() }
        pictureInPicture.onDidClose = { [weak self] in self?.isPictureInPicture = false }
    }

    // MARK: Start und Ende

    func start() {
        guard !started, !closed else { return }
        started = true
        if itemID.hasPrefix(StreamSessions.prefix) {
            startStream()
            return
        }
        guard let item = store.item(itemID) else {
            errorMessage = "Dieser Download existiert nicht mehr."
            return
        }
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            errorMessage = "Die Datei fehlt auf der Festplatte."
            return
        }
        windowTitle = item.displayTitle
        setTitles(title: item.title, isEpisode: item.isEpisode, series: item.seriesName,
                  season: item.seasonNumber, episode: item.episodeNumber, year: item.year)
        store.nowPlaying.insert(itemID)
        lastSavedTicks = item.positionTicks

        // Wahl nach Container: MP4/MOV (die umgerechneten Downloads) mit AVKit, alles andere mit mpv.
        let ext = item.fileURL.pathExtension.lowercased()
        let avKitAllowed = UserDefaults.standard.bool(forKey: SettingsKeys.useAVKitForMP4)
        mainKind = avKitAllowed && ["mp4", "m4v", "mov"].contains(ext) ? .avKit : .mpv

        // Vorspann wie im Web nur beim Start von vorn, nicht beim Fortsetzen. Ob und welcher
        // läuft, entscheiden die zuletzt gelesenen Einstellungen von „Local Intros“.
        if UserDefaults.standard.bool(forKey: SettingsKeys.playIntros), startPosition(for: item) == 0,
           let intro = intros.pick(for: item) {
            introQueue = [intro]
        }

        installHousekeeping()
        playNext()
    }

    private func installHousekeeping() {
        saveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: .jellyDeskWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            // Beim Beenden der App mit offenem Player: bei Streams gleich das Ende melden, damit der Server den letzten
            // Stand festhält und die Sitzung schließt, statt auf eine Zwischenmeldung zu vertrauen.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.stream != nil, self.isLoaded, !self.closed { self.reportStream(.stopped) } else { self.saveProgress() }
            }
        }
        installKeyMonitor()
        installRemoteCommands()
    }

    private func setTitles(title: String, isEpisode: Bool, series: String, season: Int?, episode: Int?, year: Int?) {
        if isEpisode {
            mainHeadline = series.isEmpty ? title : series
            var parts: [String] = []
            if let season { parts.append("S\(season)") }
            if let episode { parts.append("F\(episode)") }
            parts.append(title)
            mainSubline = parts.joined(separator: " · ")
        } else {
            mainHeadline = title
            mainSubline = year.map(String.init) ?? ""
        }
    }

    /// Dort fortsetzen, wo zuletzt aufgehört wurde (Startwert stammt aus positionTicks der Nachricht).
    private func startPosition(for item: OfflineItem) -> TimeInterval {
        let total = item.duration
        let position = Ticks.seconds(item.positionTicks)
        if total > 0, position / total > 0.95 { return 0 }
        return position < 1 ? 0 : position
    }

    /// Spielt den nächsten Vorspann oder, wenn keiner mehr wartet, den Titel selbst.
    private func playNext() {
        if !introQueue.isEmpty {
            let url = introQueue.removeFirst()
            isIntro = true
            headline = "Vorspann"
            subline = mainHeadline
            trickplay = nil
            load(url: url, kind: .mpv, startAt: 0, fallbackDuration: 0)
            return
        }
        guard let item = store.item(itemID) else { return }
        isIntro = false
        headline = mainHeadline
        subline = mainSubline
        if let info = item.trickplay, info.isUsable {
            let folder = AppPaths.trickplay(for: item.id)
            trickplay = TrickplayProvider(info: info) { index in
                try? Data(contentsOf: folder.appendingPathComponent("\(index).jpg"))
            }
        }
        load(url: item.fileURL, kind: mainKind, startAt: startPosition(for: item), fallbackDuration: item.duration)
    }

    private func load(url: URL, kind: PlayerEngineKind, startAt: TimeInterval, fallbackDuration: TimeInterval,
                      headers: [String: String] = [:]) {
        isLoaded = false
        preferencesApplied = false
        errorMessage = nil
        position = startAt
        duration = fallbackDuration

        if engine?.kind != kind {
            // Die Ansicht des alten Players gehört zurück ins Fenster, bevor er verschwindet.
            if pictureInPicture.isActive { pictureInPicture.stop() }
            engine?.shutdown()
            let newEngine: PlayerEngine
            switch kind {
            case .avKit:
                newEngine = AVKitPlayerEngine()
            case .mpv:
                // HDR durchreichen, wenn der Bildschirm des aktiven Fensters es kann.
                let screen = NSApp.keyWindow?.screen ?? NSScreen.main
                let hdr = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
                newEngine = MPVPlayerEngine(hdrDisplay: hdr)
            }
            newEngine.delegate = self
            newEngine.volume = volume
            newEngine.speed = speed
            engine = newEngine
        }
        engine?.setHTTPHeaders(headers)
        engine?.load(url: url, startAt: startAt, fallbackDuration: fallbackDuration)
        engine?.play()
    }

    // MARK: Streams

    private func startStream() {
        guard let request = streams.request(for: itemID) else {
            errorMessage = "Dieser Wiedergabe-Auftrag ist nicht mehr gültig. Bitte in der Weboberfläche erneut starten."
            return
        }
        // Ab hier hält nur noch dieses Fenster die Zugangsdaten.
        streams.discard(itemID)
        stream = request
        installHousekeeping()
        playStream(at: request.startIndex)
    }

    /// Erster eigentlicher Titel der Warteschlange; nur für ihn gelten Startstelle und Spurwahl
    /// aus der Weboberfläche.
    private var firstMainIndex: Int {
        guard let stream else { return 0 }
        return stream.items[stream.startIndex...].firstIndex { !$0.isIntro } ?? stream.startIndex
    }

    /// `resumeAt`: denselben Titel neu laden (andere Qualität oder Spur) und dort fortsetzen.
    private func playStream(at index: Int, resumeAt: TimeInterval? = nil) {
        guard let stream else { return }
        guard index < stream.items.count else {
            // Warteschlange zu Ende: wie im Web-Player zurück zur Oberfläche.
            let window = pictureInPicture.isActive ? pictureInPicture.playerWindow : engine?.view.window
            pictureInPicture.stop()
            window?.close()
            return
        }
        if resumeAt == nil {
            overrideAudioIndex = nil
            overrideSubtitleIndex = nil
        }
        streamIndex = index
        streamSource = nil
        streamReported = false
        lastReportedPause = nil
        trickplay = nil
        streamLoad += 1
        // Neuer Titel: ein etwaiges vorheriges Sheet gilt nicht mehr.
        ratingOffered = false
        pendingRatingPrompt = nil
        let number = streamLoad
        let item = stream.items[index]
        let isFirstMain = index == firstMainIndex

        // Über einem Vorspann steht schon der Titel, der danach kommt.
        let main = item.isIntro ? (stream.items[index...].first { !$0.isIntro } ?? item) : item
        windowTitle = main.displayTitle
        setTitles(title: main.title, isEpisode: main.isEpisode, series: main.seriesName,
                  season: main.seasonNumber, episode: main.episodeNumber, year: main.year)
        isIntro = item.isIntro
        headline = item.isIntro ? "Vorspann" : mainHeadline
        subline = item.isIntro ? mainHeadline : mainSubline

        var startAt: TimeInterval = 0
        if let resumeAt {
            startAt = max(0, resumeAt)
        } else if isFirstMain, !item.isIntro {
            let wanted = Ticks.seconds(stream.startPositionTicks)
            startAt = item.duration > 0 && wanted / item.duration > 0.95 ? 0 : (wanted < 1 ? 0 : wanted)
        }
        isLoaded = false
        errorMessage = nil
        position = startAt
        duration = item.duration

        let api = self.api
        let token = stream.accessToken
        let bitrate = item.isIntro ? nil : streamQuality.maxBitrate
        let wantedAudio = overrideAudioIndex ?? (isFirstMain ? stream.audioStreamIndex : nil)
        let wantedSubtitle = overrideSubtitleIndex ?? (isFirstMain ? stream.subtitleStreamIndex : nil)
        Task { [weak self] in
            let requestedSourceId = isFirstMain ? stream.mediaSourceId : nil
            var source: JellyfinAPIService.PlaybackSource?
            var transcodeURL: URL?
            if let bitrate {
                // Kleiner gerechnet vom Server. Klappt das nicht (oder liegt die Datei gar nicht auf dem
                // Server), läuft das Original.
                let request = JellyfinAPIService.TranscodeRequest(maxBitrate: bitrate, audioStreamIndex: wantedAudio,
                                                                  subtitleStreamIndex: wantedSubtitle)
                if let transcoded = try? await api.playbackSource(server: stream.serverUrl, itemId: item.itemId, userId: stream.userId,
                                                                  token: token, mediaSourceId: requestedSourceId, transcode: request),
                   transcoded.remoteURL == nil, let path = transcoded.transcodingPath,
                   let url = Self.serverURL(path, base: stream.serverUrl), url.hasSameOrigin(as: stream.serverUrl) {
                    source = transcoded
                    transcodeURL = url
                }
            }
            if source == nil {
                source = try? await api.playbackSource(server: stream.serverUrl, itemId: item.itemId, userId: stream.userId,
                                                       token: token, mediaSourceId: requestedSourceId)
            }
            guard let self, !self.closed, self.streamLoad == number else { return }
            self.streamSource = source
            self.isTranscoding = transcodeURL != nil
            self.activeAudioIndex = transcodeURL == nil ? nil : (wantedAudio ?? source?.defaultAudioIndex)
            self.activeSubtitleIndex = transcodeURL == nil ? nil : (wantedSubtitle ?? source?.defaultSubtitleIndex)
            let mediaSourceId = source?.mediaSourceId ?? item.itemId
            // Dateien außerhalb des Servers holt die App unter der genannten Adresse; über den Server gereicht ließe
            // sich darin nicht springen.
            guard let url = transcodeURL ?? source?.remoteURL ?? JellyfinAPIService.streamURL(
                server: stream.serverUrl, itemId: item.itemId, mediaSourceId: mediaSourceId,
                playSessionId: source?.playSessionId ?? "") else {
                self.errorMessage = "Die Adresse des Titels ließ sich nicht bilden."
                return
            }
            // Nur das Token: die übrigen Angaben der Kopfzeile kennt der Server aus der Anmeldung. An fremde
            // Adressen geht es nicht.
            let ownServer = url.host == stream.serverUrl.host && url.port == stream.serverUrl.port
            self.load(url: url, kind: .mpv, startAt: startAt, fallbackDuration: item.duration,
                      headers: ownServer ? ["Authorization": "MediaBrowser Token=\"\(token)\""] : [:])
            guard !item.isIntro,
                  let info = await api.trickplayInfo(server: stream.serverUrl, itemId: item.itemId, userId: stream.userId,
                                                     token: token, mediaSourceId: mediaSourceId),
                  !self.closed, self.streamLoad == number else { return }
            self.trickplay = TrickplayProvider(info: info) { sheet in
                await api.trickplaySheet(server: stream.serverUrl, itemId: item.itemId, info: info, index: sheet, token: token)
            }
        }
    }

    /// Sobald die Datei offen ist: externe Untertitel anhängen und die Spuren wählen, die die
    /// Weboberfläche bzw. der Server für diesen Nutzer vorsieht.
    private func applyStreamTracks() {
        guard let stream, let engine, let source = streamSource, !isIntro else { return }
        let item = stream.items[streamIndex]
        let isFirstMain = streamIndex == firstMainIndex

        if isTranscoding {
            // Der Server liefert genau die gewählte Tonspur; Bild-Untertitel sind eingebrannt, Text-Untertitel
            // kommen als eigene Datei.
            engine.selectSubtitleTrack(id: nil)
            if let wanted = activeSubtitleIndex, wanted >= 0,
               let track = source.tracks.first(where: { !$0.isAudio && $0.index == wanted }),
               track.deliveryMethod == "External", let path = track.deliveryPath,
               let url = Self.serverURL(path, base: stream.serverUrl), url.hasSameOrigin(as: stream.serverUrl) {
                engine.addSubtitle(url: url, title: track.title, language: track.language, select: true)
            }
            return
        }

        let wantedAudio = overrideAudioIndex ?? (isFirstMain ? stream.audioStreamIndex : nil) ?? source.defaultAudioIndex
        let wantedSubtitle = overrideSubtitleIndex ?? (isFirstMain ? stream.subtitleStreamIndex : nil) ?? source.defaultSubtitleIndex

        // mpv zählt die Spuren je Art ab 1 in der Reihenfolge der Datei; der Server zählt alle
        // Spuren gemeinsam. Entscheidend ist deshalb der Platz unter den Spuren derselben Art.
        let audio = source.tracks.filter { $0.isAudio && !$0.isExternal }.sorted { $0.index < $1.index }
        if let wantedAudio, let place = audio.firstIndex(where: { $0.index == wantedAudio }),
           engine.audioTracks.contains(where: { $0.id == place + 1 }) {
            engine.selectAudioTrack(id: place + 1)
        }

        let internalSubtitles = source.tracks.filter { !$0.isAudio && !$0.isExternal }.sorted { $0.index < $1.index }
        let chosen = wantedSubtitle.flatMap { wanted in source.tracks.first { !$0.isAudio && $0.index == wanted } }
        if let chosen, !chosen.isExternal, let place = internalSubtitles.firstIndex(where: { $0.index == chosen.index }),
           engine.subtitleTracks.contains(where: { $0.id == place + 1 }) {
            engine.selectSubtitleTrack(id: place + 1)
        } else if chosen == nil, wantedSubtitle != nil || source.defaultSubtitleIndex == nil {
            engine.selectSubtitleTrack(id: nil)
        }
        for track in source.tracks where !track.isAudio && track.isExternal {
            let path = track.deliveryPath
                ?? "/Videos/\(item.itemId)/\(source.mediaSourceId)/Subtitles/\(track.index)/0/Stream.\(track.codec.isEmpty ? "srt" : track.codec)"
            guard let url = Self.serverURL(path, base: stream.serverUrl), url.hasSameOrigin(as: stream.serverUrl) else { continue }
            engine.addSubtitle(url: url, title: track.title, language: track.language, select: track.index == chosen?.index)
        }
    }

    /// Eine Adresse, die der Server relativ zu sich nennt (Untertitel, HLS-Wiedergabeliste).
    private static func serverURL(_ path: String, base: URL) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: root + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func reportStream(_ kind: JellyfinAPIService.PlaybackReport, position override: TimeInterval? = nil) {
        guard let stream, !isIntro, streamIndex < stream.items.count else { return }
        if kind != .start, !streamReported { return }
        if kind == .start { streamReported = true }
        if kind == .stopped { streamReported = false }
        let item = stream.items[streamIndex]
        let seconds = override ?? engine?.position ?? position
        let api = self.api
        let source = streamSource
        let paused = engine?.isPaused ?? true
        lastReportedPause = paused
        let level = volume
        let transcoding = isTranscoding
        let rate = speed
        streams.track {
            await api.report(kind, server: stream.serverUrl, token: stream.accessToken, itemId: item.itemId,
                             mediaSourceId: source?.mediaSourceId ?? item.itemId, playSessionId: source?.playSessionId ?? "",
                             positionTicks: Ticks.from(seconds: seconds.isFinite ? seconds : 0), isPaused: paused, volume: level,
                             transcoding: transcoding, speed: rate)
        }
    }

    /// Überspringt den laufenden Vorspann.
    func skipIntro() {
        guard isIntro else { return }
        if stream != nil { playStream(at: streamIndex + 1) } else { playNext() }
    }

    /// Beim Schließen des Fensters: Stand sichern, Player freigeben, Abgleich anstoßen.
    func close() {
        guard !closed else { return }
        closed = true
        pictureInPicture.stop()
        if let fullscreenExitObserver { NotificationCenter.default.removeObserver(fullscreenExitObserver) }
        fullscreenExitObserver = nil
        if stream != nil {
            reportStream(.stopped)
            streams.discard(itemID)
        } else {
            saveProgress()
            store.nowPlaying.remove(itemID)
            store.saveNow()
        }

        saveTimer?.invalidate()
        saveTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        removeRemoteCommands()
        allowSleep()

        engine?.shutdown()
        engine = nil
        if stream == nil { sync.syncSoon() }
    }

    // MARK: Position sichern

    /// Schreibt die Position in den Store. Über 90 % gilt der Titel als gesehen.
    func saveProgress() {
        guard let engine, isLoaded, !isIntro else { return }
        if stream != nil {
            reportStream(.progress)
            // Für Streams gibt es keinen lokalen Gesehen-Stand; „gesehen“ führt der Server.
            // Trotzdem hier prüfen, ob die 90-%-Schwelle das Sheet auslöst.
            if let total = engine.duration as TimeInterval?, total > 0,
               engine.position.isFinite, engine.position / total > 0.9 {
                maybeOfferRating()
            }
            return
        }
        let total = engine.duration
        let current = engine.position
        guard total > 0, current.isFinite else { return }

        let ticks = Ticks.from(seconds: current)
        let watched = current / total > 0.9
        if watched { maybeOfferRating() }
        guard ticks != lastSavedTicks else { return }   // nichts Neues, z. B. pausiert
        lastSavedTicks = ticks

        store.update(itemID) {
            if watched {
                $0.played = true
                $0.positionTicks = 0
                $0.pendingMarkPlayed = true
            } else {
                // Ein noch nicht gemeldetes „gesehen“ bleibt bestehen, auch wenn danach
                // zurückgespult wird; es wird erst nach dem Abgleich gelöscht.
                $0.positionTicks = ticks
            }
            $0.positionUpdatedAt = Date()
            $0.needsSync = true
        }
    }

    // MARK: Bewertung

    /// Prüft, ob für den aktuell laufenden Hauptfilm das Sheet gezeigt werden soll,
    /// und setzt `pendingRatingPrompt` entsprechend. Darf mehrfach aufgerufen werden;
    /// schlägt nach einem Treffer je Wiedergabe-Sitzung nicht noch einmal an.
    private func maybeOfferRating() {
        guard !ratingOffered, !isIntro, pendingRatingPrompt == nil else { return }

        // Nur Filme, keine Folgen, kein Mediathek-/Kanal-Titel.
        if let stream, streamIndex < stream.items.count {
            let item = stream.items[streamIndex]
            guard item.itemType == "Movie", !item.isIntro, streamSource?.remoteURL == nil else { return }
            let credentialRef = credentials.upsert(serverId: stream.serverId, serverUrl: stream.serverUrl,
                                                   userId: stream.userId, accessToken: stream.accessToken)
            // Darf laut Server-Einstellung gefragt werden? Fehlt der Stand, trotzdem fragen.
            if let cache = ratings.ratePromptCache(for: stream.serverUrl), cache.ratePrompt == false { return }
            let askedCache = ratings.askedCache(server: stream.serverUrl, userId: stream.userId)
            if askedCache.off || askedCache.isAsked(item.itemId) { return }
            if ratings.hasPending(itemId: item.itemId, userId: stream.userId, server: stream.serverUrl) { return }

            ratingOffered = true
            var context = RatingContext(itemId: item.itemId, tmdbId: nil, serverId: stream.serverId,
                                        serverUrl: stream.serverUrl, credentialRef: credentialRef,
                                        userId: stream.userId, title: item.title, year: item.year)
            pendingRatingPrompt = context
            // TMDb-Kennung online nachziehen; bei Erfolg Sheet-Kontext ergänzen.
            let api = self.api, server = stream.serverUrl, userId = stream.userId, token = stream.accessToken
            Task { [weak self] in
                let providers = await api.providerIds(server: server, itemId: item.itemId, userId: userId, token: token)
                if let tmdb = providers["Tmdb"].flatMap(Int.init) {
                    context.tmdbId = tmdb
                    await MainActor.run {
                        guard let self, self.pendingRatingPrompt?.itemId == item.itemId else { return }
                        self.pendingRatingPrompt = context
                    }
                }
            }
            return
        }

        guard let item = store.item(itemID), item.itemType == "Movie" else { return }
        if let cache = ratings.ratePromptCache(for: item.serverUrl), cache.ratePrompt == false { return }
        guard let credential = credentials.credential(ref: item.credentialRef) else { return }
        let askedCache = ratings.askedCache(server: item.serverUrl, userId: credential.userId)
        if askedCache.off || askedCache.isAsked(item.itemId) { return }
        if ratings.hasPending(itemId: item.itemId, userId: credential.userId, server: item.serverUrl) { return }

        ratingOffered = true
        pendingRatingPrompt = RatingContext(
            itemId: item.itemId, tmdbId: item.tmdbId, serverId: item.serverId,
            serverUrl: item.serverUrl, credentialRef: item.credentialRef,
            userId: credential.userId, title: item.title, year: item.year)
    }

    private func enqueue(_ action: PendingRating.Action, draft: RatingDraft?) {
        guard let context = pendingRatingPrompt else { return }
        let dateString = draft?.watchedDate.map { Self.formatDate($0) } ?? nil
        let entry = PendingRating(
            id: UUID().uuidString,
            itemId: context.itemId,
            tmdbId: context.tmdbId,
            serverId: context.serverId,
            serverUrlString: context.serverUrl.absoluteString,
            credentialRef: context.credentialRef,
            userId: context.userId,
            action: action,
            stars: draft?.stars,
            liked: draft?.liked ?? false,
            watchedDate: dateString,
            comment: draft?.comment ?? "",
            containsSpoilers: draft?.containsSpoilers ?? false,
            rewatch: draft?.rewatch ?? false,
            createdAt: Date()
        )
        ratings.enqueue(entry)
        ratings.markAskedLocally(itemId: context.itemId, server: context.serverUrl,
                                 userId: context.userId, off: action == .off)
        pendingRatingPrompt = nil
        sync.syncSoon()
    }

    func submitRating(_ draft: RatingDraft) { enqueue(.save, draft: draft) }
    func postponeRating() { enqueue(.later, draft: nil) }
    func disableRatingPrompt() { enqueue(.off, draft: nil) }
    /// Sheet ohne Wahl geschlossen (z. B. Fenster weg): Id NICHT eintragen, damit Cinema Glass
    /// das nächste Mal online von selbst fragt.
    func dismissRatingSheet() { pendingRatingPrompt = nil }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Bedienung

    func togglePause() {
        engine?.togglePause()
    }

    func seek(to seconds: TimeInterval) {
        engine?.seek(to: seconds)
        position = seconds
        updateNowPlaying()
    }

    func skip(_ delta: TimeInterval) {
        guard let engine else { return }
        seek(to: max(0, engine.position + delta))
    }

    func toggleFullscreen() {
        // Im Bild-in-Bild gehört die Ansicht nicht zum Player-Fenster.
        guard let engine, !pictureInPicture.isActive else { return }
        engine.setFullscreen(!engine.isFullscreen)
    }

    // MARK: Geschwindigkeit, Qualität, Bild-in-Bild

    func setSpeed(_ value: Double) {
        speed = min(4, max(0.25, value))
        engine?.speed = speed
        updateNowPlaying()
        if stream != nil, isLoaded, streamReported { reportStream(.progress) }
    }

    /// Ob sich die Qualität für den laufenden Titel wählen lässt: nur bei Streams vom eigenen Server.
    var canChangeQuality: Bool {
        stream != nil && !isIntro && streamSource?.remoteURL == nil
    }

    /// Merkt sich die Wahl (gilt auch für folgende Titel und Fenster) und lädt den laufenden Titel
    /// in der neuen Qualität an derselben Stelle neu.
    func selectQuality(_ quality: StreamQuality) {
        guard quality != streamQuality else { return }
        streamQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: SettingsKeys.streamQuality)
        guard canChangeQuality, isLoaded else { return }
        rememberCurrentTracks()
        reloadCurrentStream()
    }

    /// Hält die gerade gewählten Spuren in der Zählung des Servers fest, damit sie nach dem Neuladen
    /// wieder gelten.
    private func rememberCurrentTracks() {
        guard let source = streamSource else { return }
        if isTranscoding {
            overrideAudioIndex = activeAudioIndex
            overrideSubtitleIndex = activeSubtitleIndex ?? -1
            return
        }
        guard let engine else { return }
        let audio = source.tracks.filter { $0.isAudio && !$0.isExternal }.sorted { $0.index < $1.index }
        if let id = engine.selectedAudioTrackID, audio.indices.contains(id - 1) {
            overrideAudioIndex = audio[id - 1].index
        }
        guard let id = engine.selectedSubtitleTrackID,
              let selected = engine.subtitleTracks.first(where: { $0.id == id }) else {
            overrideSubtitleIndex = -1
            return
        }
        if selected.isExternal {
            overrideSubtitleIndex = source.tracks.first { !$0.isAudio && $0.isExternal && $0.title == selected.title }?.index
        } else {
            let subtitles = source.tracks.filter { !$0.isAudio && !$0.isExternal }.sorted { $0.index < $1.index }
            overrideSubtitleIndex = subtitles.indices.contains(id - 1) ? subtitles[id - 1].index : nil
        }
    }

    private func reloadCurrentStream() {
        let at = engine?.position ?? position
        // Der Server beendet damit auch eine laufende Umrechnung.
        reportStream(.stopped)
        playStream(at: streamIndex, resumeAt: at)
    }

    var canPictureInPicture: Bool { PictureInPicture.isAvailable && engine != nil && isLoaded }

    func togglePictureInPicture() {
        if pictureInPicture.isActive {
            pictureInPicture.stop()
            return
        }
        guard let engine, PictureInPicture.isAvailable else { return }
        if engine.isFullscreen, let window = engine.view.window {
            // Erst aus dem Vollbild heraus, sonst bliebe ein leerer Vollbild-Space zurück.
            fullscreenExitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.fullscreenExitObserver { NotificationCenter.default.removeObserver(observer) }
                    self.fullscreenExitObserver = nil
                    self.enterPictureInPicture()
                }
            }
            engine.setFullscreen(false)
            return
        }
        enterPictureInPicture()
    }

    private func enterPictureInPicture() {
        guard let engine, !closed, !pictureInPicture.isActive else { return }
        pictureInPicture.start(view: engine.view, aspect: engine.videoAspect, playing: !engine.isPaused)
        isPictureInPicture = pictureInPicture.isActive
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
        }
    }

    func selectAudio(_ track: MediaTrack) {
        if isTranscoding {
            // Während der Umrechnung zählen die Spuren des Servers; er rechnet mit der neuen Spur neu.
            guard track.id != activeAudioIndex else { return }
            overrideAudioIndex = track.id
            overrideSubtitleIndex = activeSubtitleIndex ?? -1
            reloadCurrentStream()
            return
        }
        engine?.selectAudioTrack(id: track.id)
        guard !isIntro, stream == nil else { return }
        store.update(itemID) {
            $0.audioPreference = TrackPreference(trackID: track.id, language: track.language, title: track.title)
        }
    }

    /// nil schaltet die Untertitel aus.
    func selectSubtitle(_ track: MediaTrack?) {
        if isTranscoding {
            let wanted = track?.id ?? -1
            guard wanted != (activeSubtitleIndex ?? -1) else { return }
            overrideAudioIndex = activeAudioIndex
            overrideSubtitleIndex = wanted
            reloadCurrentStream()
            return
        }
        engine?.selectSubtitleTrack(id: track?.id)
        guard !isIntro, stream == nil else { return }
        store.update(itemID) {
            $0.subtitlePreference = track.map {
                TrackPreference(trackID: $0.id, language: $0.language, title: $0.title)
            } ?? TrackPreference(off: true)
        }
    }

    /// Wendet die pro Titel gemerkte Spurwahl an, sobald die Spuren bekannt sind.
    private func applyStoredPreferences() {
        guard !preferencesApplied, !isIntro, stream == nil, let engine, let item = store.item(itemID) else { return }
        preferencesApplied = true

        func match(_ preference: TrackPreference, in tracks: [MediaTrack]) -> MediaTrack? {
            // Erst dieselbe Spur, dann eine mit gleicher Sprache und gleichem Titel
            // (die Nummer verschiebt sich, wenn externe Untertitel dazukommen).
            if let exact = tracks.first(where: {
                $0.id == preference.trackID && $0.language == preference.language && $0.title == preference.title
            }) { return exact }
            return tracks.first { $0.language == preference.language && $0.title == preference.title }
        }

        if let preference = item.audioPreference, let track = match(preference, in: engine.audioTracks) {
            engine.selectAudioTrack(id: track.id)
        }
        if let preference = item.subtitlePreference {
            if preference.off {
                engine.selectSubtitleTrack(id: nil)
            } else if let track = match(preference, in: engine.subtitleTracks) {
                engine.selectSubtitleTrack(id: track.id)
            }
        }
    }

    // MARK: Tastatur

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.engine?.view.window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 49: self.togglePause()                                   // Leertaste
            case 123: self.skip(-10)                                      // Pfeil links
            case 124: self.skip(10)                                       // Pfeil rechts
            case 126: self.volume = min(1, self.volume + 0.05)            // Pfeil hoch
            case 125: self.volume = max(0, self.volume - 0.05)            // Pfeil runter
            case 3: self.toggleFullscreen()                               // F
            case 46: self.toggleMute()                                    // M
            case 35: self.togglePictureInPicture()                        // P
            case 53:                                                      // Esc
                guard self.engine?.isFullscreen == true else { return event }
                self.toggleFullscreen()
            default: return event
            }
            return nil
        }
    }

    // MARK: Medientasten und „Jetzt läuft“

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                guard self != nil else { return .commandFailed }
                action(event)
                return .success
            }
            remoteTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] _ in self?.engine?.play() }
        add(center.pauseCommand) { [weak self] _ in self?.engine?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePause() }
        center.skipForwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(10) }
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(-10) }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
    }

    private func removeRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: windowTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        center.playbackState = isPaused ? .paused : .playing
    }

    // MARK: Ruhezustand

    private func preventSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Videowiedergabe")
    }

    private func allowSleep() {
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
    }
}

// MARK: - PlayerEngineDelegate

extension PlayerViewModel: PlayerEngineDelegate {
    private func refreshState(from engine: PlayerEngine) {
        isPaused = engine.isPaused
        pictureInPicture.setPlaying(!isPaused)
        if isTranscoding, let source = streamSource {
            // In der HLS-Fassung steckt nur die eine gewählte Tonspur; das Menü zeigt deshalb die Spuren
            // des Servers, und eine andere Wahl lässt ihn neu rechnen.
            func track(_ t: JellyfinAPIService.StreamTrack) -> MediaTrack {
                MediaTrack(id: t.index, kind: t.isAudio ? .audio : .subtitle, title: t.title, language: t.language,
                           codec: t.codec, channels: t.channels, isExternal: t.isExternal, isForced: t.isForced)
            }
            audioTracks = source.tracks.filter(\.isAudio).map(track)
            subtitleTracks = source.tracks.filter { !$0.isAudio }.map(track)
            selectedAudioTrackID = activeAudioIndex
            selectedSubtitleTrackID = (activeSubtitleIndex ?? -1) >= 0 ? activeSubtitleIndex : nil
        } else {
            audioTracks = engine.audioTracks
            subtitleTracks = engine.subtitleTracks
            selectedAudioTrackID = engine.selectedAudioTrackID
            selectedSubtitleTrackID = engine.selectedSubtitleTrackID
        }
        if isPaused { allowSleep() } else { preventSleep() }
        updateNowPlaying()
    }

    func engineDidLoad(_ engine: PlayerEngine) {
        guard engine === self.engine else { return }
        // Das Player-Fenster soll beim nächsten App-Start nicht von selbst wieder aufgehen.
        engine.view.window?.isRestorable = false
        isLoaded = true
        pictureInPicture.setAspect(engine.videoAspect)
        duration = engine.duration
        position = engine.position
        applyStoredPreferences()
        if stream != nil {
            applyStreamTracks()
            reportStream(.start)
        }
        refreshState(from: engine)
    }

    func engineDidUpdateTime(_ engine: PlayerEngine) {
        guard engine === self.engine, isLoaded else { return }
        position = engine.position
        if engine.duration != duration { duration = engine.duration }
    }

    func engineDidUpdateState(_ engine: PlayerEngine) {
        guard engine === self.engine else { return }
        refreshState(from: engine)
        // Pause und Fortsetzen sofort melden, damit der Stand auf dem Server stimmt.
        if stream != nil, isLoaded, streamReported, lastReportedPause != engine.isPaused {
            reportStream(.progress)
        }
    }

    func engineDidReachEnd(_ engine: PlayerEngine) {
        // Nur für die gerade geladene Datei; ein verspätetes Ende der vorigen wird übergangen.
        guard engine === self.engine, isLoaded else { return }
        if stream != nil {
            // Das Ende gilt dem Server als gesehen; danach folgt der nächste Titel der Warteschlange.
            reportStream(.stopped, position: engine.duration)
            // Für Filme ohne Mediathek-/Kanal-Herkunft die Bewertungs-Frage anbieten, bevor der
            // nächste Titel startet.
            maybeOfferRating()
            if pendingRatingPrompt == nil {
                playStream(at: streamIndex + 1)
            } else {
                // Warten, bis das Sheet geschlossen ist; der Nutzer kann dann weiterschauen oder das Fenster schließen.
                self.engine?.pause()
            }
            return
        }
        if isIntro {
            playNext()
            return
        }
        position = engine.duration
        saveProgress()
        maybeOfferRating()
        engine.pause()
    }

    func engine(_ engine: PlayerEngine, didFailWith message: String) {
        guard engine === self.engine else { return }
        if stream != nil {
            // Ein kaputter Vorspann hält den Film nicht auf.
            if isIntro { playStream(at: streamIndex + 1) } else { errorMessage = message }
        } else if isIntro {
            // Ein kaputter Vorspann hält den Film nicht auf.
            playNext()
        } else if engine.kind == .avKit {
            // AVKit kommt mit der Datei nicht zurecht: mit mpv noch einmal versuchen.
            mainKind = .mpv
            playNext()
        } else {
            errorMessage = message
        }
    }
}
