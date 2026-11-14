import SwiftUI

enum SidebarItem: Hashable {
    case server, downloads
}

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var web: WebViewModel
    @EnvironmentObject private var notices: Notices
    @AppStorage(SettingsKeys.serverURL) private var serverURL = ""
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .server
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFullscreen = false
    /// Seitenleiste wurde für die Wiedergabe im Web-Player ausgeblendet und kommt danach zurück.
    @State private var hiddenForPlayback = false

    private var sidebarHidden: Bool { columnVisibility == .detailOnly }
    /// Läuft im Server-Bereich ein Video, verschwindet alles, was nicht zum Bild gehört.
    private var playbackMode: Bool { web.isVideoRoute && selection != .downloads }
    /// Ohne Seitenleiste bleibt über der Weboberfläche eine Kopfzeile für die Fensterknöpfe frei.
    private var headerStrip: Bool { sidebarHidden && !playbackMode && !hiddenForPlayback }
    /// Höhe der Titelzeile des Fensters; so hoch ist die Kopfzeile auch im Vollbild.
    private static let headerHeight: CGFloat = 32

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = sidebarHidden ? .all : .detailOnly
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Label("Server", systemImage: "play.tv")
                    .tag(SidebarItem.server)
                Label("Downloads", systemImage: "arrow.down.circle")
                    .badge(downloads.activeCount)
                    .tag(SidebarItem.downloads)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface.opacity(0.55))
            .safeAreaInset(edge: .bottom) {
                // Navigation der Web-Ansicht. Sie sitzt hier statt in einer Werkzeugleiste, damit
                // über der Weboberfläche kein Fensterrahmen liegt.
                HStack(spacing: 6) {
                    if selection != .downloads, !serverURL.isEmpty {
                        Button { web.goBack() } label: { Label("Zurück", systemImage: "chevron.left") }
                            .disabled(!web.canGoBack)
                            .help("Zurück")
                        Button { web.goForward() } label: { Label("Vorwärts", systemImage: "chevron.right") }
                            .disabled(!web.canGoForward)
                            .help("Vorwärts")
                        Button { web.goHome() } label: { Label("Startseite", systemImage: "house") }
                            .help("Startseite des Servers")
                        Button { web.reload() } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
                            .help("Neu laden")
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(GlassCircleButtonStyle(size: 28))
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            GeometryReader { geometry in
                ZStack {
                    Theme.background
                    // Die Web-Ansicht bleibt bestehen, während die Downloads gezeigt werden;
                    // sonst gingen Seitenzustand und laufende Wiedergabe verloren.
                    ServerView(onShowDownloads: { selection = .downloads })
                        .opacity(selection == .downloads ? 0 : 1)
                        .allowsHitTesting(selection != .downloads)
                    if selection == .downloads {
                        DownloadsView()
                    }
                }
                // Die Kopfzeile ergänzt, was die Titelzeile gerade nicht freihält. So ist sie in
                // jedem Augenblick gleich hoch, auch mitten im Wechsel zwischen Fenster und Vollbild.
                .padding(.top, headerStrip ? max(0, Self.headerHeight - geometry.safeAreaInsets.top) : 0)
            }
            // Mit Seitenleiste liegen die Fensterknöpfe über ihr, die Weboberfläche reicht bis an
            // die Oberkante. Ohne Seitenleiste lägen sie auf der Weboberfläche; dann bleibt im
            // Fenster eine schmale Kopfzeile frei. Im Vollbild bleibt sie in derselben Höhe
            // bestehen, obwohl es dort keine Titelzeile gibt: sonst rutschte die Seite beim
            // Wechsel um diese Höhe nach oben, und der Knopf für die Seitenleiste läge auf ihr.
            // Während der Wiedergabe gibt es keine Kopfzeile: das Bild reicht bis oben, damit
            // sich beim Wechsel ins Vollbild nichts verschiebt, und die Fensterknöpfe erscheinen
            // nur, wenn der Zeiger am oberen Rand ist.
            .ignoresSafeArea(.container, edges: headerStrip ? [] : .top)
            .background(Theme.background.ignoresSafeArea())
        }
        // Der Knopf für die Seitenleiste sitzt wie in anderen Mac-Apps oben neben den
        // Fensterknöpfen, bei ein- wie ausgeblendeter Leiste an derselben Stelle.
        .overlay(alignment: .topLeading) {
            ZStack {
            if !playbackMode {
                Button { toggleSidebar() } label: {
                    Label(sidebarHidden ? "Seitenleiste einblenden" : "Seitenleiste ausblenden", systemImage: "sidebar.left")
                }
                .buttonStyle(GlassCircleButtonStyle(size: 26))
                .help(sidebarHidden ? "Seitenleiste einblenden (⌃⌘S)" : "Seitenleiste ausblenden (⌃⌘S)")
                .padding(.leading, isFullscreen ? 14 : 80)
                .padding(.top, 3)
                .ignoresSafeArea()
                .transition(.opacity)
            }
            }
            // Nur der Knopf blendet weich; hinge die Animation am ganzen Fenster, liefe auch die
            // Größenänderung der Web-Ansicht animiert und damit Bild für Bild neu umbrochen.
            .animation(.easeInOut(duration: 0.2), value: playbackMode)
        }
        .onChange(of: playbackMode, initial: true) { _, playing in
            if playing {
                if !sidebarHidden {
                    hiddenForPlayback = true
                    withAnimation(.easeInOut(duration: 0.25)) { columnVisibility = .detailOnly }
                }
            } else if hiddenForPlayback {
                hiddenForPlayback = false
                withAnimation(.easeInOut(duration: 0.25)) { columnVisibility = .all }
            }
        }
        // Die Weboberfläche hat einen Titel an den eigenen Player übergeben.
        .onChange(of: web.playerToOpen) { _, key in
            guard let key else { return }
            openWindow(id: "player", value: key)
            web.playerOpened()
        }
        .onChange(of: columnVisibility) { _, value in
            // Holt man die Leiste während der Wiedergabe selbst zurück, bleibt sie danach, wie sie ist.
            if value != .detailOnly { hiddenForPlayback = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true { isFullscreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true { isFullscreen = false }
        }
        // Leiste ohne Titel, Knöpfe und Hintergrund: es bleiben nur die Fensterknöpfe.
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .tint(Theme.blue)
        // Leiste dauerhaft aus: gleiches Layout im Fenster und im Vollbild, kein Umbau beim Wechsel.
        .background(HiddenWindowToolbar())
        .background(WindowButtonsOnHover(active: playbackMode))
        // Vollbild-Wechsel mit laufendem Inhalt statt eingefrorenem Standbild (siehe LiveFullscreen).
        .background(LiveFullscreen(live: playbackMode))
        .overlay(alignment: .bottom) {
            if let notice = notices.current {
                Text(notice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glass(Capsule(), strong: true)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notices.current)
        .sheet(isPresented: Binding(
            get: { !downloads.pendingConfirmation.isEmpty },
            set: { if !$0 { downloads.discardPending() } }
        )) {
            ConfirmDownloadsSheet()
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
        }
    }
}

/// Rückfrage vor dem Laden: bei „immer nachfragen“ oder wenn die in der Weboberfläche
/// gewählte Qualität von der Standardqualität abweicht. Geladen wird stets die übergebene Adresse.
private struct ConfirmDownloadsSheet: View {
    @EnvironmentObject private var downloads: DownloadManager
    @AppStorage(SettingsKeys.defaultQuality) private var defaultQuality = "orig"

    var body: some View {
        let requests = downloads.pendingConfirmation
        let total = requests.reduce(Int64(0)) { $0 + $1.estimatedBytes }

        VStack(alignment: .leading, spacing: 16) {
            Text(requests.count == 1 ? "Diesen Titel laden?" : "\(requests.count) Titel laden?")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Standardqualität: \(Quality.label(defaultQuality)). Geladen wird die Fassung, die in der Weboberfläche gewählt wurde.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(requests) { request in
                        HStack(spacing: 10) {
                            Text(request.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            OutlineBadge(text: Quality.label(request.quality), highlighted: request.quality != defaultQuality)
                            Text((request.isOriginal ? "" : "ca. ") + Format.bytes(request.estimatedBytes))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text2)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 260)

            HStack(spacing: 10) {
                Text("Zusammen etwa \(Format.bytes(total))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                Spacer()
                Button("Verwerfen", role: .cancel) { downloads.discardPending() }
                    .buttonStyle(GlassPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Laden") { downloads.confirmPending() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.surface)
    }
}
