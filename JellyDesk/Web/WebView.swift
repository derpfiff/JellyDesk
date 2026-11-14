import SwiftUI
import WebKit

/// Zeigt die WKWebView des Modells. Die Ansicht selbst lebt im Modell, damit sie
/// beim Wechsel zwischen „Server“ und „Downloads“ erhalten bleibt.
///
/// SwiftUI verwaltet nur einen schlichten Container, nicht die WKWebView selbst: für das
/// Element-Vollbild (Video im Web-Player) hängt WebKit die Web-Ansicht in ein eigenes Fenster
/// um und setzt einen Platzhalter an ihre Stelle. Verwaltet SwiftUI die WKWebView direkt,
/// kommt das durcheinander und das Vollbild bleibt leer.
struct WebView: NSViewRepresentable {
    let model: WebViewModel

    func makeNSView(context: Context) -> NSView {
        let container = WebContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        container.showsVideo = { [weak model] in model?.isVideoRoute ?? false }
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Nur einhängen, wenn die Web-Ansicht nirgends hängt. Während des Vollbilds
        // gehört sie dem Vollbildfenster von WebKit und bleibt dort.
        if model.webView.superview == nil, container.subviews.isEmpty {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let webView = model.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// Führt die Web-Ansicht durch den Wechsel ins Vollbild und zurück.
///
/// Bekäme die Web-Ansicht in jedem Schritt der Animation die neue Größe, müsste die Seite jedes
/// Mal neu umbrechen. Ihr Bild kommt aus einem anderen Prozess und hinkt dem Fenster dann
/// sichtbar hinterher. Deshalb bekommt sie gleich zu Beginn die Breite, die sie am Ende haben
/// wird, und wird während der Animation nur optisch auf die jeweilige Fenstergröße skaliert;
/// ihre Höhe folgt dem Seitenverhältnis des Fensters. Die Seite baut sich so genau einmal um,
/// ganz am Anfang, wenn die Bewegung einsetzt. Am Ziel steht sie schon in ihrer endgültigen
/// Anordnung und Schärfe, und dort ändert sich nichts mehr.
final class WebContainerView: NSView {
    /// Breite, in der die Seite während des Wechsels angeordnet ist (die Breite am Ziel).
    private var layoutWidth: CGFloat?
    /// Feste Höhe der Seite während des Wechsels, außer im Videoplayer (siehe `begin`).
    private var layoutHeight: CGFloat?
    /// Zeigt die Seite gerade ihren Videoplayer?
    var showsVideo: (@MainActor () -> Bool)?
    /// Größe im Fenster vor dem Vollbild; dorthin geht es beim Verlassen zurück.
    private var windowedSize: CGSize?
    /// Abbild des vorherigen Zustands, das den einen Umbau der Seite überdeckt.
    private var cover: CALayer?
    private var observers: [NSObjectProtocol] = []
    private var repaintTimer: Timer?

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        repaintTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.keepRepainting()
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, let window = self.window, let screen = window.screen,
                  self.bounds.width > 1, self.bounds.height > 1 else { return }
            self.windowedSize = self.bounds.size
            // Nur die eigene Animation braucht die Führung; die des Systems setzt das Fenster
            // in einem Schritt auf die neue Größe.
            guard let proxy = window.delegate as? WindowDelegateProxy, proxy.live else { return }
            let target = proxy.fullscreenTarget(on: screen).size
            // Alles neben der Web-Ansicht (Seitenleiste) behält seine Breite.
            self.begin(layoutWidth: self.bounds.width + target.width - window.frame.width,
                       finalHeight: self.bounds.height + target.height - window.frame.height)
        })
        observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, let window = self.window, self.bounds.width > 1, self.bounds.height > 1,
                  let proxy = window.delegate as? WindowDelegateProxy, proxy.live else { return }
            var width = self.windowedSize?.width
            if width == nil, case let frame = proxy.windowedFrame, frame.width > 100 {
                width = self.bounds.width + frame.width - window.frame.width
            }
            guard let width else { return }
            self.begin(layoutWidth: width, finalHeight: self.windowedSize?.height ?? self.bounds.height)
        })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.finish()
            })
        }
    }

    /// Hält WebKit während des Wechsels am Zeichnen. Bei der Animation des Systems ist das echte
    /// Fenster nicht zu sehen, und WebKit zeichnet eine unsichtbare Seite nicht neu: es bemerkt
    /// die neue Größe, baut die Seite aber erst um, wenn das Fenster wieder erscheint. Für ein
    /// paar Bilder stünde dann noch der alte Inhalt in der neuen Größe da, und die Seite bekäme
    /// ihr `resize` erst danach. Ein angefordertes Abbild erzwingt das Zeichnen sofort.
    private func keepRepainting() {
        repaintTimer?.invalidate()
        let started = Date()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self, Date().timeIntervalSince(started) < 1.5,
                  let webView = self.subviews.compactMap({ $0 as? WKWebView }).first else {
                timer.invalidate()
                return
            }
            webView.takeSnapshot(with: config) { _, _ in }
        }
        RunLoop.main.add(timer, forMode: .common)
        repaintTimer = timer
    }

    /// Ordnet die Seite in der Zielbreite an. Der Umbau dauert ein, zwei Bilder; so lange liegt
    /// ein Abbild dessen darüber, was gerade auf dem Bildschirm zu sehen ist, und blendet dann
    /// in die neu angeordnete Seite über.
    ///
    /// Im Videoplayer folgt die Höhe der Seite dem Fenster, damit das Video in jedem Schritt
    /// mittig sitzt; die Seite ist dort leicht und verkraftet das. Jede andere Seite bekommt
    /// gleich ihre endgültige Höhe: sie müsste sonst in jedem Schritt Regale und Bilder neu
    /// anordnen, und die Bewegung ruckte. Sie liegt oben an. Was beim Vergrößern unten
    /// übersteht, schneidet das Fenster ab; beim Verkleinern ist sie anfangs kürzer als das
    /// Fenster, und darunter bleibt bis zum Ankommen der schwarze Grund sichtbar.
    private func begin(layoutWidth width: CGFloat, finalHeight: CGFloat) {
        guard width > 100, abs(width - bounds.width) > 1 else { return }
        showCover()
        layoutWidth = width
        let video = MainActor.assumeIsolated { showsVideo?() } ?? false
        layoutHeight = video ? nil : max(1, finalHeight.rounded())
        fitContent()
        hideCoverWhenRedrawn()
    }

    /// Am Ziel: Die Seite hat ihre endgültige Breite bereits. Weicht die echte Größe doch ab
    /// (anderes Vollbildmaß als erwartet), wird der kleine Rest wie am Anfang überdeckt.
    private func finish() {
        guard let width = layoutWidth else { return }
        let needsCover = abs(width - bounds.width) > 1
        if needsCover { showCover() }
        layoutWidth = nil
        layoutHeight = nil
        fitContent()
        if needsCover { hideCoverWhenRedrawn() }
    }

    private func showCover() {
        cover?.removeFromSuperlayer()
        cover = nil
        guard let root = layer, let image = onScreenImage() else {
            NSLog("JellyDesk: kein Abbild für den Größenwechsel der Web-Ansicht")
            return
        }
        let picture = CALayer()
        picture.frame = bounds
        picture.contents = image
        picture.contentsGravity = .resize
        picture.zPosition = 10
        picture.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(picture)
        CATransaction.commit()
        cover = picture
    }

    private func hideCoverWhenRedrawn() {
        guard let picture = cover else { return }
        let remove = { [weak self] in
            guard let self, self.cover === picture else { return }
            self.cover = nil
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.09)
            CATransaction.setCompletionBlock { picture.removeFromSuperlayer() }
            picture.opacity = 0
            CATransaction.commit()
        }
        if let webView = subviews.compactMap({ $0 as? WKWebView }).first {
            // Der Rückruf kommt, nachdem WebKit neu gezeichnet hat. Erst der zweite gilt: der
            // erste kann noch vor dem Umbau auf die neue Breite liegen.
            let presented = WKSnapshotConfiguration()
            presented.afterScreenUpdates = true
            presented.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.takeSnapshot(with: presented) { _, _ in
                webView.takeSnapshot(with: presented) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { remove() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { remove() }
    }

    /// Das, was vom eigenen Fenster im Bereich dieser Ansicht gerade zu sehen ist – mit Videobild
    /// und allen Effekten. Ein Bild aus `takeSnapshot` taugt dafür nicht: darin fehlt das Video.
    private func onScreenImage() -> CGImage? {
        guard let window, window.windowNumber > 0, let primary = NSScreen.screens.first else { return nil }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let rect = CGRect(x: onScreen.minX, y: primary.frame.height - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        // Die Funktion ist im aktuellen SDK nicht mehr deklariert, für eigene Fenster aber weiter
        // vorhanden und braucht dafür keine Freigabe der Bildschirmaufnahme.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingBestResolution: UInt32 = (1 << 0) | (1 << 3)
        return capture(rect, includingWindow, UInt32(window.windowNumber), ignoreFramingBestResolution)?.takeRetainedValue()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitContent()
    }

    override func layout() {
        super.layout()
        fitContent()
    }

    private func fitContent() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        if let cover, cover.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cover.frame = bounds
            CATransaction.commit()
        }
        // Die Web-Ansicht hängt nur außerhalb des Vollbilds von WebKit hier.
        for view in subviews {
            guard let layer = view.layer else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let layoutWidth {
                // Feste Breite, Höhe im Seitenverhältnis des Containers; die Ebene wird von der
                // linken unteren Ecke aus auf die Größe des Containers gezogen. Der Rahmen der
                // Ansicht ändert dabei nur seine Höhe, sodass die Seite ihre Anordnung behält.
                let scale = size.width / layoutWidth
                let height = layoutHeight ?? max(1, (size.height / scale).rounded())
                view.autoresizingMask = []
                if view.frame.origin != .zero || view.frame.width != layoutWidth || view.frame.height != height {
                    view.frame = NSRect(x: 0, y: 0, width: layoutWidth, height: height)
                }
                layer.anchorPoint = .zero
                layer.position = .zero
                // Oberkante der Seite an der Oberkante des Containers halten.
                layer.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 0,
                                                           ty: (size.height - height * scale).rounded()))
            } else {
                layer.setAffineTransform(.identity)
                if view.frame != bounds { view.frame = bounds }
                view.autoresizingMask = [.width, .height]
            }
            CATransaction.commit()
        }
    }
}
