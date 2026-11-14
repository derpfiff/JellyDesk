import SwiftUI

/// Bereich „Downloads“: Filme und Serien (Staffel/Folge) mit Fortschritt und Bedienung,
/// gestaltet wie die Regale des Themes: schwarzer Grund, fette weiße Titel, Glas-Knöpfe.
struct DownloadsView: View {
    @EnvironmentObject private var store: OfflineStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var sync: ProgressSyncService
    @AppStorage(SettingsKeys.defaultQuality) private var defaultQuality = "orig"
    @Environment(\.openWindow) private var openWindow

    /// "" zeigt alle Qualitäten.
    @State private var qualityFilter = ""
    @State private var collapsed: Set<String> = []
    @State private var deleteCandidate: OfflineItem?

    private struct Season: Identifiable {
        let id: String
        let number: Int?
        let episodes: [OfflineItem]
        var title: String { number.map { $0 == 0 ? "Extras" : "Staffel \($0)" } ?? "Ohne Staffel" }
    }

    private struct Series: Identifiable {
        let id: String
        let name: String
        let seasons: [Season]
        var count: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    }

    private var visibleItems: [OfflineItem] {
        qualityFilter.isEmpty ? store.items : store.items.filter { $0.quality == qualityFilter }
    }

    private var movies: [OfflineItem] {
        visibleItems
            .filter { !$0.isEpisode }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var series: [Series] {
        let episodes = visibleItems.filter(\.isEpisode)
        let grouped = Dictionary(grouping: episodes) { $0.seriesName.isEmpty ? "Unbekannte Serie" : $0.seriesName }
        let result: [Series] = grouped.map { name, items in
            let bySeason = Dictionary(grouping: items) { $0.seasonNumber ?? -1 }
            let seasons: [Season] = bySeason.map { number, list in
                let sorted = list.sorted {
                    ($0.episodeNumber ?? Int.max, $0.title) < ($1.episodeNumber ?? Int.max, $1.title)
                }
                return Season(id: "\(name)#\(number)", number: number < 0 ? nil : number, episodes: sorted)
            }
            .sorted { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
            return Series(id: name, name: name, seasons: seasons)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filterOptions: [(key: String, label: String)] {
        [("", "Alle")] + Quality.all.map { ($0, Quality.label($0)) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    header
                    if store.items.isEmpty {
                        emptyState(
                            symbol: "arrow.down.circle",
                            title: "Noch keine Downloads",
                            text: "Öffne unter „Server“ einen Film, eine Folge, eine Staffel oder eine Serie und wähle dort den Download-Knopf."
                        )
                    } else if visibleItems.isEmpty {
                        emptyState(
                            symbol: "line.3.horizontal.decrease.circle",
                            title: "Keine Downloads in \(Quality.label(qualityFilter))",
                            text: "Der Qualitätsfilter blendet alle Einträge aus."
                        )
                    } else {
                        if !movies.isEmpty { moviesSection }
                        if !series.isEmpty { seriesSection }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 44)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(
            "„\(deleteCandidate?.displayTitle ?? "")“ löschen?",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            presenting: deleteCandidate
        ) { item in
            Button("Löschen", role: .destructive) {
                downloads.remove(item.id)
                deleteCandidate = nil
            }
            Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
        } message: { item in
            Text(item.needsSync
                 ? "Die Datei wird von der Festplatte entfernt. Der Wiedergabestand ist dem Server noch nicht gemeldet und geht dabei verloren."
                 : "Die Datei wird von der Festplatte entfernt.")
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Downloads")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 16)
            GlassSegmentedControl(options: filterOptions, selection: $qualityFilter)
                .help("Liste nach Qualität filtern (Standard: \(Quality.label(defaultQuality)))")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.offlineMedia])
            } label: {
                Label("Im Finder zeigen", systemImage: "folder")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .help("Ordner OfflineMedia im Finder zeigen")
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label("Abgleichen", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .disabled(sync.isSyncing)
            .help("Wiedergabestand jetzt abgleichen – \(sync.status)")
        }
    }

    private func emptyState(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(text)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: Abschnitte

    private func shelfTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Theme.text)
    }

    private var moviesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfTitle("Filme")
            rows(movies)
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            shelfTitle("Serien")
            ForEach(series) { show in
                VStack(alignment: .leading, spacing: 8) {
                    groupHeader(id: show.id, title: show.name, count: show.count, prominent: true)
                    if !collapsed.contains(show.id) {
                        ForEach(show.seasons) { season in
                            VStack(alignment: .leading, spacing: 4) {
                                groupHeader(id: season.id, title: season.title, count: season.episodes.count, prominent: false)
                                if !collapsed.contains(season.id) {
                                    rows(season.episodes)
                                }
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(id: String, title: String, count: Int, prominent: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .rotationEffect(.degrees(collapsed.contains(id) ? 0 : 90))
                Text(title)
                    .font(.system(size: prominent ? 18 : 14, weight: prominent ? .bold : .semibold))
                    .foregroundStyle(prominent ? Theme.text : Theme.text2)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func rows(_ items: [OfflineItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                DownloadRowView(
                    item: item,
                    progress: downloads.displayProgress(for: item),
                    deviatesFromDefault: item.quality != defaultQuality,
                    onPlay: { openWindow(id: "player", value: item.id) },
                    onRestart: {
                        store.resetPlayback(item.id)
                        openWindow(id: "player", value: item.id)
                    },
                    onPause: { downloads.pause(item.id) },
                    onResume: { downloads.resume(item.id) },
                    onReveal: { reveal(item) },
                    onDelete: { deleteCandidate = item }
                )
                if item.id != items.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }

    private func reveal(_ item: OfflineItem) {
        let fm = FileManager.default
        if fm.fileExists(atPath: item.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        } else {
            // Noch nicht fertig: den Zielordner zeigen, soweit er schon existiert.
            var dir = item.fileURL.deletingLastPathComponent()
            while !fm.fileExists(atPath: dir.path), dir.path.count > AppPaths.offlineMedia.path.count {
                dir = dir.deletingLastPathComponent()
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}

/// Eine Zeile der Download-Liste.
struct DownloadRowView: View {
    let item: OfflineItem
    let progress: DownloadManager.Progress?
    let deviatesFromDefault: Bool
    let onPlay: () -> Void
    let onRestart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            PosterView(url: item.posterURL, wide: item.isEpisode, watched: item.played, fraction: item.watchedFraction)

            VStack(alignment: .leading, spacing: 6) {
                Text(rowTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    OutlineBadge(text: Quality.label(item.quality), highlighted: deviatesFromDefault)
                        .help(deviatesFromDefault ? "Weicht von der Standardqualität ab" : "Standardqualität")
                    Text(detailLine)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                    if item.needsSync {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .help("Wiedergabestand ist dem Server noch nicht gemeldet")
                    }
                }
                if item.state != .completed {
                    ThinProgressBar(fraction: progress?.fraction ?? 0,
                                    color: item.state == .failed ? Theme.red : item.state == .paused ? Theme.text3 : Theme.text)
                        .frame(maxWidth: 420)
                        .padding(.top, 2)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(item.state == .failed ? Theme.red : Theme.text2)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                switch item.state {
                case .completed:
                    Button(action: onPlay) {
                        Label(item.positionTicks > 0 && !item.played ? "Fortsetzen" : "Abspielen", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("Abspielen")
                    if item.positionTicks > 0 || item.played {
                        Button(action: onRestart) { Label("Von vorn abspielen", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Von vorn abspielen (Wiedergabestand zurücksetzen)")
                    }
                case .queued, .downloading:
                    Button(action: onPause) {
                        Label(item.isOriginal ? "Pausieren" : "Abbrechen", systemImage: item.isOriginal ? "pause.fill" : "stop.fill")
                    }
                    .buttonStyle(GlassCircleButtonStyle())
                    .help(item.isOriginal ? "Pausieren" : "Abbrechen (umgerechnete Fassungen beginnen danach von vorn)")
                case .paused:
                    Button(action: onResume) {
                        Label(item.isOriginal ? "Fortsetzen" : "Von vorn laden", systemImage: "arrow.down")
                    }
                    .buttonStyle(GlassPillButtonStyle())
                    .help(item.isOriginal ? "Fortsetzen" : "Von vorn laden")
                case .failed:
                    Button(action: onResume) { Label("Erneut versuchen", systemImage: "arrow.clockwise") }
                        .buttonStyle(GlassPillButtonStyle())
                        .help("Erneut versuchen")
                }
                Button(action: onReveal) { Label("Im Finder zeigen", systemImage: "magnifyingglass") }
                    .buttonStyle(GlassCircleButtonStyle())
                    .help("Im Finder zeigen")
                Button(action: onDelete) { Label("Löschen", systemImage: "trash") }
                    .buttonStyle(GlassCircleButtonStyle())
                    .help("Löschen")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(hovering ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if item.state == .completed { onPlay() }
        }
        .contextMenu {
            if item.state == .completed {
                Button(item.positionTicks > 0 && !item.played ? "Fortsetzen" : "Abspielen", action: onPlay)
                if item.positionTicks > 0 || item.played { Button("Von vorn abspielen", action: onRestart) }
            }
            if item.isActive { Button(item.isOriginal ? "Pausieren" : "Abbrechen", action: onPause) }
            if item.state == .paused || item.state == .failed {
                Button(item.state == .failed ? "Erneut versuchen" : (item.isOriginal ? "Fortsetzen" : "Von vorn laden"),
                       action: onResume)
            }
            Button("Im Finder zeigen", action: onReveal)
            Divider()
            Button("Löschen", role: .destructive, action: onDelete)
        }
    }

    private var rowTitle: String {
        guard item.isEpisode else {
            return item.year.map { "\(item.title) (\($0))" } ?? item.title
        }
        return item.episodeNumber.map { "\($0). \(item.title)" } ?? item.title
    }

    /// Größe und Laufzeit.
    private var detailLine: String {
        var parts: [String] = []
        if item.state == .completed {
            parts.append(Format.bytes(item.fileSize))
        } else if let progress, progress.expected > 0 {
            parts.append((progress.isEstimate ? "ca. " : "") + Format.bytes(progress.expected))
        } else if item.estimatedBytes > 0 {
            parts.append("ca. " + Format.bytes(item.estimatedBytes))
        }
        if item.runTimeTicks > 0 {
            parts.append("\(Int((item.duration / 60).rounded())) Min.")
        }
        if item.state == .completed {
            if item.played {
                parts.append("gesehen")
            } else if item.positionTicks > 0 {
                parts.append("bei " + Format.time(Ticks.seconds(item.positionTicks)))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        let received = progress?.received ?? item.bytesReceived
        let percent = Int(((progress?.fraction ?? 0) * 100).rounded(.down))
        switch item.state {
        case .queued:
            return item.errorMessage ?? "Wartet in der Schlange"
        case .downloading:
            if let progress, progress.isEstimate {
                // Geschätzt: die Anzeige bleibt bei 100 % stehen, bis der Strom endet.
                return "\(Format.bytes(received)) geladen, etwa \(percent) % (Server rechnet um)"
            }
            return "\(Format.bytes(received)) geladen, \(percent) %"
        case .paused:
            return item.isOriginal
                ? "Pausiert bei \(percent) %"
                : "Abgebrochen. Umgerechnete Fassungen beginnen von vorn."
        case .failed:
            return item.errorMessage ?? "Fehlgeschlagen"
        case .completed:
            return ""
        }
    }
}

/// Schmaler Fortschrittsbalken wie unter dem „Fortsetzen“-Knopf des Themes.
struct ThinProgressBar: View {
    let fraction: Double
    var color: Color = Theme.text

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Fortschritt")
        .accessibilityValue("\(Int(fraction * 100)) Prozent")
    }
}

/// Bild aus dem Artwork-Ordner mit kleinem Zwischenspeicher: Poster im Hochformat,
/// Folgenbilder im Querformat.
struct PosterView: View {
    let url: URL?
    var wide = false
    let watched: Bool
    let fraction: Double

    private static let cache = NSCache<NSURL, NSImage>()

    private var image: NSImage? {
        guard let url else { return nil }
        if let cached = Self.cache.object(forKey: url as NSURL) { return cached }
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(loaded, forKey: url as NSURL)
        return loaded
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Theme.surface)
                    .overlay(Image(systemName: "film").foregroundStyle(Theme.text3))
            }
            if !watched, fraction > 0.01 {
                ThinProgressBar(fraction: fraction)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
            }
        }
        .frame(width: wide ? 124 : 58, height: wide ? 70 : 87)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if watched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, Theme.green)
                    .padding(4)
            }
        }
    }
}
