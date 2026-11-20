import Foundation

/// Stand des Bewertungs-Sheets: die Wahl des Nutzers.
struct RatingDraft: Equatable {
    /// Halbe Sterne, 0.5 … 5.0; nil = keine Bewertung.
    var stars: Double?
    var liked: Bool = false
    /// Datum des Schauens; nil = „noch nicht gewählt“ bzw. Haken abgewählt.
    var watchedDate: Date? = Date()
    var rewatch: Bool = false
    var comment: String = ""
    var containsSpoilers: Bool = false

    /// Jellyfin-Bewertung 1–10; halbe Sterne sind ungerade Werte. nil, wenn keine Sterne vergeben.
    var jellyfinRating: Int? {
        guard let stars else { return nil }
        let value = Int((stars * 2).rounded())
        return max(1, min(10, value))
    }
}

/// Zu welchem Film gehört das Sheet. Enthält genug, um die Antwort offline zu speichern.
struct RatingContext: Equatable, Identifiable {
    var itemId: String
    var tmdbId: Int?
    var serverId: String
    var serverUrl: URL
    var credentialRef: String
    var userId: String
    var title: String
    var year: Int?

    /// Für SwiftUIs `.sheet(item:)`.
    var id: String { "\(serverUrl.absoluteString)|\(userId)|\(itemId)" }
}

/// Eine gespeicherte, aber noch nicht gesendete Antwort auf die Bewertungs-Frage.
/// Wird beim Sync in dieser Reihenfolge abgearbeitet:
/// 1. Eintrag in `CustomPrefs.asked` (bei allen drei Antworten), ggf. `off=1`.
/// 2. Nur bei `.save`: Bewertung an Jellyfin, Entdecken-Rückmeldung, Letterboxd.
struct PendingRating: Codable, Identifiable, Equatable {
    enum Action: String, Codable { case save, later, off }

    var id: String
    var itemId: String
    var tmdbId: Int?
    var serverId: String
    var serverUrlString: String
    var credentialRef: String
    var userId: String

    var action: Action
    var stars: Double?
    var liked: Bool
    /// „YYYY-MM-DD“; nil, wenn der Nutzer kein Datum gesetzt hat.
    var watchedDate: String?
    var comment: String
    var containsSpoilers: Bool
    var rewatch: Bool

    var createdAt: Date
    var askedPushed: Bool = false
    var ratingPushed: Bool = false
    var discoverAttempted: Bool = false
    var letterboxdPushed: Bool = false
    /// Letzte vom Server gemeldete Antwort an Letterboxd (posted|queued|error).
    var letterboxdStatus: String?
    var letterboxdError: String?

    var serverUrl: URL? { URL(string: serverUrlString) }

    /// 1–10 für Jellyfin; nil, wenn keine Sterne.
    var jellyfinRating: Int? {
        guard let stars else { return nil }
        let value = Int((stars * 2).rounded())
        return max(1, min(10, value))
    }

    /// Alle Server-Aufrufe erledigt: Eintrag kann entfernt werden.
    func isFullyPushed(letterboxdAvailable: Bool, hasTmdb: Bool) -> Bool {
        guard askedPushed else { return false }
        guard action == .save else { return true }
        guard ratingPushed else { return false }
        guard !letterboxdAvailable || !hasTmdb || letterboxdPushed else { return false }
        return true
    }
}

/// Zwischengespeicherte Antwort des Servers auf
/// `GET /DisplayPreferences/cinemaglass-rate?userId=…&client=cinemaglass`.
struct AskedCache: Codable, Equatable {
    var ids: [String] = []
    var off: Bool = false
    var fetchedAt: Date?

    /// Jellyfin-IDs in `CustomPrefs.asked` sind 32-stelliges Hex ohne Bindestriche.
    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "").lowercased()
    }

    mutating func markAsked(_ rawId: String) {
        let id = AskedCache.normalize(rawId)
        guard !id.isEmpty else { return }
        ids.removeAll { $0 == id }
        ids.append(id)
        if ids.count > 300 { ids.removeFirst(ids.count - 300) }
    }

    func isAsked(_ rawId: String) -> Bool {
        let id = AskedCache.normalize(rawId)
        return ids.contains(id)
    }
}

/// Zwischengespeicherter Stand von `GET /CinemaGlass/config`.
struct CinemaGlassConfigCache: Codable, Equatable {
    var ratePrompt: Bool
    var fetchedAt: Date
}
