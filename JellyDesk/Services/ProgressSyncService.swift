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
    private let ratings: RatingStore
    private let notices: Notices
    /// Wird bei jedem Abgleich mit aufgefrischt, damit geänderte Plugin-Einstellungen ankommen.
    var introLibrary: IntroLibrary?

    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var soonTask: Task<Void, Never>?
    private var rerunRequested = false
    private var wasSatisfied = false

    init(store: OfflineStore, credentials: CredentialStore, api: JellyfinAPIService,
         downloads: DownloadManager, ratings: RatingStore, notices: Notices) {
        self.store = store
        self.credentials = credentials
        self.api = api
        self.downloads = downloads
        self.ratings = ratings
        self.notices = notices
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
        // Server, die nur offene Bewertungen haben (aber keine Mediathek): hier mit hineinnehmen,
        // damit auch sie abgeglichen werden.
        let ratingServers: Set<URL> = Set(ratings.pending.compactMap { $0.serverUrl })
        let allServers: Set<URL> = Set(candidates.map(\.serverUrl)).union(ratingServers)
        guard !allServers.isEmpty else {
            status = "Nichts abzugleichen."
            return
        }

        var pushed = 0, pulled = 0, failed = 0, unreachable = 0
        var lastError: String?
        let byServer = Dictionary(grouping: candidates, by: { $0.serverUrl })

        for server in allServers {
            let items = byServer[server] ?? []
            // Erreichbarkeitsprobe ohne Anmeldung.
            guard (try? await api.publicInfo(server: server)) != nil else {
                unreachable += items.count
                continue
            }
            // Darf überhaupt gefragt werden? Antwort cachen, damit sie auch offline gilt.
            if let prompt = await api.cinemaGlassRatePrompt(server: server) {
                ratings.setRatePrompt(prompt, for: server)
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

        // Nach dem Gesehen-Status folgen in derselben Runde die Bewertungen und – falls dort
        // eingerichtet – Letterboxd. So gilt für jede Antwort die vom Server vorgesehene
        // Reihenfolge, auch wenn sie offline gegeben wurde.
        let ratingsResult = await syncRatings()

        var parts: [String] = []
        if pushed > 0 { parts.append("\(pushed) gemeldet") }
        if pulled > 0 { parts.append("\(pulled) vom Server übernommen") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen" + (lastError.map { " (\($0))" } ?? "")) }
        if unreachable > 0 { parts.append("Server nicht erreichbar (\(unreachable) Titel)") }
        if ratingsResult.pushed > 0 { parts.append("\(ratingsResult.pushed) Bewertung\(ratingsResult.pushed == 1 ? "" : "en") gesendet") }
        if parts.isEmpty { parts.append("alles auf dem Stand des Servers") }
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        status = "\(time): " + parts.joined(separator: ", ") + "."
    }

    // MARK: Bewertungen

    private struct RatingSyncResult {
        var pushed = 0
    }

    /// Schickt die offenen Antworten an Cinema Glass (schon gefragt), Jellyfin (Bewertung),
    /// Cinema Glass (Entdecken) und Letterboxd ab. Fehler bleiben still: der Eintrag versucht es
    /// beim nächsten Abgleich wieder. Eine `error`-Antwort von Letterboxd wird einmal angezeigt.
    /// Darüber hinaus wird die „Schon gefragt“-Liste jedes bekannten (Server, Nutzer)-Paars
    /// nachgezogen, damit offline-Entscheidungen auf einem frischen Stand aufsetzen.
    private func syncRatings() async -> RatingSyncResult {
        var result = RatingSyncResult()

        // Jedes bekannte (Server, Nutzer)-Paar: aus offenen Bewertungen und aus der Mediathek.
        struct Account: Hashable { let serverKey: String; let userId: String; let credentialRef: String }
        var accounts: Set<Account> = []
        for entry in ratings.pending {
            accounts.insert(Account(serverKey: entry.serverUrlString,
                                    userId: entry.userId, credentialRef: entry.credentialRef))
        }
        for item in store.items {
            guard let credential = credentials.credential(ref: item.credentialRef) else { continue }
            accounts.insert(Account(serverKey: item.serverUrl.absoluteString,
                                    userId: credential.userId, credentialRef: item.credentialRef))
        }
        guard !accounts.isEmpty else { return result }

        let byAccount = Dictionary(grouping: ratings.pending) {
            Account(serverKey: $0.serverUrlString, userId: $0.userId, credentialRef: $0.credentialRef)
        }

        for account in accounts {
            guard let server = URL(string: account.serverKey),
                  let credential = credentials.credential(ref: account.credentialRef),
                  (try? await api.publicInfo(server: server)) != nil else { continue }

            let group = byAccount[account] ?? []
            let notPushedForAsked = group.filter { !$0.askedPushed }
            let needsOff = group.contains { $0.action == .off }

            if !notPushedForAsked.isEmpty {
                // Cinema Glass: „Schon gefragt“ anhängen (frisch lesen, deduplizieren, zurückschreiben).
                do {
                    let summary = try await api.appendCinemaGlassAsked(
                        server: server, userId: credential.userId, token: credential.accessToken,
                        itemIds: notPushedForAsked.map(\.itemId), disableForever: needsOff)
                    var cache = ratings.askedCache(server: server, userId: credential.userId)
                    cache.ids = summary.asked
                    cache.off = summary.off
                    cache.fetchedAt = Date()
                    ratings.replaceAskedCache(cache, server: server, userId: credential.userId)
                    for entry in notPushedForAsked {
                        ratings.update(entry.id) { $0.askedPushed = true }
                    }
                } catch {
                    continue
                }
            } else if let summary = try? await api.cinemaGlassAskedSummary(
                server: server, userId: credential.userId, token: credential.accessToken) {
                // Nichts zu senden – trotzdem den lokalen Stand auffrischen, damit ein
                // „Nicht mehr fragen“ eines anderen Geräts hier offline gilt.
                var cache = ratings.askedCache(server: server, userId: credential.userId)
                cache.ids = summary.asked
                cache.off = summary.off
                cache.fetchedAt = Date()
                ratings.replaceAskedCache(cache, server: server, userId: credential.userId)
            }

            guard !group.isEmpty else { continue }

            let endpoints = await api.endpoints(for: server)

            // Letterboxd-Status je Server einmal; nachher je Eintrag entscheiden, ob geschickt wird.
            let letterboxdStatus = try? await api.letterboxdStatus(server: server, token: credential.accessToken)
            let letterboxdAvailable = letterboxdStatus?.enabled == true && letterboxdStatus?.configured == true

            for entry in group where entry.action == .save {
                // Bewertung an Jellyfin.
                if !entry.ratingPushed {
                    do {
                        try await api.postUserRating(server: server, endpoints: endpoints,
                                                     itemId: entry.itemId, userId: credential.userId,
                                                     token: credential.accessToken,
                                                     rating: entry.jellyfinRating, liked: entry.liked)
                        ratings.update(entry.id) { $0.ratingPushed = true }
                    } catch {
                        continue
                    }
                }

                // Entdecken-Rückmeldung: Fehler absichtlich ignoriert.
                if !entry.discoverAttempted, let tmdb = entry.tmdbId {
                    let action: String?
                    if entry.liked || (entry.stars ?? 0) >= 4 { action = "like" }
                    else if let s = entry.stars, s <= 2 { action = "dislike" }
                    else { action = nil }
                    if let action {
                        await api.postDiscoverFeedback(server: server, token: credential.accessToken,
                                                      tmdbId: tmdb, action: action)
                    }
                    ratings.update(entry.id) { $0.discoverAttempted = true }
                }

                // Letterboxd – nur wenn Plugin bereit UND TMDb-Kennung vorhanden.
                if letterboxdAvailable, let tmdb = entry.tmdbId, !entry.letterboxdPushed {
                    do {
                        let outcome = try await api.postLetterboxdEntry(
                            server: server, token: credential.accessToken,
                            itemId: entry.itemId, tmdbId: tmdb,
                            watchedDate: entry.watchedDate, rating: entry.stars,
                            liked: entry.liked, review: entry.comment,
                            containsSpoilers: entry.containsSpoilers, rewatch: entry.rewatch)
                        switch outcome {
                        case .posted:
                            ratings.update(entry.id) {
                                $0.letterboxdPushed = true
                                $0.letterboxdStatus = "posted"
                                $0.letterboxdError = nil
                            }
                        case .queued:
                            ratings.update(entry.id) {
                                $0.letterboxdPushed = true
                                $0.letterboxdStatus = "queued"
                                $0.letterboxdError = nil
                            }
                        case .error(let message):
                            // Einmal als Hinweis zeigen, danach den Eintrag entfernen (ein Dauer-Fehler
                            // vom Server lohnt nicht, ihn jedes Mal erneut zu versuchen).
                            notices.post(RatingL10n.t(
                                "Letterboxd: \(message)",
                                "Letterboxd: \(message)"
                            ))
                            ratings.update(entry.id) {
                                $0.letterboxdPushed = true
                                $0.letterboxdStatus = "error"
                                $0.letterboxdError = message
                            }
                        }
                    } catch {
                        continue
                    }
                }
            }

            // Fertige Einträge entfernen.
            for entry in group {
                guard let current = ratings.pending.first(where: { $0.id == entry.id }) else { continue }
                let hasTmdb = entry.tmdbId != nil
                if current.isFullyPushed(letterboxdAvailable: letterboxdAvailable, hasTmdb: hasTmdb) {
                    if current.action == .save { result.pushed += 1 }
                    ratings.remove(entry.id)
                }
            }
        }
        return result
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
