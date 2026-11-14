import AppKit
import MediaPlayer

extension Notification.Name {
    /// Die App wird beendet: offene Player sichern ihren Stand.
    static let jellyDeskWillTerminate = Notification.Name("JellyDeskWillTerminate")
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

    /// Auftrag der Weboberfläche; nil bei einem Download.
    private var stream: StreamRequest?
    private var streamIndex = 0
    private var streamSource: JellyfinAPIService.PlaybackSource?
    /// Zählt die Ladevorgänge, damit eine verspätete Antwort keinen neueren Titel überschreibt.
    private var streamLoad = 0
    /// Der Beginn des laufenden Titels ist dem Server gemeldet.
    private var streamReported = false
    private var lastReportedPause: Bool?

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
         api: JellyfinAPIService, streams: StreamSessions) {
        self.intros = intros
        self.api = api
        self.streams = streams
        self.itemID = itemID
        self.store = store
        self.sync = sync
        self.volume = UserDefaults.standard.double(forKey: SettingsKeys.playerVolume)
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

    private func playStream(at index: Int) {
        guard let stream else { return }
        guard index < stream.items.count else {
            // Warteschlange zu Ende: wie im Web-Player zurück zur Oberfläche.
            engine?.view.window?.close()
            return
        }
        streamIndex = index
        streamSource = nil
        streamReported = false
        lastReportedPause = nil
        trickplay = nil
        streamLoad += 1
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
        if isFirstMain, !item.isIntro {
            let wanted = Ticks.seconds(stream.startPositionTicks)
            startAt = item.duration > 0 && wanted / item.duration > 0.95 ? 0 : (wanted < 1 ? 0 : wanted)
        }
        isLoaded = false
        errorMessage = nil
        position = startAt
        duration = item.duration

        let api = self.api
        let token = stream.accessToken
        Task { [weak self] in
            let source = try? await api.playbackSource(server: stream.serverUrl, itemId: item.itemId, userId: stream.userId,
                                                       token: token, mediaSourceId: isFirstMain ? stream.mediaSourceId : nil)
            guard let self, !self.closed, self.streamLoad == number else { return }
            self.streamSource = source
            let mediaSourceId = source?.mediaSourceId ?? item.itemId
            // Dateien außerhalb des Servers holt die App unter der genannten Adresse; über den Server gereicht ließe
            // sich darin nicht springen.
            guard let url = source?.remoteURL ?? JellyfinAPIService.streamURL(
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
        let wantedAudio = (isFirstMain ? stream.audioStreamIndex : nil) ?? source.defaultAudioIndex
        let wantedSubtitle = (isFirstMain ? stream.subtitleStreamIndex : nil) ?? source.defaultSubtitleIndex

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
            let base = stream.serverUrl.absoluteString.hasSuffix("/") ? String(stream.serverUrl.absoluteString.dropLast()) : stream.serverUrl.absoluteString
            guard let url = URL(string: path.hasPrefix("http") ? path : base + (path.hasPrefix("/") ? path : "/" + path)),
                  url.hasSameOrigin(as: stream.serverUrl) else { continue }
            engine.addSubtitle(url: url, title: track.title, language: track.language, select: track.index == chosen?.index)
        }
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
        streams.track {
            await api.report(kind, server: stream.serverUrl, token: stream.accessToken, itemId: item.itemId,
                             mediaSourceId: source?.mediaSourceId ?? item.itemId, playSessionId: source?.playSessionId ?? "",
                             positionTicks: Ticks.from(seconds: seconds.isFinite ? seconds : 0), isPaused: paused, volume: level)
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
            return
        }
        let total = engine.duration
        let current = engine.position
        guard total > 0, current.isFinite else { return }

        let ticks = Ticks.from(seconds: current)
        guard ticks != lastSavedTicks else { return }   // nichts Neues, z. B. pausiert
        lastSavedTicks = ticks
        let watched = current / total > 0.9

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
        guard let engine else { return }
        engine.setFullscreen(!engine.isFullscreen)
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
        engine?.selectAudioTrack(id: track.id)
        guard !isIntro, stream == nil else { return }
        store.update(itemID) {
            $0.audioPreference = TrackPreference(trackID: track.id, language: track.language, title: track.title)
        }
    }

    /// nil schaltet die Untertitel aus.
    func selectSubtitle(_ track: MediaTrack?) {
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
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
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
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        selectedAudioTrackID = engine.selectedAudioTrackID
        selectedSubtitleTrackID = engine.selectedSubtitleTrackID
        if isPaused { allowSleep() } else { preventSleep() }
        updateNowPlaying()
    }

    func engineDidLoad(_ engine: PlayerEngine) {
        guard engine === self.engine else { return }
        // Das Player-Fenster soll beim nächsten App-Start nicht von selbst wieder aufgehen.
        engine.view.window?.isRestorable = false
        isLoaded = true
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
            playStream(at: streamIndex + 1)
            return
        }
        if isIntro {
            playNext()
            return
        }
        position = engine.duration
        saveProgress()
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
