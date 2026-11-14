import Foundation

/// Metadaten aller Downloads als JSON-Datei (OfflineMedia/library.json).
@MainActor
final class OfflineStore: ObservableObject {
    @Published private(set) var items: [OfflineItem] = []
    /// Titel, die gerade im Player offen sind; der Abgleich fasst sie nicht an.
    var nowPlaying: Set<String> = []

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private struct Library: Codable {
        var version: Int = 1
        var items: [OfflineItem]
    }

    init(fileURL: URL = AppPaths.libraryFile) {
        self.fileURL = fileURL
        AppPaths.ensureDirectories()
        load()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try Self.makeDecoder().decode(Library.self, from: data).items
        } catch {
            // Unlesbare Datei nicht überschreiben, sondern beiseitelegen.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("library-defekt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    func item(_ id: String) -> OfflineItem? {
        items.first { $0.id == id }
    }

    func add(_ item: OfflineItem) {
        items.append(item)
        scheduleSave()
    }

    func update(_ id: String, _ change: (inout OfflineItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var copy = items[index]
        change(&copy)
        guard copy != items[index] else { return }
        items[index] = copy
        scheduleSave()
    }

    /// Setzt den Wiedergabestand zurück, damit der Titel wieder von vorn beginnt. Der Server
    /// erfährt es beim nächsten Abgleich.
    func resetPlayback(_ id: String) {
        update(id) {
            $0.positionTicks = 0
            $0.played = false
            $0.pendingMarkPlayed = false
            $0.positionUpdatedAt = Date()
            $0.needsSync = true
        }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Schreibt sofort und atomar, z. B. vor dem Beenden.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let data = try Self.makeEncoder().encode(Library(items: items))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("JellyDesk: Metadaten konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }
}
