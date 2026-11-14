import Foundation

/// Speicherorte der App. In der Sandbox liegt alles im Container:
/// ~/Library/Containers/<Bundle-ID>/Data/Library/Application Support/<Bundle-ID>/OfflineMedia
enum AppPaths {
    static let bundleID = Bundle.main.bundleIdentifier ?? "JellyDesk"

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    static var offlineMedia: URL {
        appSupport.appendingPathComponent("OfflineMedia", isDirectory: true)
    }

    /// Poster und Hintergründe, nach Download-ID benannt.
    static var artwork: URL {
        offlineMedia.appendingPathComponent(".artwork", isDirectory: true)
    }

    /// Vorspann-Videos des Servers (Plugin „Local Intros“), nach Titel-ID benannt.
    static var intros: URL {
        offlineMedia.appendingPathComponent(".intros", isDirectory: true)
    }

    /// Vorschaubilder für die Zeitleiste, je Download ein Ordner mit den Bögen des Servers.
    static var trickplay: URL {
        offlineMedia.appendingPathComponent(".trickplay", isDirectory: true)
    }

    static func trickplay(for downloadID: String) -> URL {
        trickplay.appendingPathComponent(downloadID, isDirectory: true)
    }

    static var libraryFile: URL {
        offlineMedia.appendingPathComponent("library.json")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [offlineMedia, artwork, intros, trickplay] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Schlüssel für @AppStorage / UserDefaults.
enum SettingsKeys {
    static let serverURL = "serverURL"
    static let defaultQuality = "defaultQuality"
    static let alwaysAsk = "alwaysAskBeforeDownload"
    static let useAVKitForMP4 = "useAVKitForMP4"
    static let playIntros = "playIntros"
    static let deviceID = "deviceID"
    static let playerVolume = "playerVolume"
    static let nativeStreaming = "nativeStreaming"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            defaultQuality: "orig",
            alwaysAsk: false,
            useAVKitForMP4: true,
            playIntros: true,
            playerVolume: 1.0,
            nativeStreaming: true,
        ])
    }

    /// Feste Gerätekennung dieser Installation für die Authorization-Kopfzeile.
    static var deviceIdentifier: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceID), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceID)
        return fresh
    }
}
