import AppKit
import Foundation

/// Fragt bei GitHub nach, ob es für JellyDesk eine neuere Fassung gibt. Kein eigener Installer:
/// bei einem Fund öffnet die App die Release-Seite im Browser, dort lädt und ersetzt der Nutzer
/// die Anwendung selbst. Das reicht für ein kleines Projekt und braucht weder Fremdabhängigkeit
/// noch Entwicklerkonto-Signatur für die eigentliche Update-Logik.
///
/// Geprüft wird höchstens einmal am Tag – zusätzlich jederzeit über „JellyDesk → Nach Updates
/// suchen …“. Wer eine Version einmal weggeklickt hat, bekommt sie nicht noch einmal angeboten.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false
    /// Sitzt der letzte Check hinter einem 403 (Ratenlimit) oder HTTP-Fehler, landet er hier,
    /// damit der Menüeintrag ggf. eine Meldung zeigen kann.
    @Published private(set) var lastError: String?

    /// Veröffentlichungen stehen unter dieser GitHub-Repo-Kennung.
    private let repoOwner = "derpfiff"
    private let repoName = "JellyDesk"

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "updateCheckLastRun"
    private let skippedVersionKey = "updateSkippedVersion"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    // MARK: Hintergrund-Check

    /// Vom App-Start aufgerufen: fragt im Hintergrund einmal am Tag, zeigt den Dialog nur bei
    /// echtem Fund. Fehler bleiben still.
    func checkInBackgroundIfDue() {
        let now = Date()
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           now.timeIntervalSince(last) < 86_400 { return }
        defaults.set(now, forKey: lastCheckKey)
        Task { await check(interactive: false) }
    }

    /// Vom Menüeintrag „Nach Updates suchen …“: zeigt immer eine Antwort an, auch wenn alles
    /// aktuell ist oder der Check fehlgeschlagen ist.
    func checkInteractively() {
        defaults.set(Date(), forKey: lastCheckKey)
        Task { await check(interactive: true) }
    }

    // MARK: Prüflogik

    private struct Release {
        let tag: String
        let name: String
        let notes: String
        let url: URL
    }

    private func check(interactive: Bool) async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        do {
            guard let release = try await fetchLatestRelease() else {
                if interactive { showUpToDate() }
                return
            }
            guard let latest = Version(release.tag), let current = Version(currentVersion) else {
                if interactive { showUpToDate() }
                return
            }
            if latest > current {
                // Eine vom Nutzer übersprungene Version gilt nur für den stillen Check.
                if !interactive, defaults.string(forKey: skippedVersionKey) == latest.canonical { return }
                showUpdateAvailable(release: release, latest: latest)
            } else if interactive {
                showUpToDate()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if interactive { showError(error) }
        }
    }

    private func fetchLatestRelease() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // Keine Kennung des Nutzers in der User-Agent-Zeile.
        request.setValue("JellyDesk/updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }       // noch keine Veröffentlichung
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "UpdateChecker", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub antwortet mit HTTP \(http.statusCode)."])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              let htmlString = object["html_url"] as? String, let html = URL(string: htmlString) else { return nil }
        if (object["draft"] as? Bool) == true { return nil }
        if (object["prerelease"] as? Bool) == true { return nil }
        let name = (object["name"] as? String) ?? tag
        let notes = (object["body"] as? String) ?? ""
        return Release(tag: tag, name: name, notes: notes, url: html)
    }

    // MARK: Anzeige

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private func showUpdateAvailable(release: Release, latest: Version) {
        let alert = NSAlert()
        alert.messageText = "JellyDesk \(latest.canonical) ist verfügbar."
        alert.informativeText = buildInformativeText(release: release)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Release-Seite öffnen")
        alert.addButton(withTitle: "Später")
        alert.addButton(withTitle: "Diese Version überspringen")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.url)
        case .alertThirdButtonReturn:
            defaults.set(latest.canonical, forKey: skippedVersionKey)
        default:
            break
        }
    }

    private func buildInformativeText(release: Release) -> String {
        var text = "Installiert: \(currentVersion)."
        let trimmed = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Knapp halten: maximal 400 Zeichen, damit der Dialog nicht ausufert.
            let notes = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
            text += "\n\n" + notes
        }
        return text
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "JellyDesk \(currentVersion) ist aktuell."
        alert.informativeText = "Es liegt keine neuere Fassung bei GitHub vor."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Konnte nicht bei GitHub nachsehen."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Versionsvergleich nach „Major.Minor.Patch“. Führendes „v“ und Vorab-Kennungen („-beta.1“) werden
/// weggelassen; Vorab-Versionen sind damit gleichwertig mit der entsprechenden regulären.
private struct Version: Comparable {
    let components: [Int]
    let canonical: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        let parts = text.split(separator: ".").map(String.init)
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
        canonical = numbers.map(String.init).joined(separator: ".")
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let a = lhs.components, b = rhs.components
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        lhs.canonical == rhs.canonical
    }
}
