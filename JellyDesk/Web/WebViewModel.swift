import AppKit
import WebKit

/// Reicht Nachrichten weiter, ohne dass der WKUserContentController das Modell festhält.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Wie oben, für den Kanal mit Antwort.
private final class WeakReplyMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WebViewModel?

    init(_ target: WebViewModel) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let target = self?.target else {
                replyHandler(nil, "nicht verfügbar")
                return
            }
            if message.name == WebViewModel.playBridgeName {
                target.handlePlayMessage(message, reply: replyHandler)
            } else {
                target.handleWindowMessage(message, reply: replyHandler)
            }
        }
    }
}

/// Besitzt die eine WKWebView der App und ist ihr Delegate. Die Weboberfläche bleibt
/// unverändert: es werden weder CSS noch JavaScript eingeschleust und kein window.NativeShell
/// definiert. Die App meldet nur zwei Nachrichtenkanäle an: „atvDownload“ für Downloads und
/// „atvWindow“, über den die Weboberfläche das Fenster-Vollbild der App auslöst.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    static let bridgeName = "atvDownload"
    static let windowBridgeName = "atvWindow"
    static let playBridgeName = "atvPlay"

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// Der Server antwortet nicht. Getrennt von `loadError`: die Weboberfläche kann aus dem
    /// Zwischenspeicher des Browsers noch laden, obwohl der Server fort ist.
    @Published private(set) var unreachable: String?
    /// Die Seite des Servers ist einmal vollständig angekommen; bis dahin zeigt die App einen
    /// eigenen Ladezustand statt der leeren Web-Ansicht.
    @Published private(set) var hasPage = false
    /// Die Weboberfläche zeigt gerade ihren Videoplayer (Route „#/video“).
    @Published private(set) var isVideoRoute = false

    let webView: WKWebView
    private(set) var serverURL: URL?
    private var probeTask: Task<Void, Never>?
    private var probeNumber = 0
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let downloads: DownloadManager
    private let notices: Notices
    private let store: OfflineStore
    private let streams: StreamSessions
    /// Kennung für ein Player-Fenster, das die Oberfläche öffnen soll (Download oder Stream).
    @Published private(set) var playerToOpen: String?
    private var observations: [NSKeyValueObservation] = []
    /// Seitenverhältnis des Videos, das die Weboberfläche gerade zeigt; von ihr gemeldet.
    private(set) var videoAspect: CGFloat?
    /// Vollbild-Zustand des Fensters, wie er nach dem laufenden Wechsel gilt. `styleMask` hinkt
    /// während der Animation hinterher; eine Abfrage in dieser Zeit bekäme sonst den alten Stand.
    private var windowFullscreen: Bool?
    private var fullscreenObservers: [NSObjectProtocol] = []
    /// Ziel-Dateien laufender Browser-Downloads (Rückfall über WKDownload).
    private var fileDownloads: [ObjectIdentifier: URL] = [:]

    init(downloads: DownloadManager, notices: Notices, store: OfflineStore, streams: StreamSessions) {
        self.downloads = downloads
        self.notices = notices
        self.store = store
        self.streams = streams

        let config = WKWebViewConfiguration()
        // Dauerhafter Speicher: Anmeldung, Cookies und LocalStorage überleben den Neustart.
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        // Bild-in-Bild ist in einer WKWebView auf dem Mac ab Werk abgeschaltet; der Knopf im
        // Web-Player bliebe ohne Wirkung. Einen öffentlichen Schalter gibt es dafür nicht.
        if config.preferences.responds(to: Selector(("_setAllowsPictureInPictureMediaPlayback:"))) {
            config.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        // Wie Safari ausweisen, damit Jellyfin-Web dieselben Wiedergabeprofile wählt wie dort.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        webView = WKWebView(frame: .zero, configuration: config)
        // Kein Zurück/Vorwärts per Wischen: die Geste gilt für jedes waagerechte Wischen und kam
        // dem Blättern in den Regalen der Weboberfläche in die Quere. Zurück und Vorwärts gibt
        // es über die Knöpfe in der Seitenleiste und ⌘[ / ⌘].
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        // Flächen außerhalb der Seite (z. B. beim Wechsel ins Vollbild) schwarz statt weiß.
        webView.underPageBackgroundColor = .black
        // Ohne eigene Grundfläche: eine noch leere Web-Ansicht wäre sonst weiß. Einen öffentlichen
        // Schalter gibt es auf dem Mac dafür nicht.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }

        super.init()

        // Die einzigen Eingriffe: die Nachrichtenkanäle aus docs/NATIVE-BRIDGE.md.
        config.userContentController.add(WeakScriptMessageHandler(self), name: Self.bridgeName)
        config.userContentController.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: Self.windowBridgeName)
        config.userContentController.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: Self.playBridgeName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let center = NotificationCenter.default
        for (name, value) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)] {
            fullscreenObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow, window === self.webView.window else { return }
                    self.windowFullscreen = value
                }
            })
        }

        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoBack
                DispatchQueue.main.async { self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.canGoForward
                DispatchQueue.main.async { self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                let value = view.isLoading
                DispatchQueue.main.async { self?.isLoading = value }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                let fragment = view.url?.fragment ?? ""
                let value = fragment.hasPrefix("/video") || fragment.hasPrefix("!/video")
                DispatchQueue.main.async { if self?.isVideoRoute != value { self?.isVideoRoute = value } }
            },
        ]
    }

    // MARK: Navigation

    func load(server: URL) {
        if serverURL == server, webView.url != nil, loadError == nil { return }
        if serverURL != server { hasPage = false }
        serverURL = server
        loadError = nil
        webView.load(URLRequest(url: server))
        probe()
    }

    func goHome() {
        guard let serverURL else { return }
        loadError = nil
        webView.load(URLRequest(url: serverURL))
        probe()
    }

    func reload() {
        loadError = nil
        // Am Zwischenspeicher vorbei: wer neu lädt, will den Stand des Servers sehen.
        if webView.url == nil || !hasPage { goHome() } else { webView.reloadFromOrigin(); probe() }
    }

    /// Verwirft die zwischengespeicherten Dateien der Weboberfläche und lädt neu. Anmeldung,
    /// Cookies und LocalStorage bleiben. Nötig, wenn auf dem Server eine Datei unter gleichem
    /// Namen ersetzt wurde (eigenes Logo, eigene Symbole): solche Dateien fragt die Seite erst
    /// beim Blättern an, und dann käme sonst weiter die alte Kopie.
    func clearCacheAndReload() {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            self?.reload()
        }
    }

    /// Fragt den Server direkt, ob er da ist. Auf das Laden der Seite ist dafür kein Verlass: bei
    /// einem stummen Server läuft es eine Minute ins Leere, und liegt die Weboberfläche noch im
    /// Zwischenspeicher, gelingt es sogar. Solange der Server fehlt, wird alle paar Sekunden
    /// erneut gefragt und die Seite von selbst geladen, sobald er wieder antwortet.
    private func probe() {
        guard let server = serverURL else { return }
        probeTask?.cancel()
        probeNumber += 1
        let number = probeNumber
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                var request = URLRequest(url: server.appendingPathComponent("System/Info/Public"))
                request.cachePolicy = .reloadIgnoringLocalCacheData
                var failure: String?
                do {
                    let (_, response) = try await Self.probeSession.data(for: request)
                    // Jede Antwort zählt: auch ein Fehlerstatus kommt von einem lebenden Server.
                    if !(response is HTTPURLResponse) { failure = "Keine gültige Antwort." }
                } catch {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    failure = error.localizedDescription
                }
                guard let self, !Task.isCancelled, self.probeNumber == number, self.serverURL == server else { return }
                if let failure {
                    if self.unreachable == nil {
                        self.unreachable = failure
                        self.webView.stopLoading()
                    }
                } else {
                    if self.unreachable != nil {
                        self.unreachable = nil
                        self.loadError = nil
                        self.hasPage = false
                        self.webView.load(URLRequest(url: server))
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    private func isServerHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let serverHost = serverURL?.host?.lowercased() else { return false }
        return host == serverHost
    }

    private func isWebScheme(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

// MARK: - Download-Brücke

extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName else { return }

        // Der Kanal ist in jedem Frame sichtbar, auch in eingebetteten fremden Seiten
        // (z. B. dem YouTube-Trailer). Angenommen wird nur das Hauptdokument des Servers.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              let serverHost = serverURL?.host?.lowercased(),
              origin.host.lowercased() == serverHost else {
            NSLog("JellyDesk: Download-Nachricht von fremder Herkunft verworfen (%@)", origin.host)
            return
        }

        do {
            let request = try DownloadRequest(messageBody: message.body)
            downloads.receive(request)
        } catch {
            notices.post("Download-Nachricht abgelehnt: \(error.localizedDescription)")
        }
    }
}

// MARK: - Wiedergabe-Brücke

extension WebViewModel {
    /// Die Weboberfläche wollte Titel abspielen und fragt, ob die App das übernimmt
    /// (`{ type: "play", … }`, siehe docs/NATIVE-BRIDGE.md). Antwort: `{ handled: Bool }`.
    /// Bei `true` bricht die Weboberfläche ihre eigene Wiedergabe ab, und die App spielt die
    /// Dateien unverändert im eigenen Player; bei `false` läuft alles wie im Browser.
    fileprivate func handlePlayMessage(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, let server = serverURL,
              let serverHost = server.host?.lowercased(), origin.host.lowercased() == serverHost else {
            reply(nil, "fremde Herkunft")
            return
        }
        guard UserDefaults.standard.bool(forKey: SettingsKeys.nativeStreaming) else {
            reply(["handled": false], nil)
            return
        }
        do {
            let request = try StreamRequest(messageBody: message.body)
            // Das Token darf nur an den Server gehen, dessen Seite die App gerade zeigt.
            guard request.serverUrl.hasSameOrigin(as: server) else {
                reply(["handled": false], nil)
                return
            }
            // Liegt der Titel schon vollständig auf der Platte, spielt die App die Datei.
            let main = request.items[request.startIndex...].first { !$0.isIntro }
            if let main, request.items.filter({ !$0.isIntro }).count == 1,
               let local = store.items.first(where: { $0.itemId == main.itemId && $0.state == .completed && $0.isOriginal }),
               FileManager.default.fileExists(atPath: local.fileURL.path) {
                playerToOpen = local.id
            } else {
                playerToOpen = streams.register(request)
            }
            reply(["handled": true], nil)
        } catch {
            NSLog("JellyDesk: Wiedergabe-Nachricht abgelehnt: %@", error.localizedDescription)
            reply(["handled": false], nil)
        }
    }

    func playerOpened() {
        playerToOpen = nil
    }
}

// MARK: - Fenster-Brücke

extension WebViewModel {
    /// Vollbild über das Fenster der App statt über das Element-Vollbild von WebKit. Dessen
    /// Animation springt; der Wechsel des Fensters läuft mit laufendem Bild (siehe LiveFullscreen).
    /// Nachricht: `{ type: "fullscreen", action: "enter" | "exit" | "toggle" | "state" }`,
    /// Antwort: `{ fullscreen: Bool }` mit dem Zustand, der danach gilt.
    fileprivate func handleWindowMessage(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == Self.windowBridgeName, message.frameInfo.isMainFrame,
              let serverHost = serverURL?.host?.lowercased(),
              origin.host.lowercased() == serverHost else {
            reply(nil, "fremde Herkunft")
            return
        }
        guard let body = message.body as? [String: Any] else {
            reply(nil, "unbekannte Nachricht")
            return
        }
        // `{ type: "video", aspect: Breite / Höhe }`: damit skaliert die App die Seite beim
        // Wechsel ins Vollbild so, dass das Video danach genau so groß ist wie währenddessen.
        if body["type"] as? String == "video" {
            if let aspect = (body["aspect"] as? NSNumber)?.doubleValue, aspect.isFinite, aspect > 0.2, aspect < 6 {
                videoAspect = CGFloat(aspect)
            }
            reply(["ok": true], nil)
            return
        }
        guard body["type"] as? String == "fullscreen", let window = webView.window else {
            reply(nil, "unbekannte Nachricht")
            return
        }
        let isFullscreen = windowFullscreen ?? window.styleMask.contains(.fullScreen)
        let target: Bool
        switch body["action"] as? String {
        case "enter": target = true
        case "exit": target = false
        case "toggle": target = !isFullscreen
        default: target = isFullscreen
        }
        if target != isFullscreen {
            windowFullscreen = target
            window.toggleFullScreen(nil)
        }
        reply(["fullscreen": target], nil)
    }
}

// MARK: - Navigation

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""

        // mailto:, tel: und Ähnliches an das System geben.
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        // Angeklickte Links auf fremde Domains öffnet der Standardbrowser. Eingebettete Frames
        // (Trailer) und Weiterleitungen des Servers selbst bleiben unberührt.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           isWebScheme(url), !isServerHost(url) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Rückfall für gewöhnliche Datei-Downloads: alles, was die Ansicht nicht darstellen kann
        // oder was der Server als Anhang ausliefert.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Nach einem fehlgeschlagenen Laden zeigt WebKit eine leere Seite an; die zählt nicht
        // als Erfolg, sonst verschwände der Hinweis und es bliebe eine weiße Fläche.
        guard let url = webView.url, isWebScheme(url) else { return }
        loadError = nil
        hasPage = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// Jellyfin-Web ist eine Einzelseiten-Anwendung: scheitert das Laden des Hauptdokuments,
    /// ist der Server nicht erreichbar. Dann zeigt die App eine eigene Fehlerseite mit „Erneut laden“.
    private func report(_ error: Error) {
        let nsError = error as NSError
        // Abgebrochene Ladevorgänge (neue Navigation, Umwandlung in einen Download) sind kein Fehler.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 || nsError.code == 204 { return }
        loadError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Fenster, Dialoge

extension WebViewModel: WKUIDelegate {
    /// target=_blank und window.open: Seiten des Servers bleiben in derselben Ansicht,
    /// fremde Domains gehen an den Standardbrowser. Ein zweites Fenster gibt es nicht.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if isWebScheme(url), !isServerHost(url) {
            NSWorkspace.shared.open(url)
        } else if isWebScheme(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @discardableResult
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = webView.window {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

// MARK: - Gewöhnliche Datei-Downloads

extension WebViewModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let fm = FileManager.default
        guard let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let name = FileNameSanitizer.component(suggestedFilename, fallback: "Download", isFileName: true)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var target = folder.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)"))
            counter += 1
        }
        fileDownloads[ObjectIdentifier(download)] = target
        notices.post("Lade „\(target.lastPathComponent)“ in den Ordner Downloads …")
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let target = fileDownloads.removeValue(forKey: ObjectIdentifier(download)) {
            notices.post("„\(target.lastPathComponent)“ liegt im Ordner Downloads.")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let target = fileDownloads.removeValue(forKey: ObjectIdentifier(download))
        notices.post("Download von „\(target?.lastPathComponent ?? "Datei")“ fehlgeschlagen: \(error.localizedDescription)")
    }
}
