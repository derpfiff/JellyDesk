import Foundation

/// Baut die Kopfzeile, mit der sich die App bei Jellyfin ausweist:
/// Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"
enum JellyfinAuth {
    static func header(token: String?) -> String {
        func clean(_ value: String) -> String {
            // Anführungszeichen, Kommas und Nicht-ASCII würden die Kopfzeile zerlegen.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_.")
            let filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
            return filtered.isEmpty ? "Mac" : filtered
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let device = Host.current().localizedName ?? "Mac"
        var parts = [
            "Client=\"JellyDesk\"",
            "Device=\"\(clean(device))\"",
            "DeviceId=\"\(SettingsKeys.deviceIdentifier)\"",
            "Version=\"\(clean(version))\"",
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}

/// Die wenigen Jellyfin-Aufrufe, die die App selbst macht (Erreichbarkeit, Wiedergabestand).
actor JellyfinAPIService {
    struct PublicInfo: Decodable {
        let ServerName: String?
        let Version: String?
        let Id: String?
    }

    /// Wiedergabestand eines Titels laut Server.
    struct UserData {
        var positionTicks: Int64
        var played: Bool
        var lastPlayedDate: Date?
    }

    /// Ein Vorspann-Video, das der Server vor einem Titel abspielen würde.
    struct Intro {
        let id: String
        let name: String
        let fileExtension: String
    }

    /// Welche Pfade der Server laut seiner openapi.json anbietet.
    struct Endpoints {
        var modernUserData = true
        var modernPlayed = true
        /// Lesbarer Befund für die Einstellungen.
        var report = "Noch nicht geprüft."
    }

    enum APIError: LocalizedError {
        case http(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): return "Token abgelehnt (in der Weboberfläche neu anmelden)."
            case .http(let code): return "HTTP \(code)"
            case .invalidResponse: return "Unerwartete Antwort"
            }
        }
    }

    private let session: URLSession
    private var endpointCache: [String: Endpoints] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    private func request(server: URL, path: String, query: [URLQueryItem] = [], method: String = "GET",
                         token: String? = nil, json: [String: Any]? = nil) -> URLRequest? {
        // Der Server kann unter einem Unterpfad liegen (Base URL), deshalb anhängen statt ersetzen.
        var url = server
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let final = components.url else { return nil }

        var request = URLRequest(url: final)
        request.httpMethod = method
        request.setValue(JellyfinAuth.header(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest?) async throws -> Data {
        guard let request else { throw APIError.invalidResponse }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return data
    }

    // MARK: Erreichbarkeit

    /// GET /System/Info/Public – ohne Anmeldung, dient als Erreichbarkeitsprobe.
    func publicInfo(server: URL) async throws -> PublicInfo {
        let data = try await send(request(server: server, path: "System/Info/Public"))
        return try JSONDecoder().decode(PublicInfo.self, from: data)
    }

    // MARK: Pfadprüfung gegen /api-docs/openapi.json

    /// Prüft einmal je Server und Lauf, ob die Pfade aus NATIVE-BRIDGE.md existieren.
    /// Fehlen sie (Server vor 10.9), werden die früheren Pfade mit der Nutzerkennung im Pfad benutzt.
    func endpoints(for server: URL) async -> Endpoints {
        let key = server.absoluteString
        if let cached = endpointCache[key] { return cached }

        var result = Endpoints()
        do {
            let data = try await send(request(server: server, path: "api-docs/openapi.json"))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let paths = root["paths"] as? [String: Any] else { throw APIError.invalidResponse }
            let version = (root["info"] as? [String: Any])?["version"] as? String ?? "unbekannt"

            func has(_ path: String, _ method: String) -> Bool {
                (paths[path] as? [String: Any])?[method] != nil
            }
            let userData = has("/UserItems/{itemId}/UserData", "post")
            let played = has("/UserPlayedItems/{itemId}", "post")
            let legacyUserData = has("/Users/{userId}/Items/{itemId}/UserData", "post")
            let legacyPlayed = has("/Users/{userId}/PlayedItems/{itemId}", "post")

            result.modernUserData = userData || !legacyUserData
            result.modernPlayed = played || !legacyPlayed

            var notes: [String] = []
            if userData && played {
                notes.append("Beide Pfade sind laut openapi.json vorhanden (API \(version)).")
            }
            if !userData {
                notes.append(legacyUserData
                    ? "Abweichung: POST /UserItems/{itemId}/UserData fehlt, benutzt wird /Users/{userId}/Items/{itemId}/UserData."
                    : "Abweichung: POST /UserItems/{itemId}/UserData steht nicht in der openapi.json; es wird trotzdem versucht.")
            }
            if !played {
                notes.append(legacyPlayed
                    ? "Abweichung: POST /UserPlayedItems/{itemId} fehlt, benutzt wird /Users/{userId}/PlayedItems/{itemId}."
                    : "Abweichung: POST /UserPlayedItems/{itemId} steht nicht in der openapi.json; es wird trotzdem versucht.")
            }
            result.report = notes.joined(separator: " ")
            endpointCache[key] = result
        } catch {
            // Nicht zwischenspeichern: beim nächsten Abgleich erneut prüfen.
            result.report = "openapi.json nicht abrufbar (\(error.localizedDescription)); es gelten die Pfade aus NATIVE-BRIDGE.md."
        }
        return result
    }

    // MARK: Vorspann

    /// GET /Items/{itemId}/Intros?userId=… – was der Server (z. B. das Plugin „Local Intros“)
    /// vor diesem Titel abspielen würde.
    func intros(server: URL, itemId: String, userId: String, token: String) async throws -> [Intro] {
        let data = try await send(request(server: server, path: "Items/\(itemId)/Intros",
                                          query: [URLQueryItem(name: "userId", value: userId)], token: token))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let items = root["Items"] as? [[String: Any]] ?? []
        var result: [Intro] = []
        for item in items {
            guard let id = item["Id"] as? String, !id.isEmpty else { continue }
            var ext = ((item["Path"] as? String ?? "") as NSString).pathExtension.lowercased()
            if ext.isEmpty {
                ext = (item["Container"] as? String ?? "").split(separator: ",").first.map(String.init) ?? ""
            }
            if ext.isEmpty || ext.count > 5 { ext = "mkv" }
            result.append(Intro(id: id, name: item["Name"] as? String ?? "Vorspann", fileExtension: ext))
        }
        return result
    }

    /// Die Konfiguration des Plugins „Local Intros“ als JSON. Nur Administratoren dürfen sie
    /// lesen; sonst nil.
    func localIntrosConfigurationData(server: URL, token: String) async -> Data? {
        let pluginId = "07d8679501f24d22b174cdc6056c3e7c"
        return try? await send(request(server: server, path: "Plugins/\(pluginId)/Configuration", token: token))
    }

    /// Tags, Genres und Studios eines Titels; bei Folgen samt Staffel und Serie, wie das Plugin
    /// sie für seine Sonderregeln zusammenzieht.
    func introCriteria(server: URL, itemId: String, userId: String, token: String) async throws -> IntroCriteria {
        func load(_ id: String) async throws -> [String: Any] {
            let data = try await send(request(server: server, path: "Items/\(id)",
                                              query: [URLQueryItem(name: "userId", value: userId)], token: token))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.invalidResponse
            }
            return object
        }
        var criteria = IntroCriteria()
        func add(_ object: [String: Any]) {
            criteria.tags += object["Tags"] as? [String] ?? []
            criteria.genres += object["Genres"] as? [String] ?? []
            criteria.studios += (object["Studios"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }
        }
        let item = try await load(itemId)
        add(item)
        if (item["Type"] as? String) == "Episode" {
            for key in ["SeasonId", "SeriesId"] {
                if let parent = item[key] as? String, let object = try? await load(parent) { add(object) }
            }
        }
        return criteria
    }

    // MARK: Wiedergabestand

    private func userDataRoute(_ endpoints: Endpoints, itemId: String, userId: String) -> (String, [URLQueryItem]) {
        endpoints.modernUserData
            ? ("UserItems/\(itemId)/UserData", [URLQueryItem(name: "userId", value: userId)])
            : ("Users/\(userId)/Items/\(itemId)/UserData", [])
    }

    /// GET /UserItems/{itemId}/UserData?userId=…
    func userData(server: URL, endpoints: Endpoints, itemId: String, userId: String, token: String) async throws -> UserData {
        let (path, query) = userDataRoute(endpoints, itemId: itemId, userId: userId)
        let data = try await send(request(server: server, path: path, query: query, token: token))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return UserData(
            positionTicks: (object["PlaybackPositionTicks"] as? NSNumber)?.int64Value ?? 0,
            played: (object["Played"] as? Bool) ?? false,
            lastPlayedDate: (object["LastPlayedDate"] as? String).flatMap(Self.parseDate)
        )
    }

    /// POST /UserItems/{itemId}/UserData?userId=… mit {"PlaybackPositionTicks": …}
    func updatePosition(server: URL, endpoints: Endpoints, itemId: String, userId: String, token: String,
                        positionTicks: Int64, date: Date) async throws {
        let (path, query) = userDataRoute(endpoints, itemId: itemId, userId: userId)
        let body: [String: Any] = [
            "PlaybackPositionTicks": positionTicks,
            "LastPlayedDate": Self.formatDate(date),
        ]
        _ = try await send(request(server: server, path: path, query: query, method: "POST", token: token, json: body))
    }

    /// POST /UserPlayedItems/{itemId}?userId=…
    func markPlayed(server: URL, endpoints: Endpoints, itemId: String, userId: String, token: String,
                    date: Date) async throws {
        let datePlayed = URLQueryItem(name: "datePlayed", value: Self.formatDate(date))
        let (path, query): (String, [URLQueryItem]) = endpoints.modernPlayed
            ? ("UserPlayedItems/\(itemId)", [URLQueryItem(name: "userId", value: userId), datePlayed])
            : ("Users/\(userId)/PlayedItems/\(itemId)", [datePlayed])
        _ = try await send(request(server: server, path: path, query: query, method: "POST", token: token))
    }

    // MARK: Streams

    /// Eine Ton- oder Untertitelspur laut Server.
    struct StreamTrack: Sendable {
        let index: Int
        let isAudio: Bool
        let isExternal: Bool
        let codec: String
        let language: String?
        let title: String?
        /// Bei externen Untertiteln: Adresse relativ zum Server.
        let deliveryPath: String?
    }

    /// Was der Server über die Datei eines Titels sagt.
    struct PlaybackSource: Sendable {
        let playSessionId: String
        let mediaSourceId: String
        let container: String
        let runTimeTicks: Int64
        let tracks: [StreamTrack]
        let defaultAudioIndex: Int?
        let defaultSubtitleIndex: Int?
        /// Liegt die Datei nicht auf dem Server (Kanäle, z. B. eine Mediathek), nennt er hier ihre Adresse.
        let remoteURL: URL?
    }

    enum PlaybackReport: String, Sendable {
        case start = "Sessions/Playing"
        case progress = "Sessions/Playing/Progress"
        case stopped = "Sessions/Playing/Stopped"
    }

    /// POST /Items/{itemId}/PlaybackInfo: Die App spielt jede Datei selbst ab und fragt deshalb
    /// nur nach den Quellen, nicht nach einer Umrechnung.
    func playbackSource(server: URL, itemId: String, userId: String, token: String, mediaSourceId: String?) async throws -> PlaybackSource {
        var body: [String: Any] = [
            "UserId": userId,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": false,
            "AutoOpenLiveStream": false,
            "DeviceProfile": [
                "Name": "JellyDesk",
                "MaxStreamingBitrate": 1_000_000_000,
                "DirectPlayProfiles": [["Type": "Video"], ["Type": "Audio"]],
                "TranscodingProfiles": [[String: Any]](),
                "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgs", "pgssub", "dvdsub", "dvbsub", "sub", "smi", "ttml", "mov_text"]
                    .flatMap { [["Format": $0, "Method": "Embed"], ["Format": $0, "Method": "External"]] },
            ] as [String: Any],
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        let data = try await send(request(server: server, path: "Items/\(itemId)/PlaybackInfo",
                                          query: [URLQueryItem(name: "userId", value: userId)], method: "POST", token: token, json: body))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = object["MediaSources"] as? [[String: Any]], !sources.isEmpty else {
            throw APIError.invalidResponse
        }
        let source = sources.first { ($0["Id"] as? String) == mediaSourceId } ?? sources[0]
        let tracks: [StreamTrack] = (source["MediaStreams"] as? [[String: Any]] ?? []).compactMap { stream in
            guard let type = stream["Type"] as? String, type == "Audio" || type == "Subtitle",
                  let index = (stream["Index"] as? NSNumber)?.intValue else { return nil }
            return StreamTrack(index: index, isAudio: type == "Audio",
                               isExternal: (stream["IsExternal"] as? Bool) ?? false,
                               codec: (stream["Codec"] as? String) ?? "",
                               language: stream["Language"] as? String,
                               title: (stream["Title"] as? String) ?? (stream["DisplayTitle"] as? String),
                               deliveryPath: stream["DeliveryUrl"] as? String)
        }
        var remote: URL?
        if (source["Protocol"] as? String) == "Http", (source["IsRemote"] as? Bool) == true,
           let path = source["Path"] as? String, let url = URL(string: path), url.isWebURL {
            remote = url
        }
        return PlaybackSource(
            playSessionId: (object["PlaySessionId"] as? String) ?? "",
            mediaSourceId: (source["Id"] as? String) ?? itemId,
            container: (source["Container"] as? String) ?? "",
            runTimeTicks: (source["RunTimeTicks"] as? NSNumber)?.int64Value ?? 0,
            tracks: tracks,
            defaultAudioIndex: (source["DefaultAudioStreamIndex"] as? NSNumber)?.intValue,
            defaultSubtitleIndex: (source["DefaultSubtitleStreamIndex"] as? NSNumber)?.intValue,
            remoteURL: remote)
    }

    /// Adresse der unveränderten Datei: GET /Videos/{itemId}/stream?static=true
    nonisolated static func streamURL(server: URL, itemId: String, mediaSourceId: String, playSessionId: String) -> URL? {
        var url = server
        for part in ["Videos", itemId, "stream"] { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "deviceId", value: SettingsKeys.deviceIdentifier),
        ] + (playSessionId.isEmpty ? [] : [URLQueryItem(name: "playSessionId", value: playSessionId)])
        return components.url
    }

    /// Meldet Beginn, Stand oder Ende einer Wiedergabe. Der Server führt damit „Weiterschauen“
    /// und den Gesehen-Status selbst, wie bei jedem anderen Client.
    func report(_ kind: PlaybackReport, server: URL, token: String, itemId: String, mediaSourceId: String,
                playSessionId: String, positionTicks: Int64, isPaused: Bool, volume: Double) async {
        var body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PositionTicks": max(0, positionTicks),
            "IsPaused": isPaused,
            "IsMuted": volume <= 0,
            "VolumeLevel": Int((min(1, max(0, volume)) * 100).rounded()),
            "CanSeek": true,
            "PlayMethod": "DirectPlay",
        ]
        if !playSessionId.isEmpty { body["PlaySessionId"] = playSessionId }
        _ = try? await send(request(server: server, path: kind.rawValue, method: "POST", token: token, json: body))
    }

    // MARK: Vorschaubilder

    /// GET /Items/{itemId}?userId=…&fields=Trickplay: welche Vorschaubilder der Server für den Titel hat.
    func trickplayInfo(server: URL, itemId: String, userId: String, token: String, mediaSourceId: String?) async -> TrickplayInfo? {
        let query = [URLQueryItem(name: "userId", value: userId), URLQueryItem(name: "fields", value: "Trickplay")]
        guard let data = try? await send(request(server: server, path: "Items/\(itemId)", query: query, token: token)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifest = object["Trickplay"] as? [String: Any] else { return nil }
        return TrickplayInfo.pick(from: manifest, preferredSource: mediaSourceId ?? itemId)
    }

    /// GET /Videos/{itemId}/Trickplay/{width}/{index}.jpg
    func trickplaySheet(server: URL, itemId: String, info: TrickplayInfo, index: Int, token: String) async -> Data? {
        let query = [URLQueryItem(name: "mediaSourceId", value: info.mediaSourceId)]
        guard let data = try? await send(request(server: server, path: "Videos/\(itemId)/Trickplay/\(info.width)/\(index).jpg",
                                                 query: query, token: token)),
              !data.isEmpty, data.count < 40_000_000 else { return nil }
        return data
    }

    // MARK: Datumsangaben

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Jellyfin liefert bis zu sieben Nachkommastellen ("2026-11-10T20:15:30.1234567Z");
    /// die werden vor dem Lesen abgeschnitten.
    static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            text.removeSubrange(dot..<end)
        }
        let hasZone = text.hasSuffix("Z") || text.dropFirst(10).contains("+") || text.dropFirst(10).contains("-")
        if !hasZone { text += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
