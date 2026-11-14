import AppKit
import Libmpv

/// Was der Ereignis-Thread von libmpv an den Hauptthread meldet.
private enum MPVEvent {
    case fileLoaded(tracks: [MediaTrack], duration: Double)
    case time(Double)
    case duration(Double)
    case pause(Bool)
    case endReached
    case audioTrack(Int?)
    case subtitleTrack(Int?)
    case volume(Double)
    case tracks([MediaTrack])
    case failed(String)
}

/// Hält den mpv-Kontext und liest dessen Ereignisse auf einer eigenen Queue.
/// Die mpv-Client-API ist threadsicher; Befehle kommen vom Hauptthread.
private final class MPVCore: @unchecked Sendable {
    let handle: OpaquePointer
    private let queue = DispatchQueue(label: "JellyDesk.mpv.events", qos: .userInitiated)
    /// Wird auf der Ereignis-Queue aufgerufen.
    var onEvent: ((MPVEvent) -> Void)?
    /// Wird auf der Ereignis-Queue aufgerufen, bevor mpv die Videoausgabe einrichtet, mit dem
    /// Seitenverhältnis des Videos (nil: unbekannt). mpv wartet, bis der Aufruf zurückkehrt.
    var onPreload: ((CGFloat?) -> Void)?

    // Nur auf der Queue benutzt.
    private var destroyed = false
    private var lastReportedTime = -1.0

    init?() {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle
    }

    func installWakeup() {
        // Der Kontext hält diese Instanz fest, bis destroy() sie wieder freigibt.
        let context = Unmanaged.passRetained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue().wakeup()
        }, context)
    }

    private func wakeup() {
        queue.async { [self] in drainEvents() }
    }

    /// Beendet mpv. Läuft auf der Ereignis-Queue, damit kein Ereignis mehr gelesen wird,
    /// und abseits des Hauptthreads, weil das Schließen des Decoders kurz dauern kann.
    func destroy() {
        onEvent = nil
        onPreload = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        queue.async { [self] in
            destroyed = true
            mpv_terminate_destroy(handle)
            Unmanaged.passUnretained(self).release()
        }
    }

    // MARK: Eigenschaften

    func string(_ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func double(_ name: String) -> Double? {
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ name: String) -> Int? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }

    func flag(_ name: String) -> Bool? {
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    @discardableResult
    func set(_ name: String, _ value: String) -> Bool {
        mpv_set_property_string(handle, name, value) >= 0
    }

    /// Setzt eine Eigenschaft, ohne auf den mpv-Kern zu warten. Für Aufrufe vom Hauptthread:
    /// ein wartender Hauptthread könnte sich sonst mit dem Render-Thread verklemmen, der für den
    /// EDR-Modus seinerseits auf den Hauptthread wartet.
    func setAsync(_ name: String, _ value: String) {
        value.withCString { pointer in
            var copy: UnsafePointer<CChar>? = pointer
            mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &copy)
        }
    }

    // Nur auf der Queue benutzt.
    private var aspectNudged = false

    /// Veranlasst mpv, seine Videoausgabe neu einzustellen, ohne den Decoder anzuhalten. Die
    /// MoltenVK-Ausgabe liest die Größe der Zeichenfläche nur dabei. Auslöser ist eine Änderung
    /// der Bildparameter: das Seitenverhältnis wird abwechselnd um ein Zweitausendstel (unter
    /// einem Pixel) verstellt und wieder auf den Wert der Datei gesetzt.
    func reconfigureVideoOutput() {
        queue.async { [self] in
            guard !destroyed else { return }
            if aspectNudged {
                set("video-aspect-override", "-1")
                aspectNudged = false
            } else if let aspect = double("video-params/aspect"), aspect > 0 {
                set("video-aspect-override", String(format: "%.6f", aspect * 1.0005))
                aspectNudged = true
            }
        }
    }

    /// Vor dem Laden einer neuen Datei: die Verstellung zurücknehmen.
    func resetAspectNudge() {
        queue.async { [self] in
            guard !destroyed, aspectNudged else { return }
            set("video-aspect-override", "-1")
            aspectNudged = false
        }
    }

    @discardableResult
    func setOption(_ name: String, _ value: String) -> Bool {
        let status = mpv_set_option_string(handle, name, value)
        if status < 0 {
            NSLog("JellyDesk/mpv: Option %@=%@ abgelehnt: %s", name, value, mpv_error_string(status))
        }
        return status >= 0
    }

    func command(_ arguments: [String]) {
        var cArguments: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        cArguments.append(nil)
        defer { cArguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        // Asynchron, damit der Hauptthread beim Spulen nicht auf den Decoder wartet.
        mpv_command_async(handle, 0, &cArguments)
    }

    /// Seitenverhältnis der ersten echten Videospur laut Container (mit Pixelform und Drehung).
    func videoAspect() -> CGFloat? {
        let count = int("track-list/count") ?? 0
        for index in 0..<max(0, count) {
            let prefix = "track-list/\(index)/"
            guard string(prefix + "type") == "video",
                  flag(prefix + "albumart") != true, flag(prefix + "image") != true,
                  let width = int(prefix + "demux-w"), let height = int(prefix + "demux-h"),
                  width > 0, height > 0 else { continue }
            let par = double(prefix + "demux-par") ?? 1
            var aspect = CGFloat(width) * CGFloat(par > 0 ? par : 1) / CGFloat(height)
            let rotation = abs(int(prefix + "demux-rotation") ?? 0) % 180
            if rotation == 90 { aspect = 1 / aspect }
            return aspect
        }
        return nil
    }

    func readTracks() -> [MediaTrack] {
        let count = int("track-list/count") ?? 0
        var tracks: [MediaTrack] = []
        for index in 0..<max(0, count) {
            let prefix = "track-list/\(index)/"
            guard let type = string(prefix + "type"), let id = int(prefix + "id") else { continue }
            let kind: MediaTrack.Kind
            switch type {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue
            }
            var track = MediaTrack(id: id, kind: kind)
            track.title = string(prefix + "title")
            track.language = string(prefix + "lang")
            track.codec = string(prefix + "codec")
            track.channels = int(prefix + "demux-channel-count")
            track.isExternal = flag(prefix + "external") ?? false
            track.isDefault = flag(prefix + "default") ?? false
            track.isForced = flag(prefix + "forced") ?? false
            if track.isExternal, track.title == nil,
               let file = string(prefix + "external-filename") {
                track.title = URL(fileURLWithPath: file).lastPathComponent
            }
            tracks.append(track)
        }
        return tracks
    }

    // MARK: Ereignisse

    private func drainEvents() {
        while !destroyed {
            guard let event = mpv_wait_event(handle, 0) else { return }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                return

            case MPV_EVENT_HOOK:
                // „on_preloaded“: Datei ist geöffnet, die Videoausgabe aber noch nicht eingerichtet.
                // Jetzt die Zeichenfläche auf das Seitenverhältnis des Videos bringen, dann weiter.
                guard let data = event.pointee.data else { break }
                let hook = data.assumingMemoryBound(to: mpv_event_hook.self).pointee
                onPreload?(videoAspect())
                mpv_hook_continue(handle, hook.id)

            case MPV_EVENT_FILE_LOADED:
                lastReportedTime = -1
                onEvent?(.fileLoaded(tracks: readTracks(), duration: double("duration") ?? 0))

            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { break }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    onEvent?(.failed(String(cString: mpv_error_string(end.error))))
                } else if end.reason == MPV_END_FILE_REASON_EOF {
                    onEvent?(.endReached)
                }

            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { break }
                handleProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee)

            case MPV_EVENT_LOG_MESSAGE:
                guard let data = event.pointee.data else { break }
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                if let prefix = message.prefix, let text = message.text {
                    NSLog("mpv [%s] %s", prefix, text)
                }

            case MPV_EVENT_SHUTDOWN:
                return

            default:
                break
            }
        }
    }

    private func handleProperty(_ property: mpv_event_property) {
        guard let cName = property.name else { return }
        let name = String(cString: cName)

        func double() -> Double? {
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard property.format == MPV_FORMAT_FLAG, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func int() -> Int? {
            guard property.format == MPV_FORMAT_INT64, let data = property.data else { return nil }
            return Int(data.assumingMemoryBound(to: Int64.self).pointee)
        }

        switch name {
        case "time-pos":
            // Kommt mit jedem Bild; vier Meldungen pro Sekunde genügen der Oberfläche.
            guard let value = double(), abs(value - lastReportedTime) >= 0.25 else { return }
            lastReportedTime = value
            onEvent?(.time(value))
        case "duration":
            if let value = double() { onEvent?(.duration(value)) }
        case "pause":
            if let value = flag() { onEvent?(.pause(value)) }
        case "eof-reached":
            // Mit keep-open bleibt die Datei am Ende offen; das Ende zeigt diese Eigenschaft.
            if flag() == true { onEvent?(.endReached) }
        case "aid":
            onEvent?(.audioTrack(int()))
        case "sid":
            onEvent?(.subtitleTrack(int()))
        case "volume":
            if let value = double() { onEvent?(.volume(value)) }
        case "track-list/count":
            onEvent?(.tracks(readTracks()))
        default:
            break
        }
    }
}

/// Hauptplayer auf Basis von libmpv (MPVKit): spielt MKV/MP4 mit HEVC, H.264, DTS, TrueHD/Atmos,
/// E-AC3, PGS- und SRT-Untertiteln sowie HDR und Dolby Vision.
@MainActor
final class MPVPlayerEngine: PlayerEngine {
    private var httpHeaderFields = ""
    let kind = PlayerEngineKind.mpv
    weak var delegate: PlayerEngineDelegate?

    private let videoView = MPVVideoView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
    var view: NSView { videoView }

    private var core: MPVCore?
    private var fallbackDuration: TimeInterval = 0
    private var loaded = false
    private var refitting = false

    private(set) var position: TimeInterval = 0
    private var reportedDuration: TimeInterval = 0
    var duration: TimeInterval { reportedDuration > 0 ? reportedDuration : fallbackDuration }
    private(set) var isPaused = true
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioTrackID: Int?
    private(set) var selectedSubtitleTrackID: Int?

    var volume: Double = 1 {
        didSet {
            volume = min(1, max(0, volume))
            core?.setAsync("volume", String(format: "%.1f", volume * 100))
        }
    }

    /// `hdrDisplay`: der Bildschirm, auf dem das Fenster erscheint, kann HDR (EDR) darstellen.
    init(hdrDisplay: Bool) {
        guard let core = MPVCore() else { return }
        self.core = core

        // Ausgabe: libplacebo über Vulkan/MoltenVK in die Metal-Ebene der Ansicht.
        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(videoView.metalLayer).toOpaque()))
        mpv_set_option(core.handle, "wid", MPV_FORMAT_INT64, &layerPointer)
        core.setOption("vo", "gpu-next")
        core.setOption("gpu-api", "vulkan")
        core.setOption("gpu-context", "moltenvk")

        // Hardware-Dekodierung über VideoToolbox; was die Hardware nicht kann, dekodiert FFmpeg.
        core.setOption("hwdec", "videotoolbox")

        // HDR: an HDR-Bildschirmen durchreichen (Farbraum und Metadaten gehen an die Ebene),
        // sonst rechnet libplacebo per Tone-Mapping auf SDR herunter. Dolby Vision wird von
        // gpu-next dabei in HDR10 bzw. SDR umgesetzt. Die Option muss vor mpv_initialize stehen.
        core.setOption("target-colorspace-hint", hdrDisplay ? "yes" : "no")
        core.setOption("tone-mapping", "auto")
        core.setOption("hdr-compute-peak", "auto")

        // Datei am Ende offen halten, damit das Ende sauber gemeldet wird.
        core.setOption("keep-open", "yes")
        // Externe Untertitel neben dem Video finden (gleicher Namensanfang, z. B. Film.de.srt).
        core.setOption("sub-auto", "fuzzy")
        core.setOption("audio-file-auto", "no")
        core.setOption("subs-match-os-language", "yes")
        core.setOption("subs-fallback", "default")
        // Keine Lua-Skripte laden (stats, console, auto_profiles …). Sie laufen über LuaJIT, und
        // dessen zur Laufzeit erzeugten Code beendet die gehärtete Laufzeit sofort mit
        // „Code Signature Invalid“. Die App braucht keines davon.
        core.setOption("load-scripts", "no")
        for script in ["stats-overlay", "console", "auto-profiles", "select", "positioning", "commands", "context-menu"] {
            core.setOption("load-\(script)", "no")
        }
        // Die Oberfläche kommt von der App, nicht von mpv.
        core.setOption("osc", "no")
        core.setOption("osd-level", "0")
        core.setOption("input-default-bindings", "no")
        core.setOption("input-vo-keyboard", "no")
        core.setOption("input-media-keys", "no")
        core.setOption("config", "no")
        core.setOption("ytdl", "no")
        core.setOption("pause", "yes")
        core.setOption("volume-max", "100")

        mpv_request_log_messages(core.handle, "warn")

        let status = mpv_initialize(core.handle)
        guard status >= 0 else {
            NSLog("JellyDesk/mpv: Initialisierung fehlgeschlagen: %s", mpv_error_string(status))
            core.destroy()
            self.core = nil
            return
        }

        mpv_hook_add(core.handle, 0, "on_preloaded", 0)
        let view = videoView
        core.onPreload = { aspect in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { view.prepare(aspect: aspect) }
            }
        }
        view.onNeedsRefit = { [weak self] in
            MainActor.assumeIsolated { self?.refitVideoOutput() }
        }
        view.metalLayer.onPendingApplied = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refitFinished() }
            }
        }

        mpv_observe_property(core.handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(core.handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(core.handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(core.handle, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(core.handle, 0, "aid", MPV_FORMAT_INT64)
        mpv_observe_property(core.handle, 0, "sid", MPV_FORMAT_INT64)
        mpv_observe_property(core.handle, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(core.handle, 0, "track-list/count", MPV_FORMAT_INT64)

        core.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        core.installWakeup()
    }

    func load(url: URL, startAt: TimeInterval, fallbackDuration: TimeInterval) {
        self.fallbackDuration = fallbackDuration
        guard let core else {
            delegate?.engine(self, didFailWith: "libmpv konnte nicht gestartet werden.")
            return
        }
        loaded = false
        refitting = false
        core.resetAspectNudge()
        reportedDuration = 0
        position = max(0, startAt)
        // Gilt für die nächste geladene Datei.
        core.setAsync("start", startAt > 1 ? String(format: "%.3f", startAt) : "none")
        if url.isFileURL {
            core.setAsync("http-header-fields", "")
            core.setAsync("sub-auto", "fuzzy")
            core.command(["loadfile", url.path, "replace"])
        } else {
            // Stream vom Server: großzügig vorauslesen, damit Spulen und Funklöcher nicht stocken;
            // neben einer Adresse gibt es keine Untertiteldateien zu suchen.
            core.setAsync("http-header-fields", httpHeaderFields)
            core.setAsync("sub-auto", "no")
            core.setAsync("cache", "yes")
            core.setAsync("demuxer-max-bytes", "256MiB")
            core.setAsync("demuxer-max-back-bytes", "64MiB")
            core.setAsync("demuxer-readahead-secs", "30")
            core.setAsync("network-timeout", "30")
            core.command(["loadfile", url.absoluteString, "replace"])
        }
    }

    func setHTTPHeaders(_ headers: [String: String]) {
        // mpv trennt die Liste an Kommas; jede Zeile wird deshalb mit ihrer Länge angekündigt.
        httpHeaderFields = headers.sorted { $0.key < $1.key }.map { key, value in
            let line = "\(key): \(value)"
            return "%\(line.utf8.count)%\(line)"
        }.joined(separator: ",")
    }

    func addSubtitle(url: URL, title: String?, language: String?, select: Bool) {
        guard loaded else { return }
        var arguments = ["sub-add", url.isFileURL ? url.path : url.absoluteString, select ? "select" : "auto"]
        if let title, !title.isEmpty {
            arguments.append(title)
            if let language, !language.isEmpty { arguments.append(language) }
        }
        core?.command(arguments)
    }

    func play() { core?.setAsync("pause", "no") }
    func pause() { core?.setAsync("pause", "yes") }

    func seek(to seconds: TimeInterval) {
        guard loaded else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        core?.command(["seek", String(format: "%.3f", target), "absolute"])
    }

    func selectAudioTrack(id: Int) {
        core?.setAsync("aid", String(id))
    }

    func selectSubtitleTrack(id: Int?) {
        core?.setAsync("sid", id.map(String.init) ?? "no")
    }

    /// Nach einer Größenänderung (Fenster gezogen, Vollbild): mpv stellt seine Ausgabe auf die
    /// neue Pixelgröße um, damit das Bild scharf bleibt. Der Decoder läuft dabei weiter.
    private func refitVideoOutput() {
        guard let core else { return }
        guard loaded else {
            videoView.applyRenderSize()
            return
        }
        guard !refitting else { return }
        refitting = true
        videoView.beginRefit()
        core.reconfigureVideoOutput()
        // Kommt die Umstellung nicht zustande (z. B. keine Videospur), Ankündigung zurücknehmen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refitting else { return }
                self.videoView.metalLayer.announce(nil)
                self.refitting = false
            }
        }
    }

    private func refitFinished() {
        refitting = false
        // Hat sich das Fenster währenddessen weiter verändert, noch einmal.
        if videoView.needsRefit { refitVideoOutput() }
    }

    func shutdown() {
        videoView.onNeedsRefit = nil
        videoView.metalLayer.onPendingApplied = nil
        guard let core else { return }
        self.core = nil
        loaded = false
        core.destroy()
    }

    private func handle(_ event: MPVEvent) {
        guard core != nil else { return }
        switch event {
        case .fileLoaded(let tracks, let duration):
            loaded = true
            if duration > 0 { reportedDuration = duration }
            apply(tracks)
            core?.setAsync("start", "none")
            delegate?.engineDidLoad(self)
        case .time(let value):
            position = value
            delegate?.engineDidUpdateTime(self)
        case .duration(let value):
            if value > 0 { reportedDuration = value }
            delegate?.engineDidUpdateTime(self)
        case .pause(let value):
            isPaused = value
            delegate?.engineDidUpdateState(self)
        case .endReached:
            position = duration
            delegate?.engineDidReachEnd(self)
        case .audioTrack(let id):
            selectedAudioTrackID = id
            delegate?.engineDidUpdateState(self)
        case .subtitleTrack(let id):
            selectedSubtitleTrackID = id
            delegate?.engineDidUpdateState(self)
        case .volume:
            break
        case .tracks(let tracks):
            apply(tracks)
            delegate?.engineDidUpdateState(self)
        case .failed(let message):
            delegate?.engine(self, didFailWith: "mpv kann die Datei nicht abspielen (\(message)).")
        }
    }

    private func apply(_ tracks: [MediaTrack]) {
        audioTracks = tracks.filter { $0.kind == .audio }
        subtitleTracks = tracks.filter { $0.kind == .subtitle }
    }
}
