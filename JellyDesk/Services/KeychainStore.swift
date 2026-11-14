import Foundation
import Security

/// Dünne Hülle um generische Passwort-Einträge im Schlüsselbund.
struct KeychainStore {
    let service: String

    init(service: String = AppPaths.bundleID) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    func set(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "JellyDesk"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func data(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Zugangsdaten eines Jellyfin-Nutzers auf einem Server.
struct JellyfinCredential: Codable, Equatable {
    var serverId: String
    var serverUrl: String
    var userId: String
    var accessToken: String
}

/// Hält userId und accessToken im Schlüsselbund. Die JSON-Metadaten kennen nur
/// eine zufällige Referenz darauf.
@MainActor
final class CredentialStore {
    private let keychain: KeychainStore
    private let account = "credentials"
    private var cache: [String: JellyfinCredential]?

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    private static func decode(_ data: Data?) -> [String: JellyfinCredential] {
        guard let data, let decoded = try? JSONDecoder().decode([String: JellyfinCredential].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Liest den Schlüsselbund beim Start abseits des Hauptthreads. Fragt macOS dabei nach
    /// einer Freigabe, bleibt die Oberfläche bedienbar, statt hinter dem Dialog einzufrieren.
    func preload() async {
        guard cache == nil else { return }
        let keychain = self.keychain, account = self.account
        let data = await Task.detached(priority: .userInitiated) { keychain.data(account: account) }.value
        if cache == nil { cache = Self.decode(data) }
    }

    private func load() -> [String: JellyfinCredential] {
        if let cache { return cache }
        let loaded = Self.decode(keychain.data(account: account))
        cache = loaded
        return loaded
    }

    private func persist(_ all: [String: JellyfinCredential]) {
        cache = all
        if let data = try? JSONEncoder().encode(all) {
            keychain.set(data, account: account)
        }
    }

    func credential(ref: String) -> JellyfinCredential? {
        load()[ref]
    }

    /// Legt die Zugangsdaten ab oder frischt das Token eines bekannten Nutzers auf.
    /// Liefert die Referenz für die Metadaten.
    func upsert(serverId: String, serverUrl: URL, userId: String, accessToken: String) -> String {
        var all = load()
        let serverKey = serverId.isEmpty ? serverUrl.absoluteString : serverId
        if let existing = all.first(where: {
            ($0.value.serverId.isEmpty ? $0.value.serverUrl : $0.value.serverId) == serverKey && $0.value.userId == userId
        }) {
            if existing.value.accessToken != accessToken || existing.value.serverUrl != serverUrl.absoluteString {
                all[existing.key]?.accessToken = accessToken
                all[existing.key]?.serverUrl = serverUrl.absoluteString
                persist(all)
            }
            return existing.key
        }
        let ref = UUID().uuidString
        all[ref] = JellyfinCredential(serverId: serverId, serverUrl: serverUrl.absoluteString,
                                      userId: userId, accessToken: accessToken)
        persist(all)
        return ref
    }

    /// Entfernt Einträge, auf die kein Download mehr verweist.
    func prune(keeping refs: Set<String>) {
        let all = load()
        let kept = all.filter { refs.contains($0.key) }
        if kept.count != all.count { persist(kept) }
    }
}
