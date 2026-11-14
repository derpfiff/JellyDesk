import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Die App ist durchgehend dunkel. Das gilt so auch für Fenster, die nicht von SwiftUI
        // stammen, etwa das Vollbildfenster der Web-Ansicht mit seiner Titelzeile.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        AppServices.shared.start()
    }

    /// Downloads laufen weiter, wenn das Fenster geschlossen ist.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Vor dem Beenden: Wiedergabestände sichern und laufende Originale mit
    /// Fortsetzungsdaten anhalten, damit sie beim nächsten Start weiterladen.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .jellyDeskWillTerminate, object: nil)
        let services = AppServices.shared
        services.store.saveNow()

        var replied = false
        func reply() {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await services.downloads.prepareForTermination()
            await services.streams.settle()
            reply()
        }
        // Nicht ewig warten, falls eine Verbindung hängt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            services.store.saveNow()
            reply()
        }
        return .terminateLater
    }
}

@main
struct JellyDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        Window("JellyDesk", id: "main") {
            RootView()
                .environmentObject(services.store)
                .environmentObject(services.downloads)
                .environmentObject(services.sync)
                .environmentObject(services.web)
                .environmentObject(services.notices)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        // Kein sichtbarer Fensterrahmen: die Weboberfläche reicht bis an die Oberkante.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button("Seite neu laden") { services.web.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Zwischenspeicher leeren und neu laden") { services.web.clearCacheAndReload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Zurück") { services.web.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Vorwärts") { services.web.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
        }

        WindowGroup("Wiedergabe", id: "player", for: String.self) { $itemID in
            PlayerWindowView(itemID: itemID)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 630)
        // Wie der Web-Player: Bild bis an den Rand, Bedienung liegt darüber.
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(services.store)
                .environmentObject(services.sync)
                .environmentObject(services.web)
                .environmentObject(services.intros)
                .preferredColorScheme(.dark)
                .tint(Theme.blue)
        }
    }
}
