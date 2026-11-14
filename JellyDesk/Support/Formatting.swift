import Foundation

/// Jellyfin rechnet in Ticks: 10 000 000 pro Sekunde.
enum Ticks {
    static let perSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64) -> TimeInterval {
        Double(ticks) / perSecond
    }

    static func from(seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * perSecond).rounded())
    }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    /// 1:23:45 bzw. 23:45
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum Quality {
    static let all = ["orig", "1080", "720", "480"]

    static func label(_ key: String) -> String {
        switch key {
        case "orig": return "Original"
        case "1080", "720", "480": return key + "p"
        default: return key
        }
    }
}

enum FileNameSanitizer {
    /// Macht aus einer vom Server gelieferten Zeichenkette einen einzelnen, harmlosen Pfadbestandteil.
    /// `isFileName`: von einem gelieferten Pfad zählt nur der letzte Bestandteil. Bei Titeln und
    /// Seriennamen werden Schrägstriche dagegen wie andere unzulässige Zeichen ersetzt.
    static func component(_ raw: String, fallback: String = "Unbenannt", isFileName: Bool = false) -> String {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        if isFileName {
            if let last = name.split(separator: "/").last { name = String(last) } else { name = "" }
        }

        let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters).union(.newlines)
        name = String(name.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) })
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return fallback }

        // Dateisystemgrenze: 255 Byte je Bestandteil. Die Endung bleibt erhalten.
        let limit = 200
        if name.utf8.count > limit {
            let ext = (name as NSString).pathExtension
            var stem = (name as NSString).deletingPathExtension
            while stem.utf8.count > limit - ext.utf8.count - 1, !stem.isEmpty { stem.removeLast() }
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name
    }
}

extension URL {
    /// Schema, Host und Port stimmen überein.
    func hasSameOrigin(as other: URL) -> Bool {
        guard let a = scheme?.lowercased(), let b = other.scheme?.lowercased(), a == b,
              let ha = host?.lowercased(), let hb = other.host?.lowercased(), ha == hb else { return false }
        return effectivePort == other.effectivePort
    }

    var effectivePort: Int {
        if let port { return port }
        return scheme?.lowercased() == "https" ? 443 : 80
    }

    var isWebURL: Bool {
        guard let s = scheme?.lowercased() else { return false }
        return (s == "http" || s == "https") && !(host ?? "").isEmpty
    }
}
