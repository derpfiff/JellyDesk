import AppKit

/// Eine Ton- oder Untertitelspur.
struct MediaTrack: Identifiable, Equatable {
    enum Kind { case audio, subtitle }

    let id: Int
    let kind: Kind
    var title: String?
    var language: String?
    var codec: String?
    var channels: Int?
    var isExternal = false
    var isDefault = false
    var isForced = false

    var displayName: String {
        var parts: [String] = []
        if let language, !language.isEmpty, language != "und" {
            parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased())
        }
        if let title, !title.isEmpty { parts.append(title) }
        var details: [String] = []
        if let codec, !codec.isEmpty { details.append(Self.codecName(codec)) }
        if let channels, channels > 0 { details.append(Self.channelName(channels)) }
        if isForced { details.append("erzwungen") }
        if isExternal { details.append("extern") }
        if parts.isEmpty { parts.append("Spur \(id)") }
        return parts.joined(separator: " – ") + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
    }

    private static func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "eac3": return "E-AC3"
        case "ac3": return "AC3"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "hdmv_pgs_subtitle": return "PGS"
        case "subrip": return "SRT"
        case "ass": return "ASS"
        case "dvd_subtitle": return "VobSub"
        default: return codec.uppercased()
        }
    }

    private static func channelName(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) Kanäle"
        }
    }
}

enum PlayerEngineKind: String {
    case mpv = "mpv"
    case avKit = "AVKit"
}

@MainActor
protocol PlayerEngineDelegate: AnyObject {
    /// Datei ist geöffnet, Spuren und Dauer sind bekannt.
    func engineDidLoad(_ engine: PlayerEngine)
    /// Position oder Dauer hat sich geändert.
    func engineDidUpdateTime(_ engine: PlayerEngine)
    /// Pause, Spurliste, Spurwahl oder Lautstärke hat sich geändert.
    func engineDidUpdateState(_ engine: PlayerEngine)
    func engineDidReachEnd(_ engine: PlayerEngine)
    func engine(_ engine: PlayerEngine, didFailWith message: String)
}

/// Gemeinsame Schnittstelle der Player: libmpv für alle Formate, AVKit für MP4/MOV.
@MainActor
protocol PlayerEngine: AnyObject {
    var kind: PlayerEngineKind { get }
    /// Die Ansicht, in die das Bild gezeichnet wird.
    var view: NSView { get }
    var delegate: PlayerEngineDelegate? { get set }

    /// Lädt eine lokale Datei oder eine Adresse und springt an `startAt` (Sekunden). `fallbackDuration`
    /// gilt, solange die Datei selbst keine Dauer nennt.
    func load(url: URL, startAt: TimeInterval, fallbackDuration: TimeInterval)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)

    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPaused: Bool { get }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioTrackID: Int? { get }
    /// nil: Untertitel aus.
    var selectedSubtitleTrackID: Int? { get }
    func selectAudioTrack(id: Int)
    func selectSubtitleTrack(id: Int?)

    /// 0…1
    var volume: Double { get set }

    var isFullscreen: Bool { get }
    func setFullscreen(_ on: Bool)

    /// Kopfzeilen für die nächste über das Netz geladene Datei (Anmeldung am Server).
    func setHTTPHeaders(_ headers: [String: String])
    /// Hängt eine Untertiteldatei an den laufenden Titel und wählt sie auf Wunsch aus.
    func addSubtitle(url: URL, title: String?, language: String?, select: Bool)

    /// Gibt Decoder und Datei frei. Danach ist der Player nicht mehr benutzbar.
    func shutdown()
}

extension PlayerEngine {
    var isFullscreen: Bool {
        view.window?.styleMask.contains(.fullScreen) ?? false
    }

    func setFullscreen(_ on: Bool) {
        guard let window = view.window, isFullscreen != on else { return }
        window.toggleFullScreen(nil)
    }

    func togglePause() {
        if isPaused { play() } else { pause() }
    }

    func setHTTPHeaders(_ headers: [String: String]) {}
    func addSubtitle(url: URL, title: String?, language: String?, select: Bool) {}
}
