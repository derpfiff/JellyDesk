import Foundation
import Network

/// Meldet offline entstandene Wiedergabestände an den Server, sobald er erreichbar ist,
/// und übernimmt neuere Stände vom Server.
@MainActor
final class ProgressSyncService: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "Noch kein Abgleich."
    /// Befund der Pfadprüfung je Server-Adresse.
    @Published private(set) var endpointReports: [String: String] = [:]

    private let store: OfflineStore
    private let credentials: CredentialStore
    private let api: JellyfinAPIService
    private let downloads: DownloadManager
    /// Wird bei jedem Abgleich mit aufgefrischt, damit geänderte Plugin-Einstellungen ankommen.
    var introLibrary: IntroLibrary?

    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var soonTask: Task<Void, Never>?
    private var rerunRequested = false
    private var wasSatisfied = false

    init(store: OfflineStore, credentials: CredentialStore, api: JellyfinAPIService, downloads: DownloadManager) {
        self.store = store
        self.credentials = credentials
        self.api = api
        self.downloads = downloads
    }

    /// Beim App-Start: sofort abgleichen, danach bei jedem Netzwechsel und alle fünf Minuten.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(satisfied: satisfied) }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store.items.contains(where: { $0.needsSync }) else { return }
                self.syncSoon()
            }
        }
        syncSoon()
    }

    private func pathChanged(satisfied: Bool) {
        defer { wasSatisfied = satisfied }
        guard satisfied else { return }
        if !wasSatisfied { downloads.networkBecameAvailable() }
        syncSoon()
    }

    /// Kurz gebündelt, damit mehrere Auslöser nur einen Abgleich ergeben.
    func syncSoon() {
        soonTask?.cancel()
        soonTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        if isSyncing {
            rerunRequested = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if rerunRequested {
                rerunRequested = false
                syncSoon()
            }
        }

        introLibrary?.refreshAll()
        let candidates = store.items.filter { $0.state == .completed }
        guard !candidates.isEmpty else {
            status = "Nichts abzugleichen."
            return
        }

        var pushed = 0, pulled = 0, failed = 0, unreachable = 0
        var lastError: String?
        let byServer = Dictionary(grouping: candidates, by: { $0.serverUrl })

        for (server, items) in byServer {
            // Erreichbarkeitsprobe ohne Anmeldung.
            guard (try? await api.publicInfo(server: server)) != nil else {
                unreachable += items.count
                continue
            }
            let endpoints = await api.endpoints(for: server)
            endpointReports[server.absoluteString] = endpoints.report

            for snapshot in items {
                guard let credential = credentials.credential(ref: snapshot.credentialRef) else { continue }
                do {
                    let remote = try await api.userData(server: server, endpoints: endpoints, itemId: snapshot.itemId,
                                                        userId: credential.userId, token: credential.accessToken)
                    // Während des Wartens kann sich lokal etwas getan haben.
                    guard let current = store.item(snapshot.id), !store.nowPlaying.contains(snapshot.id) else { continue }

                    if current.needsSync {
                        let localDate = current.positionUpdatedAt ?? .distantPast
                        if let remoteDate = remote.lastPlayedDate, remoteDate > localDate {
                            // Der Stand auf dem Server ist neuer: der Server gewinnt.
                            adopt(remote, for: current.id)
                            pulled += 1
                            continue
                        }
                        let stamp = current.positionUpdatedAt ?? Date()
                        if current.pendingMarkPlayed {
                            try await api.markPlayed(server: server, endpoints: endpoints, itemId: current.itemId,
                                                     userId: credential.userId, token: credential.accessToken, date: stamp)
                        } else {
                            try await api.updatePosition(server: server, endpoints: endpoints, itemId: current.itemId,
                                                         userId: credential.userId, token: credential.accessToken,
                                                         positionTicks: current.positionTicks, date: stamp)
                        }
                        // Erst nach erfolgreicher Antwort als synchronisiert markieren – und nur,
                        // wenn inzwischen kein neuerer lokaler Stand entstanden ist.
                        store.update(current.id) {
                            if $0.positionUpdatedAt == current.positionUpdatedAt {
                                $0.needsSync = false
                                $0.pendingMarkPlayed = false
                            }
                            $0.lastSyncedAt = Date()
                        }
                        pushed += 1
                    } else if remote.positionTicks != current.positionTicks || remote.played != current.played {
                        // Lokal nichts offen: der Server ist maßgeblich.
                        adopt(remote, for: current.id)
                        pulled += 1
                    }
                } catch {
                    failed += 1
                    lastError = error.localizedDescription
                }
            }
        }

        var parts: [String] = []
        if pushed > 0 { parts.append("\(pushed) gemeldet") }
        if pulled > 0 { parts.append("\(pulled) vom Server übernommen") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen" + (lastError.map { " (\($0))" } ?? "")) }
        if unreachable > 0 { parts.append("Server nicht erreichbar (\(unreachable) Titel)") }
        if parts.isEmpty { parts.append("alles auf dem Stand des Servers") }
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        status = "\(time): " + parts.joined(separator: ", ") + "."
    }

    private func adopt(_ remote: JellyfinAPIService.UserData, for id: String) {
        store.update(id) {
            $0.positionTicks = remote.positionTicks
            $0.played = remote.played
            $0.positionUpdatedAt = remote.lastPlayedDate ?? $0.positionUpdatedAt
            $0.needsSync = false
            $0.pendingMarkPlayed = false
            $0.lastSyncedAt = Date()
        }
    }
}
