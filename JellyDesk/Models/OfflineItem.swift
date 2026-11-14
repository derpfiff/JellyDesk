import Foundation

/// Gemerkte Spurwahl eines Titels.
struct TrackPreference: Codable, Equatable {
    /// Nur für Untertitel: ausdrücklich abgeschaltet.
    var off: Bool = false
    var trackID: Int?
    var language: String?
    var title: String?
}

/// Ein heruntergeladener (oder noch ladender) Titel. Wird als JSON gespeichert.
/// Enthält absichtlich weder Token noch Nutzerkennung: die liegen im Schlüsselbund,
/// `credentialRef` verweist darauf, und in den Adressen steht statt des Tokens ein Platzhalter.
struct OfflineItem: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case queued, downloading, paused, completed, failed
    }

    var id: String
    var itemId: String
    var itemType: String
    var serverId: String
    var serverUrl: URL
    var credentialRef: String

    var title: String
    var filename: String
    /// Pfad relativ zu OfflineMedia.
    var relativePath: String
    var seriesName: String
    var seasonNumber: Int?
    var episodeNumber: Int?
    var year: Int?
    var runTimeTicks: Int64
    var quality: String
    var estimatedBytes: Int64
    var container: String

    var urlTemplate: String
    var imageUrlTemplate: String?
    var backdropUrlTemplate: String?
    var posterFile: String?
    var backdropFile: String?

    var state: State
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    var fileSize: Int64 = 0
    var errorMessage: String?
    var addedAt: Date
    var completedAt: Date?

    // Wiedergabe und Abgleich
    var positionTicks: Int64
    var positionUpdatedAt: Date?
    var played: Bool = false
    /// Lokaler Stand ist dem Server noch nicht gemeldet.
    var needsSync: Bool = false
    /// Beim nächsten Abgleich als gesehen melden statt als Position.
    var pendingMarkPlayed: Bool = false
    var lastSyncedAt: Date?
    var audioPreference: TrackPreference?
    var subtitlePreference: TrackPreference?
    /// Nur als Ersatz, wenn die Plugin-Konfiguration nicht lesbar ist: Vorspann-Dateien, die der
    /// Server für diesen Titel genannt hat. nil: nicht abgefragt.
    var introCandidates: [String]?
    /// Tags, Genres und Studios des Titels für die Sonderregeln von „Local Intros“.
    var introCriteria: IntroCriteria?

    /// Vorschaubilder für die Zeitleiste; die Bögen liegen unter `AppPaths.trickplay(for:)`.
    var trickplay: TrickplayInfo?
    /// Der Server wurde nach Vorschaubildern gefragt (auch wenn er keine hat).
    var trickplayChecked: Bool?

    var isOriginal: Bool { quality == "orig" }
    var isEpisode: Bool { itemType == "Episode" }
    var isActive: Bool { state == .queued || state == .downloading }

    var fileURL: URL { AppPaths.offlineMedia.appendingPathComponent(relativePath) }
    var posterURL: URL? { posterFile.map { AppPaths.artwork.appendingPathComponent($0) } }
    var backdropURL: URL? { backdropFile.map { AppPaths.artwork.appendingPathComponent($0) } }

    var introURLs: [URL] { (introCandidates ?? []).map { AppPaths.intros.appendingPathComponent($0) } }

    var duration: TimeInterval { Ticks.seconds(runTimeTicks) }

    /// Anteil der gesehenen Laufzeit, 0…1.
    var watchedFraction: Double {
        guard runTimeTicks > 0 else { return 0 }
        return min(1, max(0, Double(positionTicks) / Double(runTimeTicks)))
    }

    var displayTitle: String {
        guard isEpisode else { return title }
        var parts: [String] = []
        if !seriesName.isEmpty { parts.append(seriesName) }
        if let s = seasonNumber, let e = episodeNumber { parts.append(String(format: "S%02dE%02d", s, e)) }
        parts.append(title)
        return parts.joined(separator: " · ")
    }
}

/// Ersetzt das Token in Adressen durch einen Platzhalter und setzt es beim Laden wieder ein.
/// Die geladene Adresse ist danach zeichengleich mit der vom Theme übergebenen.
enum TokenTemplate {
    static let marker = "{{ATV_TOKEN}}"

    static func redact(_ urlString: String, token: String) -> String {
        guard !token.isEmpty else { return urlString }
        var result = urlString.replacingOccurrences(of: token, with: marker)
        if let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != token {
            result = result.replacingOccurrences(of: encoded, with: marker)
        }
        return result
    }

    static func fill(_ template: String, token: String) -> URL? {
        URL(string: template.replacingOccurrences(of: marker, with: token))
    }
}
