import Foundation

/// Ein Titel der Warteschlange, die die Weboberfläche abspielen wollte.
struct StreamItem: Equatable {
    let itemId: String
    let title: String
    let itemType: String
    let seriesName: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    let runTimeTicks: Int64
    /// Vorspann, den der Server vor den eigentlichen Titel gestellt hat.
    let isIntro: Bool

    var isEpisode: Bool { itemType == "Episode" }
    var duration: TimeInterval { Ticks.seconds(runTimeTicks) }

    var displayTitle: String {
        guard isEpisode else { return title }
        var parts: [String] = []
        if !seriesName.isEmpty { parts.append(seriesName) }
        if let s = seasonNumber, let e = episodeNumber { parts.append(String(format: "S%02dE%02d", s, e)) }
        parts.append(title)
        return parts.joined(separator: " · ")
    }
}

/// Eine Nachricht des Themes über den Kanal „atvPlay“ (docs/NATIVE-BRIDGE.md): die Weboberfläche
/// wollte diese Titel abspielen und überlässt sie der App. Zugangsdaten bleiben im Speicher und
/// werden nirgends abgelegt.
struct StreamRequest {
    let serverUrl: URL
    let serverId: String
    let userId: String
    let accessToken: String
    let items: [StreamItem]
    let startIndex: Int
    /// Gilt für den ersten eigentlichen Titel (nicht für einen Vorspann davor).
    let startPositionTicks: Int64
    let mediaSourceId: String?
    /// Spurnummern in der Zählung des Servers, falls in der Weboberfläche gewählt.
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum BridgeError: LocalizedError {
        case notAnObject
        case wrongType(String)
        case unsupportedVersion(Int)
        case missing(String)
        case invalidURL(String)
        case noItems

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "Die Nachricht ist kein Objekt."
            case .wrongType(let t): return "Unbekannter Nachrichtentyp „\(t)“."
            case .unsupportedVersion(let v): return "Nachrichtenversion \(v) wird nicht unterstützt (erwartet: 1)."
            case .missing(let key): return "Pflichtfeld „\(key)“ fehlt."
            case .invalidURL(let key): return "„\(key)“ ist keine gültige http(s)-Adresse."
            case .noItems: return "Die Nachricht enthält keinen abspielbaren Titel."
            }
        }
    }

    /// Liest den Nachrichtenkörper, wie WebKit ihn liefert (NSDictionary mit NSString/NSNumber/NSNull).
    init(messageBody: Any) throws {
        guard let dict = messageBody as? [String: Any] else { throw BridgeError.notAnObject }

        func string(_ source: [String: Any], _ key: String) -> String {
            (source[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func int64(_ source: [String: Any], _ key: String) -> Int64? {
            guard let number = source[key] as? NSNumber else { return nil }
            let value = number.doubleValue
            guard value.isFinite, abs(value) < 9.0e18 else { return nil }
            return Int64(value.rounded())
        }
        func int(_ source: [String: Any], _ key: String) -> Int? { int64(source, key).map { Int($0) } }

        let type = string(dict, "type")
        guard type == "play" else { throw BridgeError.wrongType(type) }
        let version = int(dict, "version") ?? 0
        guard version == 1 else { throw BridgeError.unsupportedVersion(version) }

        guard let server = URL(string: string(dict, "serverUrl")), server.isWebURL else {
            throw BridgeError.invalidURL("serverUrl")
        }
        serverUrl = server
        serverId = string(dict, "serverId")
        userId = string(dict, "userId")
        if userId.isEmpty { throw BridgeError.missing("userId") }
        accessToken = string(dict, "accessToken")
        if accessToken.isEmpty { throw BridgeError.missing("accessToken") }

        let raw = dict["items"] as? [[String: Any]] ?? []
        // Kennungen landen in Adressen: nur das Alphabet von Jellyfin-IDs zulassen.
        let idCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        var parsed: [StreamItem] = []
        for entry in raw.prefix(500) {
            let id = string(entry, "itemId")
            guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(idCharacters.contains) else { continue }
            parsed.append(StreamItem(
                itemId: id,
                title: string(entry, "title").isEmpty ? "Ohne Titel" : string(entry, "title"),
                itemType: string(entry, "itemType"),
                seriesName: string(entry, "seriesName"),
                seasonNumber: int(entry, "seasonNumber"),
                episodeNumber: int(entry, "episodeNumber"),
                year: int(entry, "year"),
                runTimeTicks: max(0, int64(entry, "runTimeTicks") ?? 0),
                isIntro: (entry["isIntro"] as? NSNumber)?.boolValue ?? false))
        }
        guard !parsed.isEmpty else { throw BridgeError.noItems }
        items = parsed
        startIndex = min(max(0, int(dict, "startIndex") ?? 0), parsed.count - 1)
        startPositionTicks = max(0, int64(dict, "startPositionTicks") ?? 0)
        let source = string(dict, "mediaSourceId")
        mediaSourceId = !source.isEmpty && source.count <= 64 && source.unicodeScalars.allSatisfy(idCharacters.contains) ? source : nil
        audioStreamIndex = int(dict, "audioStreamIndex")
        subtitleStreamIndex = int(dict, "subtitleStreamIndex")
    }
}

/// Hält angenommene Wiedergabe-Aufträge, bis ihr Player-Fenster sie abholt. Das Fenster wird
/// über eine Kennung geöffnet; die Zugangsdaten reisen so nicht durch die Fensterverwaltung.
@MainActor
final class StreamSessions {
    static let prefix = "stream:"
    private var pending: [String: StreamRequest] = [:]

    func register(_ request: StreamRequest) -> String {
        let key = Self.prefix + UUID().uuidString
        pending[key] = request
        return key
    }

    func request(for key: String) -> StreamRequest? {
        pending[key]
    }

    func discard(_ key: String) {
        pending[key] = nil
    }

    // MARK: Meldungen an den Server

    private var reports: [UUID: Task<Void, Never>] = [:]

    /// Merkt sich eine laufende Wiedergabe-Meldung, damit die App beim Beenden auf sie warten kann:
    /// sonst ginge der letzte Stand verloren, wenn man die App mit offenem Player schließt.
    func track(_ report: @escaping @Sendable () async -> Void) {
        let id = UUID()
        reports[id] = Task { [weak self] in
            await report()
            await MainActor.run { self?.reports[id] = nil }
        }
    }

    /// Wartet, bis alle angestoßenen Meldungen beim Server sind.
    func settle() async {
        for task in Array(reports.values) { await task.value }
    }
}
