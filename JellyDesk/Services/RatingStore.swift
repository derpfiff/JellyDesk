import Foundation

/// Speichert alles, was zur Bewertungs-Frage lokal bleibt:
/// - den Stand von `GET /CinemaGlass/config` je Server (damit offline entschieden werden kann,
///   ob überhaupt gefragt wird),
/// - den Zwischenstand der gemeinsamen „Schon gefragt“-Liste je (Server, Nutzer),
/// - die Antworten, die noch nicht am Server sind.
///
/// Die Daten liegen neben der Mediathek (`OfflineMedia/ratings.json`) und überleben einen Neustart.
@MainActor
final class RatingStore: ObservableObject {
    @Published private(set) var pending: [PendingRating] = []

    private var configs: [String: CinemaGlassConfigCache] = [:]
    private var askedCaches: [String: AskedCache] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private struct File: Codable {
        var version: Int = 1
        var configs: [String: CinemaGlassConfigCache] = [:]
        var askedCaches: [String: AskedCache] = [:]
        var pending: [PendingRating] = []
    }

    init(fileURL: URL = AppPaths.ratingsFile) {
        self.fileURL = fileURL
        load()
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? Self.decoder().decode(File.self, from: data) else { return }
        configs = file.configs
        askedCaches = file.askedCaches
        pending = file.pending
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let file = File(configs: configs, askedCaches: askedCaches, pending: pending)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.encoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("JellyDesk: Bewertungs-Daten konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    // MARK: Cinema-Glass-Einstellung

    private func key(_ server: URL) -> String { server.absoluteString }

    func ratePromptCache(for server: URL) -> CinemaGlassConfigCache? {
        configs[key(server)]
    }

    func setRatePrompt(_ value: Bool, for server: URL) {
        configs[key(server)] = CinemaGlassConfigCache(ratePrompt: value, fetchedAt: Date())
        scheduleSave()
    }

    // MARK: Gemeinsame „Schon gefragt“-Liste

    private func askedKey(server: URL, userId: String) -> String { "\(server.absoluteString)|\(userId)" }

    func askedCache(server: URL, userId: String) -> AskedCache {
        askedCaches[askedKey(server: server, userId: userId)] ?? AskedCache()
    }

    func replaceAskedCache(_ cache: AskedCache, server: URL, userId: String) {
        askedCaches[askedKey(server: server, userId: userId)] = cache
        scheduleSave()
    }

    /// Lokal vermerken, ohne auf den Server zu warten. Der Sync schreibt die Liste später zurück.
    func markAskedLocally(itemId: String, server: URL, userId: String, off: Bool) {
        var cache = askedCache(server: server, userId: userId)
        cache.markAsked(itemId)
        if off { cache.off = true }
        askedCaches[askedKey(server: server, userId: userId)] = cache
        scheduleSave()
    }

    // MARK: Offene Antworten

    func enqueue(_ entry: PendingRating) {
        // Pro Titel und Nutzer gibt es nur eine offene Antwort; eine neue überschreibt eine alte.
        pending.removeAll { $0.itemId == entry.itemId && $0.userId == entry.userId
                             && $0.serverUrlString == entry.serverUrlString }
        pending.append(entry)
        scheduleSave()
    }

    func update(_ id: String, _ change: (inout PendingRating) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        var copy = pending[index]
        change(&copy)
        guard copy != pending[index] else { return }
        pending[index] = copy
        scheduleSave()
    }

    func remove(_ id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Steht für diesen Titel schon eine Antwort an?
    func hasPending(itemId: String, userId: String, server: URL) -> Bool {
        pending.contains {
            $0.itemId == itemId && $0.userId == userId && $0.serverUrlString == server.absoluteString
        }
    }
}
