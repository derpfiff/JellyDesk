import SwiftUI

/// Hält die Fensterleiste des Hauptfensters dauerhaft ausgeblendet.
///
/// Die Leiste ist bei uns leer und durchsichtig. Bliebe sie bestehen, zeigte macOS sie im
/// Vollbild als grauen Streifen über dem Inhalt, und beim Wechsel zwischen Fenster und Vollbild
/// würde der Inhalt mehrfach verschoben. Ohne Leiste ist das Layout in beiden Zuständen gleich;
/// die Fensterknöpfe bleiben, weil sie zur Titelzeile gehören.
struct HiddenWindowToolbar: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
            context.coordinator.enforce()
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var toolbarObservation: NSKeyValueObservation?

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func enforce() {
            guard let toolbar = window?.toolbar else { return }
            if toolbar.isVisible { toolbar.isVisible = false }
            // SwiftUI legt seinen eigenen Knopf für die Seitenleiste trotz
            // `.toolbar(removing: .sidebarToggle)` in die Leiste. Wird die Leiste kurz sichtbar
            // (Vollbild, Menüleiste), stünde er neben unserem – zwei verschiedene Knöpfe.
            for index in toolbar.items.indices.reversed()
            where toolbar.items[index].itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar") {
                toolbar.removeItem(at: index)
            }
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            enforce()
            // SwiftUI legt die Leiste bei manchen Zustandswechseln neu an; dann erneut ausblenden.
            let names: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.enforce()
                })
            }
            // SwiftUI füllt die Leiste erst nach dem Öffnen des Fensters und bei manchen Wechseln
            // erneut. Jeder neue Eintrag wird deshalb gleich im nächsten Durchlauf geprüft.
            observers.append(NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let toolbar = note.object as? NSToolbar, toolbar === self.window?.toolbar else { return }
                DispatchQueue.main.async { self.enforce() }
            })
            toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.enforce() }
            }
        }
    }
}

/// Blendet die Fensterknöpfe aus, solange `active` gilt, und zeigt sie nur, während der Zeiger
/// am oberen Fensterrand ist. So liegt während der Wiedergabe nichts auf dem Bild, und die
/// Knöpfe kommen dem Schließen-Knopf der Weboberfläche nicht in die Quere.
struct WindowButtonsOnHover: NSViewRepresentable {
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { coordinator.setActive(active) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private var active = false
        private weak var window: NSWindow?
        private var wantsShown = true
        /// Höhe des Streifens am oberen Rand, in dem die Knöpfe erscheinen.
        private let band: CGFloat = 26

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func setActive(_ value: Bool) {
            if let current = view?.window { window = current }
            guard value != active else { return }
            active = value
            if value {
                window?.acceptsMouseMovedEvents = true
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
                    self?.update()
                    return event
                }
                update()
            } else {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                show(true)
            }
        }

        private func update() {
            if let current = view?.window { window = current }
            guard active, let window else { return }
            let point = window.mouseLocationOutsideOfEventStream
            let inside = point.x >= 0 && point.x <= window.frame.width
                && point.y <= window.frame.height && point.y >= window.frame.height - band
            show(inside)
        }

        /// Richtet sich nach dem tatsächlichen Zustand der Knöpfe, nicht nach einem Merker: so
        /// bleiben sie nie unsichtbar hängen. Ausgeblendete Knöpfe sind auch nicht klickbar.
        private func show(_ value: Bool) {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let target: CGFloat = value ? 1 : 0
            guard buttons.contains(where: { $0.alphaValue != target || $0.isHidden == value }) else { return }
            wantsShown = value
            if value { buttons.forEach { $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                buttons.forEach { $0.animator().alphaValue = target }
            }, completionHandler: { [weak self] in
                guard let self, !self.wantsShown else { return }
                buttons.forEach { $0.isHidden = true }
            })
        }
    }
}
