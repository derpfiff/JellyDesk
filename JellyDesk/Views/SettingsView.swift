import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: OfflineStore
    @EnvironmentObject private var sync: ProgressSyncService
    @EnvironmentObject private var intros: IntroLibrary
    @AppStorage(SettingsKeys.serverURL) private var serverURL = ""
    @AppStorage(SettingsKeys.defaultQuality) private var defaultQuality = "orig"
    @AppStorage(SettingsKeys.alwaysAsk) private var alwaysAsk = false
    @AppStorage(SettingsKeys.nativeStreaming) private var nativeStreaming = true
    @AppStorage(SettingsKeys.useAVKitForMP4) private var useAVKitForMP4 = true
    @AppStorage(SettingsKeys.playIntros) private var playIntros = true

    @State private var input = ""
    @State private var checking = false
    @State private var message: String?
    @State private var unverified: URL?

    private var usedSpace: Int64 {
        store.items.filter { $0.state == .completed }.reduce(0) { $0 + $1.fileSize }
    }

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Aktuelle Adresse", value: serverURL.isEmpty ? "nicht gesetzt" : serverURL)
                ServerAddressForm(input: $input, checking: $checking, message: $message,
                                  unverified: $unverified, buttonTitle: "Ändern") { url in
                    serverURL = url.absoluteString
                }
                Text("Anmeldung, Cookies und LocalStorage gehören zur jeweiligen Adresse und bleiben erhalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Zwischenspeicher leeren und neu laden") { AppServices.shared.web.clearCacheAndReload() }
                Text("Hilft, wenn auf dem Server ersetzte Bilder oder Symbole in der App noch alt aussehen. Die Anmeldung bleibt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Downloads") {
                Picker("Standardqualität", selection: $defaultQuality) {
                    ForEach(Quality.all, id: \.self) { key in
                        Text(Quality.label(key)).tag(key)
                    }
                }
                Toggle("Vor jedem Download nachfragen", isOn: $alwaysAsk)
                Text("Die Qualität wählst du in der Weboberfläche; die App lädt genau diese Fassung und ändert die Adresse nie. Die Standardqualität dient zur Anzeige und zum Filtern der Liste. Weicht ein Download davon ab, fragt die App vor dem Laden nach – mit dem Schalter bei jedem Download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Belegter Speicher", value: Format.bytes(usedSpace))
                Button("Ordner OfflineMedia im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.offlineMedia])
                }
            }

            Section("Wiedergabe") {
                Toggle("Titel vom Server im eigenen Player abspielen", isOn: $nativeStreaming)
                Text("Der Play-Knopf der Weboberfläche startet dann den Player der App: Die Datei kommt unverändert vom Server, auch mit DTS, TrueHD und Bild-Untertiteln. Ausgeschaltet spielt wie im Browser der Web-Player. Braucht Cinema Glass ab 1.3.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("MP4 und MOV mit AVKit abspielen", isOn: $useAVKitForMP4)
                Text("Alle anderen Formate (MKV, DTS, TrueHD, PGS, HDR) spielt immer der mpv-Player. Ausgeschaltet übernimmt mpv auch MP4 und MOV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Vorspann") {
                Toggle("Vorspann vor Downloads abspielen", isOn: $playIntros)
                Text("Es gelten die Einstellungen des Plugins „Local Intros“ auf dem Server. Die App liest sie bei jeder Verbindung neu, lädt alle dort erkannten Intros einmalig und wählt vor jedem Start nach derselben Regel wie das Plugin (nur vor Filmen oder auch vor Folgen, Standard-Intros, Tag, Genre, Studio, Datum). Gespielt wird nur beim Start von vorn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Stand von „Local Intros“") {
                Text(intros.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Abgleich des Wiedergabestands") {
                LabeledContent("Letzter Abgleich", value: sync.status)
                LabeledContent("Noch nicht gemeldet", value: "\(store.items.filter(\.needsSync).count) Titel")
                ForEach(sync.endpointReports.sorted(by: { $0.key < $1.key }), id: \.key) { server, report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pfadprüfung \(server)")
                            .font(.caption.weight(.semibold))
                        Text(report)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(sync.isSyncing ? "Abgleich läuft …" : "Jetzt abgleichen") {
                    Task { await sync.syncNow() }
                }
                .disabled(sync.isSyncing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 780)
        .onAppear { input = serverURL }
    }
}
