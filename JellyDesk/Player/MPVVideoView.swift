import AppKit
import QuartzCore

/// CAMetalLayer für die MoltenVK-Ausgabe von libmpv.
///
/// Zwei Dinge müssen immer zusammenpassen, sonst zeichnet mpv mit falschen Maßen (Bild klein in
/// der Ecke oder angeschnitten): die Pixelgröße der Zeichenfläche und die „natürliche“ Größe
/// der Ebene (ihre `bounds` mal `contentsScale`). Weichen sie voneinander ab, legt die
/// Grafikschicht die Zeichenfläche von sich aus in der natürlichen Größe neu an – ohne dass mpv
/// davon erfährt. Deshalb:
///
/// - Die `bounds` der Ebene ändern sich nie von allein. Passt die Ebene nicht zur Ansicht,
///   wird sie nur optisch skaliert (Transformation), was Core Animation ohne Zutun erledigt.
/// - Eine neue Größe wird erst angekündigt. mpv liest sie, wenn es seine Ausgabe neu einstellt,
///   legt die Zeichenfläche in dieser Größe an und setzt dabei `drawableSize`. Genau in diesem
///   Aufruf übernimmt die Ebene auch die neuen `bounds`.
final class MPVMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    private var pendingPixels: CGSize?
    private var containerSize = CGSize(width: 960, height: 540)
    /// Wird aufgerufen (vom Render-Thread), sobald mpv die angekündigte Größe übernommen hat.
    var onPendingApplied: (() -> Void)?

    /// Läuft der Aufruf gerade innerhalb von mpvs `moltenvk_reconfig`? Wird nur geprüft, solange
    /// eine Größe angekündigt ist (wenige Bilder lang), kostet also im Normalbetrieb nichts.
    private static func calledFromOutputReconfig() -> Bool {
        Thread.callStackSymbols.prefix(12).contains { $0.contains("moltenvk_reconfig") }
    }

    /// Kündigt eine neue Zeichenfläche an, ohne die bestehende anzufassen.
    func announce(_ pixels: CGSize?) {
        lock.lock()
        pendingPixels = pixels
        lock.unlock()
    }

    /// Legt Ebene und Zeichenfläche sofort fest. Nur, solange mpv nicht zeichnet.
    func setRenderSize(pixels: CGSize, scale: CGFloat) {
        announce(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsScale = scale
        bounds = CGRect(x: 0, y: 0, width: pixels.width / scale, height: pixels.height / scale)
        CATransaction.commit()
        super.drawableSize = pixels
        place()
    }

    /// Die Ansicht hat eine neue Größe: Ebene mittig setzen und optisch einpassen.
    func setContainer(_ size: CGSize) {
        lock.lock()
        containerSize = size
        lock.unlock()
        place()
    }

    private func place() {
        lock.lock()
        let container = containerSize
        lock.unlock()
        let size = bounds.size
        guard size.width > 1, size.height > 1, container.width > 1, container.height > 1 else { return }
        let factor = min(container.width / size.width, container.height / size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = CGPoint(x: container.width / 2, y: container.height / 2)
        setAffineTransform(CGAffineTransform(scaleX: factor, y: factor))
        CATransaction.commit()
    }

    override var drawableSize: CGSize {
        get {
            lock.lock()
            let pending = pendingPixels
            lock.unlock()
            // Die angekündigte Größe sieht nur mpv, und nur beim Neueinstellen seiner Ausgabe.
            if let pending, Self.calledFromOutputReconfig() { return pending }
            return super.drawableSize
        }
        set {
            // MoltenVK setzt die Größe kurz auf 1×1, um die Darstellung abzuschließen; das
            // flackert und kann hängen bleiben (mpv-player/mpv#13651).
            guard Int(newValue.width) > 1, Int(newValue.height) > 1 else { return }
            lock.lock()
            var applied = false
            if let pending = pendingPixels, abs(pending.width - newValue.width) < 1.5, abs(pending.height - newValue.height) < 1.5 {
                pendingPixels = nil
                applied = true
            }
            lock.unlock()
            if applied {
                // Im selben Zug die Maße der Ebene nachziehen, damit natürliche Größe und
                // Zeichenfläche keinen Augenblick auseinanderliegen.
                let scale = contentsScale
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bounds = CGRect(x: 0, y: 0, width: newValue.width / scale, height: newValue.height / scale)
                CATransaction.commit()
                super.drawableSize = newValue
                place()
                CATransaction.flush()
                onPendingApplied?()
            } else {
                super.drawableSize = newValue
            }
        }
    }

    /// Der EDR-Modus des Bildschirms lässt sich nur vom Hauptthread aus einschalten;
    /// mpv setzt den Wert für target-colorspace-hint aber von seinem Render-Thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

/// Die Ansicht, in deren Metal-Ebene libmpv über Vulkan/MoltenVK zeichnet.
///
/// Die Ebene hat das Seitenverhältnis des Videos und liegt mittig in der Ansicht. Ändert sich
/// die Größe der Ansicht (Fenster ziehen, Vollbild), wird die Ebene sofort optisch eingepasst;
/// das Bild stimmt also in jedem Augenblick. Gezeichnet wird von Anfang an mindestens in
/// Vollbildgröße, sodass der Wechsel ins Vollbild und zurück ohne Umstellen der Ausgabe
/// auskommt. Nur wenn mehr Pixel nötig werden (größerer Bildschirm), meldet die Ansicht
/// `onNeedsRefit`, und der Player lässt mpv die Ausgabe umstellen; der Decoder läuft weiter.
final class MPVVideoView: NSView {
    let metalLayer = MPVMetalLayer()

    /// Die Fenstergröße hat sich beruhigt und weicht von der gerenderten Größe ab.
    var onNeedsRefit: (() -> Void)?

    private var aspect: CGFloat = 16.0 / 9.0
    /// Pixelmaße der Zeichenfläche, wie zuletzt festgelegt oder angekündigt.
    private var renderPixels = CGSize(width: 1920, height: 1080)
    private var refitCheck: DispatchWorkItem?
    /// Fläche (Punkte), für die als Nächstes gerendert werden soll, z. B. der ganze Bildschirm
    /// kurz vor dem Wechsel ins Vollbild. nil: die jetzige Ansicht.
    private var targetArea: CGSize?
    /// Während des Wechsels ins Vollbild oder zurück gilt diese Fläche statt der Ansicht, die
    /// gerade wächst oder schrumpft. Sonst stellte mpv mitten in der Animation auf eine
    /// Zwischengröße um, und das Bild wäre kurz grob.
    private var transitionArea: CGSize?
    private var fullscreenObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]

        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.addSublayer(metalLayer)
        metalLayer.setContainer(bounds.size)
        applyRenderSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    deinit {
        fullscreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Fläche, die die Ansicht im Vollbild auf dem jetzigen Bildschirm einnimmt.
    private var fullscreenArea: CGSize? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        return (window?.delegate as? WindowDelegateProxy)?.fullscreenTarget(on: screen).size
            ?? screen.fullscreenWindowFrame.size
    }

    /// Pixelmaße der größten Fläche mit dem Seitenverhältnis des Videos, die in `area`
    /// (sonst die Ansicht) passt.
    private func neededPixels(in given: CGSize? = nil) -> CGSize {
        var source = given ?? bounds.size
        // Gezeichnet wird immer mindestens in Vollbildgröße, auch im kleinen Fenster; dort
        // verkleinert die Ebene das Bild nur optisch. So muss mpv beim Wechsel ins Vollbild und
        // zurück seine Ausgabe nicht umstellen – genau dieses Umstellen ließ das Bild kurz stehen.
        if let full = fullscreenArea {
            source = CGSize(width: max(source.width, full.width), height: max(source.height, full.height))
        }
        let area = CGSize(width: max(source.width, 2), height: max(source.height, 2))
        var width = area.width
        var height = width / aspect
        if height > area.height {
            height = area.height
            width = height * aspect
        }
        let scale = backingScale
        return CGSize(width: max(2, (width * scale).rounded()), height: max(2, (height * scale).rounded()))
    }

    /// Vor dem Einrichten der Videoausgabe für eine neue Datei: Seitenverhältnis übernehmen und
    /// die Zeichenfläche auf die jetzige Ansicht auslegen.
    func prepare(aspect newAspect: CGFloat?) {
        if let newAspect, newAspect.isFinite, newAspect > 0.1, newAspect < 10 {
            aspect = newAspect
        } else {
            aspect = 16.0 / 9.0
        }
        applyRenderSize()
    }

    /// Legt die Zeichenfläche sofort fest. Nur aufrufen, solange mpv nicht zeichnet (vor dem
    /// Laden einer Datei); im laufenden Betrieb stattdessen `beginRefit`.
    func applyRenderSize() {
        let pixels = neededPixels(in: targetArea)
        targetArea = nil
        renderPixels = pixels
        metalLayer.setRenderSize(pixels: pixels, scale: backingScale)
    }

    /// Die gerenderte Größe passt nicht mehr zur Ansicht.
    var needsRefit: Bool {
        let needed = neededPixels(in: targetArea ?? transitionArea)
        let ratio = needed.width / max(renderPixels.width, 1)
        return ratio > 1.015 || ratio < 0.985
    }

    /// Kündigt die neue Zeichenfläche an, während mpv weiterzeichnet. Danach muss der Player
    /// mpv veranlassen, seine Ausgabe neu einzustellen; erst dabei wechselt die Größe wirklich.
    func beginRefit() {
        let pixels = neededPixels(in: targetArea)
        targetArea = nil
        renderPixels = pixels
        metalLayer.announce(pixels)
    }

    private func sizeChanged() {
        metalLayer.setContainer(bounds.size)
        refitCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionArea == nil, self.needsRefit else { return }
            if let onNeedsRefit = self.onNeedsRefit { onNeedsRefit() } else { self.applyRenderSize() }
        }
        refitCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    override func layout() {
        super.layout()
        metalLayer.setContainer(bounds.size)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullscreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullscreenObservers = []
        if let window {
            let center = NotificationCenter.default
            // Vor dem Wechsel ins Vollbild schon in der Zielgröße rendern, damit beim Ankommen
            // kein vergrößertes, grobes Zwischenbild zu sehen ist.
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, let screen = self.window?.screen else { return }
                self.refitCheck?.cancel()
                let area = (self.window?.delegate as? WindowDelegateProxy)?.fullscreenTarget(on: screen).size
                    ?? screen.fullscreenWindowFrame.size
                self.transitionArea = area
                self.targetArea = area
                guard self.needsRefit else {
                    self.targetArea = nil
                    return
                }
                if let onNeedsRefit = self.onNeedsRefit { onNeedsRefit() } else { self.applyRenderSize() }
            })
            // Beim Verlassen bleibt die große Zeichenfläche, bis das Fenster angekommen ist;
            // verkleinert dargestellt ist sie ohnehin scharf.
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.refitCheck?.cancel()
                let scale = self.backingScale
                self.transitionArea = CGSize(width: self.renderPixels.width / scale, height: self.renderPixels.height / scale)
            })
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                fullscreenObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.transitionArea = nil
                    self?.sizeChanged()
                })
            }
        }
        sizeChanged()
    }
}
