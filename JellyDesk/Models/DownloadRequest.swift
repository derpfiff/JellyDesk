import Foundation

/// Eine Nachricht des Themes über den Kanal „atvDownload“ (docs/NATIVE-BRIDGE.md, Version 1).
struct DownloadRequest: Identifiable {
    let id = UUID()

    let url: URL
    let filename: String
    let title: String
    let itemId: String
    let itemType: String
    let serverId: String
    let serverUrl: URL
    let userId: String
    let accessToken: String
    let runTimeTicks: Int64
    let quality: String
    let estimatedBytes: Int64
    let container: String
    let seriesName: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    let imageUrl: URL?
    let backdropUrl: URL?
    let positionTicks: Int64

    var isOriginal: Bool { quality == "orig" }
    var isEpisode: Bool { itemType == "Episode" }

    /// Anzeigename, bei Folgen mit Serie und Nummer.
    var displayTitle: String {
        guard isEpisode else { return title }
        var parts: [String] = []
        if !seriesName.isEmpty { parts.append(seriesName) }
        if let s = seasonNumber, let e = episodeNumber { parts.append(String(format: "S%02dE%02d", s, e)) }
        parts.append(title)
        return parts.joined(separator: " · ")
    }

    enum BridgeError: LocalizedError {
        case notAnObject
        case wrongType(String)
        case unsupportedVersion(Int)
        case missing(String)
        case invalidURL(String)
        case foreignDownloadURL

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "Die Nachricht ist kein Objekt."
            case .wrongType(let t): return "Unbekannter Nachrichtentyp „\(t)“."
            case .unsupportedVersion(let v): return "Nachrichtenversion \(v) wird nicht unterstützt (erwartet: 1)."
            case .missing(let key): return "Pflichtfeld „\(key)“ fehlt."
            case .invalidURL(let key): return "„\(key)“ ist keine gültige http(s)-Adresse."
            case .foreignDownloadURL: return "Die Lade-Adresse gehört nicht zum angegebenen Server."
            }
        }
    }

    /// Liest den Nachrichtenkörper, wie WebKit ihn liefert (NSDictionary mit NSString/NSNumber/NSNull).
    init(messageBody: Any) throws {
        guard let dict = messageBody as? [String: Any] else { throw BridgeError.notAnObject }

        func string(_ key: String) -> String {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func int64(_ key: String) -> Int64? {
            guard let number = dict[key] as? NSNumber else { return nil }
            let value = number.doubleValue
            guard value.isFinite, abs(value) < 9.0e18 else { return nil }
            return Int64(value.rounded())
        }
        func int(_ key: String) -> Int? { int64(key).map { Int($0) } }
        func required(_ key: String) throws -> String {
            let value = string(key)
            if value.isEmpty { throw BridgeError.missing(key) }
            return value
        }
        func webURL(_ key: String) -> URL? {
            guard let url = URL(string: string(key)), url.isWebURL else { return nil }
            return url
        }

        let type = string("type")
        guard type == "download" else { throw BridgeError.wrongType(type) }
        let version = int("version") ?? 0
        guard version == 1 else { throw BridgeError.unsupportedVersion(version) }

        _ = try required("url")
        guard let url = webURL("url") else { throw BridgeError.invalidURL("url") }
        _ = try required("serverUrl")
        guard let serverUrl = webURL("serverUrl") else { throw BridgeError.invalidURL("serverUrl") }
        // Das Token steckt als api_key in der Adresse; es darf nur an den genannten Server gehen.
        guard url.hasSameOrigin(as: serverUrl) else { throw BridgeError.foreignDownloadURL }

        self.url = url
        self.serverUrl = serverUrl
        self.itemId = try required("itemId")
        self.userId = try required("userId")
        self.accessToken = try required("accessToken")
        self.serverId = string("serverId")
        self.title = string("title").isEmpty ? "Ohne Titel" : string("title")
        self.itemType = string("itemType")
        self.quality = string("quality").isEmpty ? "orig" : string("quality")
        self.container = string("container")
        self.seriesName = string("seriesName")
        self.runTimeTicks = max(0, int64("runTimeTicks") ?? 0)
        self.estimatedBytes = max(0, int64("estimatedBytes") ?? 0)
        self.positionTicks = max(0, int64("positionTicks") ?? 0)
        self.seasonNumber = int("seasonNumber")
        self.episodeNumber = int("episodeNumber")
        self.year = int("year")

        // Bilder nur vom selben Server annehmen, sonst weglassen.
        let image = webURL("imageUrl"), backdrop = webURL("backdropUrl")
        self.imageUrl = image.flatMap { $0.hasSameOrigin(as: serverUrl) ? $0 : nil }
        self.backdropUrl = backdrop.flatMap { $0.hasSameOrigin(as: serverUrl) ? $0 : nil }

        // Der Dateiname stammt aus dem Serverpfad und wird nie als Pfad verwendet.
        let firstContainer = container.split(separator: ",").first.map(String.init) ?? ""
        let fallbackExt = quality == "orig" ? (firstContainer.isEmpty ? "mkv" : firstContainer) : "mp4"
        var name = FileNameSanitizer.component(string("filename"), fallback: "", isFileName: true)
        if name.isEmpty { name = FileNameSanitizer.component(title) + "." + fallbackExt }
        if (name as NSString).pathExtension.isEmpty { name += "." + fallbackExt }
        self.filename = name
    }
}
