import SwiftUI

/// Bettet die Ansicht des jeweils aktiven Players ein und tauscht sie beim Wechsel aus.
private struct EngineHostView: NSViewRepresentable {
    let engine: PlayerEngine?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let wanted = engine?.view
        if container.subviews.first === wanted { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let wanted else { return }
        wanted.frame = container.bounds
        wanted.autoresizingMask = [.width, .height]
        container.addSubview(wanted)
    }
}

/// Inhalt des Player-Fensters für einen Download.
struct PlayerWindowView: View {
    let itemID: String?

    var body: some View {
        if let itemID {
            PlayerScreen(itemID: itemID, services: AppServices.shared)
                .id(itemID)
        } else {
            Text("Kein Titel gewählt.")
                .frame(minWidth: 480, minHeight: 270)
        }
    }
}

/// Die Bedienung ist dem Web-Player des Themes nachgebaut: unten links Titel und runde
/// Glas-Knöpfe, rechts Ton, Spuren und Vollbild, darunter der schmale Fortschrittsbalken mit
/// Zeit und Restzeit. Geschlossen wird über die Fensterknöpfe; ein eigenes X braucht es nicht.
private struct PlayerScreen: View {
    @StateObject private var model: PlayerViewModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    @State private var showAudioMenu = false
    @State private var showSubtitleMenu = false

    init(itemID: String, services: AppServices) {
        _model = StateObject(wrappedValue: PlayerViewModel(itemID: itemID, store: services.store, sync: services.sync, intros: services.intros,
                                                               api: services.api, streams: services.streams))
    }

    private var overlayVisible: Bool {
        controlsVisible || model.isPaused || showAudioMenu || showSubtitleMenu || scrubPosition != nil
    }

    var body: some View {
        ZStack {
            Color.black
            EngineHostView(engine: model.engine)

            if let error = model.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .light))
                    Text(error)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(32)
            } else if !model.isLoaded {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            // Fängt Klicks auf das Bild ab: Doppelklick schaltet Vollbild, Einfachklick Pause.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleFullscreen() }
                .onTapGesture { model.togglePause() }

            if overlayVisible {
                overlay
                    .transition(.opacity)
            }

            if model.isIntro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { model.skipIntro() } label: {
                            Label("Vorspann überspringen", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(GlassPillButtonStyle())
                        .help("Vorspann überspringen")
                    }
                    .padding(.trailing, 40)
                    .padding(.bottom, overlayVisible ? 190 : 44)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .ignoresSafeArea()
        .background(LiveFullscreen())
        .navigationTitle(model.windowTitle.isEmpty ? "Wiedergabe" : model.windowTitle)
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onAppear {
            model.start()
            showControls()
        }
        .onDisappear {
            hideTask?.cancel()
            model.close()
        }
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !model.isPaused, scrubPosition == nil, !showAudioMenu, !showSubtitleMenu else { return }
            withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Bedienung

    private var overlay: some View {
        ZStack {
            // Abdunklung oben und unten, damit Text und Knöpfe auf hellem Bild lesbar bleiben.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                if !model.subline.isEmpty {
                    Text(model.subline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Text(model.headline)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.bottom, 14)

                HStack(spacing: 12) {
                    Button { model.skip(-10) } label: { Label("10 Sekunden zurück", systemImage: "gobackward.10") }
                        .help("10 Sekunden zurück")
                    Button { model.togglePause() } label: {
                        Label(model.isPaused ? "Wiedergabe" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(model.isPaused ? "Wiedergabe" : "Pause")
                    Button { model.skip(10) } label: { Label("10 Sekunden vor", systemImage: "goforward.10") }
                        .help("10 Sekunden vor")

                    Spacer(minLength: 12)

                    Button { model.toggleMute() } label: {
                        Label("Ton", systemImage: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(model.volume == 0 ? "Ton an" : "Ton aus")
                    VolumeBar(value: $model.volume)
                        .frame(width: 84)
                        .padding(.trailing, 6)

                    Button { showAudioMenu.toggle() } label: { Label("Tonspur", systemImage: "waveform") }
                        .help("Tonspur")
                        .popover(isPresented: $showAudioMenu, arrowEdge: .top) { audioMenu }
                    Button { showSubtitleMenu.toggle() } label: { Label("Untertitel", systemImage: "captions.bubble") }
                        .help("Untertitel")
                        .popover(isPresented: $showSubtitleMenu, arrowEdge: .top) { subtitleMenu }
                    Button { model.toggleFullscreen() } label: {
                        Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Vollbild")
                }
                .buttonStyle(GlassCircleButtonStyle(size: 44))
                .padding(.bottom, 18)

                SeekBar(position: model.position, duration: model.duration, scrub: $scrubPosition,
                        trickplay: model.trickplay) { target in
                    model.seek(to: target)
                }
                .disabled(!model.isLoaded || model.duration <= 0)

                HStack {
                    Text(Format.time(scrubPosition ?? model.position))
                    Spacer()
                    Text("-" + Format.time(max(0, model.duration - (scrubPosition ?? model.position))))
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
        }
    }

    private var audioMenu: some View {
        TrackMenu(title: "Tonspur") {
            if model.audioTracks.isEmpty {
                TrackRow(text: "Keine Tonspuren", selected: false, action: nil)
            }
            ForEach(model.audioTracks) { track in
                TrackRow(text: track.displayName, selected: track.id == model.selectedAudioTrackID) {
                    model.selectAudio(track)
                    showAudioMenu = false
                }
            }
        }
    }

    private var subtitleMenu: some View {
        TrackMenu(title: "Untertitel") {
            TrackRow(text: "Aus", selected: model.selectedSubtitleTrackID == nil) {
                model.selectSubtitle(nil)
                showSubtitleMenu = false
            }
            ForEach(model.subtitleTracks) { track in
                TrackRow(text: track.displayName, selected: track.id == model.selectedSubtitleTrackID) {
                    model.selectSubtitle(track)
                    showSubtitleMenu = false
                }
            }
        }
    }
}

/// Dunkle Liste wie die Menüs des Themes.
private struct TrackMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content }
            }
            .frame(maxHeight: 320)
        }
        .padding(6)
        .frame(minWidth: 260, maxWidth: 380)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

private struct TrackRow: View {
    let text: String
    let selected: Bool
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(selected ? 1 : 0)
                Text(text)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(action == nil ? Theme.text3 : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(hovering && action != nil ? Color.white.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering = $0 }
        .accessibilityLabel(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Schmaler Fortschrittsbalken über die ganze Breite; beim Überfahren und Ziehen wird er dicker,
/// und über dem Zeiger erscheint die Zeit, mit Vorschaubild, wenn es für den Titel welche gibt.
private struct SeekBar: View {
    let position: Double
    let duration: Double
    @Binding var scrub: Double?
    let trickplay: TrickplayProvider?
    let onSeek: (Double) -> Void
    @State private var hovering = false
    /// Stelle unter dem Zeiger in Sekunden, solange er über dem Balken ist.
    @State private var hoverTime: Double?
    @State private var preview: CGImage?
    @Environment(\.isEnabled) private var isEnabled

    private static let previewWidth: CGFloat = 240

    var body: some View {
        GeometryReader { geometry in
            let current = scrub ?? position
            let fraction = duration > 0 ? min(1, max(0, current / duration)) : 0
            let pointed = scrub ?? hoverTime
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Color.white)
                    .frame(width: max(0, fraction * geometry.size.width))
            }
            .frame(height: hovering || scrub != nil ? 8 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, duration > 0 else { return }
                        scrub = min(1, max(0, value.location.x / geometry.size.width)) * duration
                    }
                    .onEnded { _ in
                        if let target = scrub { onSeek(target) }
                        scrub = nil
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovering = true
                    hoverTime = isEnabled && duration > 0 ? min(1, max(0, point.x / geometry.size.width)) * duration : nil
                case .ended:
                    hovering = false
                    hoverTime = nil
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let pointed, isEnabled, duration > 0 {
                    let width = trickplay == nil ? 64 : Self.previewWidth
                    let x = pointed / duration * geometry.size.width
                    bubble(time: pointed)
                        .frame(width: width)
                        .offset(x: min(max(0, x - width / 2), max(0, geometry.size.width - width)), y: -22)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            // Lädt beim Erscheinen und danach nur, wenn der Zeiger ein anderes Vorschaubild erreicht.
            .task(id: previewKey(for: pointed)) {
                guard let pointed, let trickplay else {
                    preview = nil
                    return
                }
                if let image = await trickplay.thumbnail(at: pointed), !Task.isCancelled { preview = image }
            }
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Format.time(scrub ?? position))
        .accessibilityAdjustableAction { direction in
            onSeek(max(0, min(duration, position + (direction == .increment ? 10 : -10))))
        }
    }

    /// Vorschaubild mit Zeit darunter; ohne Vorschaubilder nur die Zeit.
    private func bubble(time: Double) -> some View {
        VStack(spacing: 6) {
            if let trickplay {
                ZStack {
                    Color.black
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
                }
                .frame(width: Self.previewWidth, height: Self.previewWidth / trickplay.aspect)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            }
            Text(Format.time(time))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
        }
    }

    /// Welches Vorschaubild zu einer Stelle gehört; nil, wenn es keins gibt.
    private func previewKey(for time: Double?) -> String? {
        guard let time, let place = trickplay?.info.location(at: time) else { return nil }
        return "\(place.sheet)/\(Int(place.rect.minX))/\(Int(place.rect.minY))"
    }
}

/// Lautstärke als kurzer Balken im selben Stil.
private struct VolumeBar: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Color.white)
                    .frame(width: max(0, min(1, value) * geometry.size.width))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = min(1, max(0, drag.location.x / geometry.size.width))
                }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Lautstärke")
        .accessibilityValue("\(Int(value * 100)) Prozent")
        .accessibilityAdjustableAction { direction in
            value = min(1, max(0, value + (direction == .increment ? 0.1 : -0.1)))
        }
    }
}
