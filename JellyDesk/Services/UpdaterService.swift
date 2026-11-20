import Foundation
import Sparkle

/// Dünne Hülle um Sparkles `SPUStandardUpdaterController`.
///
/// Erwartet, dass in der Info.plist `SUFeedURL` auf eine Appcast-XML zeigt und `SUPublicEDKey`
/// den öffentlichen EdDSA-Schlüssel enthält (`docs/UPDATES.md`). Ohne gültigen Schlüssel läuft der
/// Updater zwar durch, lehnt aber jede Signatur ab.
///
/// Die XPC-Dienste zum Herunterladen und Installieren liegen im Sparkle-Paket und werden über die
/// in `JellyDesk.entitlements` eingetragenen Mach-Namen angesprochen.
@MainActor
final class UpdaterService: NSObject, ObservableObject {
    static let shared = UpdaterService()

    @Published private(set) var canCheckForUpdates: Bool = true

    let controller: SPUStandardUpdaterController

    private var observer: NSKeyValueObservation?

    override init() {
        // `startingUpdater: true` prüft im Hintergrund nach dem in Info.plist eingestellten
        // Intervall; der Nutzer bekommt bei einem Fund Sparkles Standard-Dialog.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        observer = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// Vom Menüeintrag „Nach Updates suchen …“ ausgelöst: fragt Sparkle-Dialog ab.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
