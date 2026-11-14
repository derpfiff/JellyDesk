import AppKit

/// Beschreibung der Vorschaubilder eines Titels, wie Jellyfin sie erzeugt („Trickplay“): viele
/// kleine Standbilder in gleichem Zeitabstand, zu Bögen von `tileWidth` × `tileHeight` gekachelt.
struct TrickplayInfo: Codable, Equatable {
    /// Breite und Höhe eines einzelnen Vorschaubilds in Pixeln.
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    /// Zeitabstand der Bilder in Millisekunden.
    var interval: Int
    var mediaSourceId: String

    var isUsable: Bool {
        width > 0 && height > 0 && tileWidth > 0 && tileHeight > 0 && thumbnailCount > 0 && interval > 0
    }

    var tilesPerSheet: Int { tileWidth * tileHeight }
    var sheetCount: Int { Int((Double(thumbnailCount) / Double(max(1, tilesPerSheet))).rounded(.up)) }

    /// Bogen und Ausschnitt (Pixel, Ursprung oben links) für eine Stelle im Film.
    func location(at seconds: TimeInterval) -> (sheet: Int, rect: CGRect)? {
        guard isUsable, seconds.isFinite else { return nil }
        let index = min(thumbnailCount - 1, max(0, Int(seconds * 1000 / Double(interval))))
        let onSheet = index % tilesPerSheet
        let rect = CGRect(x: (onSheet % tileWidth) * width, y: (onSheet / tileWidth) * height, width: width, height: height)
        return (index / tilesPerSheet, rect)
    }

    /// Wählt aus dem Angebot des Servers (`Trickplay` eines Titels: Quelle → Breite → Angaben) die
    /// Auflösung, die der Vorschau im Player am nächsten kommt.
    static func pick(from manifest: [String: Any], preferredSource: String?, preferredWidth: Int = 320) -> TrickplayInfo? {
        let sources = manifest.compactMapValues { $0 as? [String: Any] }
        guard let sourceID = (preferredSource.flatMap { sources[$0] != nil ? $0 : nil }) ?? sources.keys.sorted().first,
              let widths = sources[sourceID] else { return nil }
        var best: TrickplayInfo?
        for (_, value) in widths {
            guard let entry = value as? [String: Any] else { continue }
            func number(_ key: String) -> Int { (entry[key] as? NSNumber)?.intValue ?? 0 }
            let info = TrickplayInfo(width: number("Width"), height: number("Height"), tileWidth: number("TileWidth"),
                                     tileHeight: number("TileHeight"), thumbnailCount: number("ThumbnailCount"),
                                     interval: number("Interval"), mediaSourceId: sourceID)
            guard info.isUsable, info.width <= 1024, info.tilesPerSheet <= 400, info.sheetCount <= 2000 else { continue }
            if best == nil || abs(info.width - preferredWidth) < abs(best!.width - preferredWidth) { best = info }
        }
        return best
    }
}

/// Liefert das Vorschaubild zu einer Stelle. Die Bögen kommen von der Platte (Downloads) oder
/// vom Server (Streams) und bleiben für die Dauer der Wiedergabe im Speicher.
@MainActor
final class TrickplayProvider {
    let info: TrickplayInfo
    private let loadSheet: (Int) async -> Data?
    private var sheets: [Int: CGImage] = [:]
    private var loading: [Int: Task<CGImage?, Never>] = [:]
    private var order: [Int] = []
    /// Ein Bogen mit 10 × 10 Bildern von 320 px belegt entpackt rund 23 MB.
    private let limit = 6

    init(info: TrickplayInfo, loadSheet: @escaping (Int) async -> Data?) {
        self.info = info
        self.loadSheet = loadSheet
    }

    /// Seitenverhältnis der Vorschaubilder.
    var aspect: CGFloat { CGFloat(info.width) / CGFloat(max(1, info.height)) }

    func thumbnail(at seconds: TimeInterval) async -> CGImage? {
        guard let place = info.location(at: seconds), let sheet = await sheet(place.sheet) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        let rect = place.rect.intersection(bounds)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return sheet.cropping(to: rect)
    }

    private func sheet(_ index: Int) async -> CGImage? {
        if let cached = sheets[index] { return cached }
        if let running = loading[index] { return await running.value }
        let load = loadSheet
        let task = Task<CGImage?, Never> {
            guard let data = await load(index), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        loading[index] = task
        let image = await task.value
        loading[index] = nil
        if let image {
            sheets[index] = image
            order.append(index)
            while order.count > limit { sheets[order.removeFirst()] = nil }
        }
        return image
    }
}
