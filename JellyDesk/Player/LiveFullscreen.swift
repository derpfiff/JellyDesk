import SwiftUI

/// Ersetzt die Vollbild-Animation des Fensters durch eine mit laufendem Inhalt, solange ein
/// Video zu sehen ist (`live`).
///
/// Standardmäßig friert macOS ein Bild des Fensters ein, zieht es bildfüllend auf und blendet
/// erst am Ende den echten Inhalt ein. Bei einem Video sieht man das als Standbild, das
/// angeschnitten groß wird und dann auf das richtig eingepasste, laufende Bild springt. Hier
/// wächst und schrumpft stattdessen das Fenster selbst; das Video läuft dabei weiter und wird
/// in jedem Schritt passend eingepasst.
///
/// Ohne Video bleibt es bei der Animation des Systems. Sie läuft im Fensterserver und damit in
/// jedem Bild des Bildschirms, auch bei 120 Hz; die eigene muss das Fenster in jedem Schritt
/// neu anordnen und lässt bei einer schweren Seite Bilder aus.
struct LiveFullscreen: NSViewRepresentable {
    /// Läuft gerade ein Video in diesem Fenster?
    var live = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.live = live
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.live = live
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    final class Coordinator {
        private var proxy: WindowDelegateProxy?
        var live = true { didSet { proxy?.live = live } }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if let proxy, window.delegate === proxy { return }
            // SwiftUI ist der eigentliche Delegate des Fensters; alles außer der Vollbild-Animation
            // geht unverändert an ihn weiter.
            let proxy = self.proxy ?? WindowDelegateProxy()
            proxy.live = live
            if window.delegate !== proxy { proxy.original = window.delegate }
            self.proxy = proxy
            window.delegate = proxy
        }
    }
}

extension NSScreen {
    /// Der Rahmen, den ein Vollbildfenster auf diesem Bildschirm bekommt. Bei Bildschirmen mit
    /// Kamera-Aussparung beginnt es unterhalb davon; zielte die Animation auf den ganzen
    /// Bildschirm, spränge das Fenster am Ende um diese Höhe.
    var fullscreenWindowFrame: NSRect {
        var rect = frame
        rect.size.height -= safeAreaInsets.top
        return rect
    }
}

/// Reicht alle Delegate-Aufrufe an den ursprünglichen Delegate weiter und übernimmt nur die
/// Methoden für eine eigene Vollbild-Animation.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    /// Eigene Animation mit laufendem Inhalt (Video) statt der des Systems.
    var live = true
    private(set) var windowedFrame = NSRect.zero
    /// Größe, die das System für das Vollbild vorgesehen hat (unter Kamera-Aussparung und,
    /// je nach Systemeinstellung, unter der Menüleiste).
    private(set) var proposedFullscreenSize: NSSize?

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        let size = original?.window?(window, willUseFullScreenContentSize: proposedSize) ?? proposedSize
        proposedFullscreenSize = size
        return size
    }

    /// Ziel der Animation: der vom System vorgesehene Rahmen, sonst Bildschirm minus Aussparung.
    func fullscreenTarget(on screen: NSScreen) -> NSRect {
        var rect = screen.fullscreenWindowFrame
        if let size = proposedFullscreenSize, size.width > 100, size.height > 100,
           size.width <= screen.frame.width + 1, size.height <= screen.frame.height + 1 {
            rect.size = size
        }
        return rect
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Auch wenn das System hinein animiert: der Rückweg kann mit Video stattfinden.
        if let window = notification.object as? NSWindow { windowedFrame = window.frame }
        original?.windowWillEnterFullScreen?(notification)
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        live ? [window] : nil
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        guard let screen = window.screen else { return }
        let target = fullscreenTarget(on: screen)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }, completionHandler: {
            window.setFrame(target, display: true)
        })
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        live && windowedFrame.width > 100 && windowedFrame.height > 100 ? [window] : nil
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        guard windowedFrame.width > 100, windowedFrame.height > 100 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(windowedFrame, display: true)
        }
    }
}
