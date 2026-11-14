import Foundation

/// Baut die Dienste der App einmal zusammen.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let notices: Notices
    let store: OfflineStore
    let credentials: CredentialStore
    let downloads: DownloadManager
    let api: JellyfinAPIService
    let sync: ProgressSyncService
    let intros: IntroLibrary
    let web: WebViewModel
    let streams = StreamSessions()

    private var started = false

    private init() {
        SettingsKeys.registerDefaults()
        AppPaths.ensureDirectories()

        let keychain = KeychainStore()
        notices = Notices()
        store = OfflineStore()
        credentials = CredentialStore(keychain: keychain)
        api = JellyfinAPIService()
        downloads = DownloadManager(store: store, credentials: credentials, keychain: keychain, notices: notices)
        downloads.api = api
        intros = IntroLibrary(store: store, credentials: credentials, api: api)
        downloads.introLibrary = intros
        sync = ProgressSyncService(store: store, credentials: credentials, api: api, downloads: downloads)
        sync.introLibrary = intros
        web = WebViewModel(downloads: downloads, notices: notices, store: store, streams: streams)
    }

    /// Nach dem Start: unterbrochene Downloads wieder aufnehmen, offene Positionen melden.
    func start() {
        guard !started else { return }
        started = true
        Task {
            // Erst die Zugangsdaten aus dem Schlüsselbund holen (im Hintergrund), dann loslegen.
            await credentials.preload()
            downloads.restoreAfterLaunch()
            sync.start()
        }
    }
}

/// Server-Adresse aus der Eingabe des Nutzers.
enum ServerAddress {
    /// Mögliche Adressen für eine Eingabe. Ohne Schema wird erst https, dann http versucht.
    static func candidates(for input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        let lower = text.lowercased()
        let strings = lower.hasPrefix("http://") || lower.hasPrefix("https://")
            ? [text]
            : ["https://" + text, "http://" + text]
        return strings.compactMap { URL(string: $0) }.filter(\.isWebURL)
    }

    /// Sucht unter den Kandidaten einen Server, der auf /System/Info/Public antwortet.
    static func resolve(_ input: String, api: JellyfinAPIService) async -> (url: URL, name: String?)? {
        for candidate in candidates(for: input) {
            if let info = try? await api.publicInfo(server: candidate) {
                return (candidate, info.ServerName)
            }
        }
        return nil
    }
}
