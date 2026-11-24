import AppKit

/// Bild-in-Bild über das System von macOS, für mpv und AVKit gleich.
///
/// Das öffentliche `AVPictureInPictureController` nimmt nur eine `AVPlayerLayer`; mpv zeichnet aber
/// in eine eigene Metal-Ebene. Das System-Bild-in-Bild selbst steckt im privaten Framework `PIP`
/// (`PIPViewController`), das auch Safari, QuickTime und IINA benutzen: es zeigt einen beliebigen
/// View Controller im schwebenden Fenster mit Play/Pause, Zurück-ins-Fenster und Schließen.
/// Die Klasse wird zur Laufzeit gesucht; fehlt sie, ist `isAvailable` falsch und der Knopf aus.
///
/// Die Ansicht des Players wandert für die Dauer in das Bild-in-Bild-Fenster und danach zurück;
/// der Decoder läuft dabei weiter. Das Player-Fenster wird solange ausgeblendet.
@MainActor
final class PictureInPicture: NSObject {
    /// Aufrufe aus dem Bild-in-Bild-Fenster.
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    /// Das Fenster ist zu, die Ansicht wieder im Player-Fenster (auch nach „Schließen“).
    var onDidClose: (() -> Void)?
    /// „Schließen“ im Bild-in-Bild-Fenster (nicht „zurück ins Fenster“).
    var onStop: (() -> Void)?

    private var pip: NSObject?
    private var content: NSViewController?
    /// Das Fenster, aus dem die Ansicht kam; solange Bild-in-Bild läuft, ist es ausgeblendet.
    private(set) weak var playerWindow: NSWindow?
    private var playerFrame: NSRect = .zero

    var isActive: Bool { pip != nil }

    private static let controllerClass: NSObject.Type? = {
        _ = dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW)
        guard let type = NSClassFromString("PIPViewController") as? NSObject.Type else { return nil }
        let needed = ["presentViewControllerAsPictureInPicture:", "setDelegate:",
                      "setAspectRatio:", "setPlaying:", "setReplacementWindow:", "setReplacementRect:"]
        guard needed.allSatisfy({ type.instancesRespond(to: NSSelectorFromString($0)) }) else { return nil }
        // Schließen muss sich lassen: entweder der neue Aufruf oder ein eigenes dismissViewController:.
        let ownDismiss = class_getInstanceMethod(type, NSSelectorFromString("dismissViewController:")).map(method_getImplementation)
            != class_getInstanceMethod(NSViewController.self, NSSelectorFromString("dismissViewController:")).map(method_getImplementation)
        let canDismiss = type.instancesRespond(to: NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")) || ownDismiss
        return canDismiss ? type : nil
    }()

    static var isAvailable: Bool { controllerClass != nil }

    /// Holt `view` aus dem Player-Fenster und zeigt sie im Bild-in-Bild.
    func start(view: NSView, aspect: CGFloat?, playing: Bool) {
        guard pip == nil, let type = Self.controllerClass else { return }
        let window = view.window
        playerWindow = window
        playerFrame = window.map { view.convert(view.bounds, to: nil).intersection($0.contentView?.bounds ?? .zero) } ?? .zero

        let controller = type.init()
        let content = NSViewController()
        view.removeFromSuperview()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 270)
        view.autoresizingMask = [.width, .height]
        content.view = view

        let ratio = aspect.flatMap { $0.isFinite && $0 > 0.1 && $0 < 10 ? $0 : nil } ?? 16.0 / 9.0
        controller.setValue(NSValue(size: NSSize(width: ratio * 1000, height: 1000)), forKey: "aspectRatio")
        controller.setValue(self, forKey: "delegate")
        controller.setValue(playing, forKey: "playing")
        if controller.responds(to: NSSelectorFromString("setUserCanResize:")) {
            controller.setValue(true, forKey: "userCanResize")
        }
        pip = controller
        self.content = content
        controller.perform(NSSelectorFromString("presentViewControllerAsPictureInPicture:"), with: content)
        window?.orderOut(nil)
    }

    /// Schließt das Bild-in-Bild von der App aus (Knopf, Titelwechsel, Fenster zu).
    func stop() {
        guard let pip, let content else { return }
        prepareReturn()
        // Neuere Systeme: dismissPictureInPictureWithCompletionHandler:. Ältere kennen nur
        // dismissViewController:, das PIPViewController dann selbst umsetzt; erbt die Klasse es nur
        // von NSViewController, passiert damit nichts.
        let withCompletion = NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")
        if pip.responds(to: withCompletion) {
            let done: @convention(block) () -> Void = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish() } }
            }
            pip.perform(withCompletion, with: done)
        } else {
            pip.perform(NSSelectorFromString("dismissViewController:"), with: content)
        }
        awaitDismissal()
    }

    /// Nicht jede Systemversion meldet das Ende (pipDidClose bzw. der Abschluss-Block bleiben unter
    /// macOS 26 aus). Verlässlich ist: das System nimmt die Ansicht aus seinem Fenster. Darauf wird
    /// kurz gewartet und dann aufgeräumt; kommt die Meldung doch, ist finish() schon erledigt.
    private func awaitDismissal(attempt: Int = 0) {
        guard pip != nil, let view = content?.view else { return }
        if view.window == nil || attempt >= 40 {
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.awaitDismissal(attempt: attempt + 1) }
        }
    }

    func setPlaying(_ playing: Bool) {
        pip?.setValue(playing, forKey: "playing")
    }

    func setAspect(_ aspect: CGFloat?) {
        guard let pip, let aspect, aspect.isFinite, aspect > 0.1, aspect < 10 else { return }
        pip.setValue(NSValue(size: NSSize(width: aspect * 1000, height: 1000)), forKey: "aspectRatio")
    }

    /// Zielt die Rückkehr-Animation auf das Player-Fenster und holt es wieder nach vorn.
    private func prepareReturn() {
        guard let pip else { return }
        if let window = playerWindow {
            pip.setValue(window, forKey: "replacementWindow")
            let rect = playerFrame.isEmpty ? (window.contentView?.bounds ?? .zero) : playerFrame
            pip.setValue(NSValue(rect: rect), forKey: "replacementRect")
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finish() {
        guard pip != nil else { return }
        // Die Ansicht aus dem View Controller lösen; das Player-Fenster setzt sie wieder ein.
        content?.view.removeFromSuperview()
        pip = nil
        content = nil
        playerWindow?.makeKeyAndOrderFront(nil)
        onDidClose?()
    }

    // MARK: PIPViewControllerDelegate (informell, über die Objective-C-Laufzeit)

    @objc func pipShouldClose(_ pip: NSObject) -> Bool { true }

    @objc func pipWillClose(_ pip: NSObject) {
        prepareReturn()
        awaitDismissal()
    }

    @objc func pipDidClose(_ pip: NSObject) {
        finish()
    }

    @objc func pipActionPlay(_ pip: NSObject) {
        onPlay?()
    }

    @objc func pipActionPause(_ pip: NSObject) {
        onPause?()
    }

    @objc func pipActionStop(_ pip: NSObject) {
        onStop?()
    }
}
