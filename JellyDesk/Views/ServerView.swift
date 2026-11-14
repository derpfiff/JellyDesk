import SwiftUI

/// Bereich „Server“: beim ersten Start die Adresse abfragen, danach die Weboberfläche zeigen.
struct ServerView: View {
    @EnvironmentObject private var web: WebViewModel
    @EnvironmentObject private var store: OfflineStore
    @AppStorage(SettingsKeys.serverURL) private var serverURL = ""
    /// Wechselt in den Bereich „Downloads“.
    var onShowDownloads: () -> Void = {}

    var body: some View {
        Group {
            if let url = URL(string: serverURL), url.isWebURL {
                ZStack {
                    WebView(model: web)
                    if let error = web.unreachable ?? web.loadError {
                        OfflineView(detail: error, downloadCount: store.items.filter { $0.state == .completed }.count,
                                    onRetry: { web.reload() }, onShowDownloads: onShowDownloads)
                    } else if !web.hasPage {
                        ConnectingView()
                    }
                }
                .onAppear { web.load(server: url) }
                .onChange(of: serverURL) { _, newValue in
                    if let newURL = URL(string: newValue), newURL.isWebURL { web.load(server: newURL) }
                }
            } else {
                ServerSetupView()
            }
        }
    }
}

/// Der Server ist nicht erreichbar: sagt, was los ist, und führt zu dem, was ohne Netz geht.
struct OfflineView: View {
    let detail: String
    let downloadCount: Int
    let onRetry: () -> Void
    let onShowDownloads: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 76, height: 76)
                .glass(Circle())
            Text("Du bist offline")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(downloadCount > 0
                 ? "Der Server ist gerade nicht erreichbar. \(downloadCount == 1 ? "Ein geladener Titel wartet" : "\(downloadCount) geladene Titel warten") in deinen Downloads."
                 : "Der Server ist gerade nicht erreichbar. Geladene Titel würdest du in deinen Downloads finden.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if downloadCount > 0 {
                    Button(action: onShowDownloads) { Label("Downloads öffnen", systemImage: "arrow.down.circle") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button(action: onRetry) { Label("Erneut versuchen", systemImage: "arrow.clockwise") }
                        .buttonStyle(GlassPillButtonStyle())
                } else {
                    Button(action: onRetry) { Label("Erneut versuchen", systemImage: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 2)
        }
        .padding(32)
        .frame(maxWidth: 440)
        .glass(RoundedRectangle(cornerRadius: 28))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ServerBackdrop())
    }
}

/// Bis die Seite des Servers da ist: derselbe Grund wie die Offline-Ansicht, damit ein
/// Wechsel dorthin nicht springt, und nie eine weiße Fläche.
struct ConnectingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ServerBackdrop())
    }
}

/// Weicher Farbschein hinter den eigenen Seiten des Bereichs „Server“.
struct ServerBackdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.blue.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.orange.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
        }
    }
}

/// Fragt die Server-Adresse ab und prüft sie gegen /System/Info/Public.
struct ServerSetupView: View {
    @AppStorage(SettingsKeys.serverURL) private var serverURL = ""
    @State private var input = ""
    @State private var checking = false
    @State private var message: String?
    @State private var unverified: URL?

    var body: some View {
        VStack(spacing: 14) {
            Text("Bitte verbinden")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Gib die Adresse ein, unter der du die Weboberfläche deines Jellyfin-Servers im Browser öffnest.")
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ServerAddressForm(input: $input, checking: $checking, message: $message, unverified: $unverified) { url in
                serverURL = url.absoluteString
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: 460)
        .glass(RoundedRectangle(cornerRadius: 28))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Weicher Farbschein wie hinter der Anmeldung des Themes.
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.blue.opacity(0.35), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color.orange.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            }
        )
    }
}

/// Eingabefeld mit Prüfung; wird beim ersten Start und in den Einstellungen benutzt.
struct ServerAddressForm: View {
    @Binding var input: String
    @Binding var checking: Bool
    @Binding var message: String?
    @Binding var unverified: URL?
    var buttonTitle = "Verbinden"
    let onAccept: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("https://jellyfin.example.com oder 192.168.1.10:8096", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(check)
                    .disabled(checking)
                Button(buttonTitle, action: check)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || ServerAddress.candidates(for: input).isEmpty)
            }
            if checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Server wird geprüft …").foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unverified {
                Button("Trotzdem \(unverified.absoluteString) verwenden") {
                    onAccept(unverified)
                    self.unverified = nil
                    message = nil
                }
            }
        }
    }

    private func check() {
        let candidates = ServerAddress.candidates(for: input)
        guard !candidates.isEmpty, !checking else { return }
        checking = true
        message = nil
        unverified = nil
        Task {
            let result = await ServerAddress.resolve(input, api: AppServices.shared.api)
            checking = false
            if let result {
                message = result.name.map { "Verbunden mit „\($0)“." }
                onAccept(result.url)
            } else {
                message = "Unter dieser Adresse antwortet kein Jellyfin-Server. Unverschlüsseltes HTTP erlaubt macOS der App nur für Adressen im Heimnetz (IP, .local, Name ohne Punkt)."
                unverified = candidates.first
            }
        }
    }
}
