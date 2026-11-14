import AppKit
import AVFoundation
import AVKit

/// Zweiter Player nur für MP4/MOV, also die vom Server umgerechneten Downloads (H.264/AAC).
/// MKV, DTS, TrueHD und PGS kann AVFoundation nicht; dafür ist der mpv-Player da.
@MainActor
final class AVKitPlayerEngine: NSObject, PlayerEngine {
    let kind = PlayerEngineKind.avKit
    weak var delegate: PlayerEngineDelegate?

    private let playerView: AVPlayerView = {
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.controlsStyle = .none          // Bedienung kommt von der App
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        view.autoresizingMask = [.width, .height]
        return view
    }()
    var view: NSView { playerView }

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var fallbackDuration: TimeInterval = 0
    private var pendingStart: TimeInterval = 0
    private var wantsPlayback = false

    private(set) var position: TimeInterval = 0
    private var assetDuration: TimeInterval = 0
    var duration: TimeInterval { assetDuration > 0 ? assetDuration : fallbackDuration }
    private(set) var isPaused = true
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioTrackID: Int?
    private(set) var selectedSubtitleTrackID: Int?

    var volume: Double = 1 {
        didSet {
            volume = min(1, max(0, volume))
            player.volume = Float(volume)
        }
    }

    override init() {
        super.init()
        playerView.player = player
        player.allowsExternalPlayback = false
    }

    func load(url: URL, startAt: TimeInterval, fallbackDuration: TimeInterval) {
        self.fallbackDuration = fallbackDuration
        pendingStart = max(0, startAt)
        position = pendingStart

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        self.item = item

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.statusChanged(status, error: message) }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPaused = paused
                    self.delegate?.engineDidUpdateState(self)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = self.duration
                self.delegate?.engineDidReachEnd(self)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.position = time.seconds
                self.delegate?.engineDidUpdateTime(self)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func statusChanged(_ status: AVPlayerItem.Status, error: String?) {
        guard let item else { return }
        switch status {
        case .readyToPlay:
            // Fortlaufend erzeugte (fragmentierte) MP4 nennen nicht immer eine Dauer.
            let seconds = item.duration.seconds
            if item.duration.isNumeric, seconds.isFinite, seconds > 0 { assetDuration = seconds }
            Task { await finishLoading(item) }
        case .failed:
            delegate?.engine(self, didFailWith: error ?? "AVKit kann die Datei nicht abspielen.")
        default:
            break
        }
    }

    private func finishLoading(_ item: AVPlayerItem) async {
        let asset = item.asset
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard self.item === item else { return }

        audioTracks = (audioGroup?.options ?? []).enumerated().map { index, option in
            MediaTrack(id: index + 1, kind: .audio, title: option.displayName,
                       language: option.locale?.language.languageCode?.identifier)
        }
        subtitleTracks = (subtitleGroup?.options ?? []).enumerated().map { index, option in
            MediaTrack(id: index + 1, kind: .subtitle, title: option.displayName,
                       language: option.locale?.language.languageCode?.identifier,
                       isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        }
        refreshSelection()

        if pendingStart > 1 {
            await item.seek(to: CMTime(seconds: pendingStart, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard self.item === item else { return }
        delegate?.engineDidLoad(self)
        if wantsPlayback { player.play() }
    }

    private func refreshSelection() {
        guard let item else { return }
        let selection = item.currentMediaSelection
        if let group = audioGroup, let option = selection.selectedMediaOption(in: group),
           let index = group.options.firstIndex(of: option) {
            selectedAudioTrackID = index + 1
        } else {
            selectedAudioTrackID = nil
        }
        if let group = subtitleGroup, let option = selection.selectedMediaOption(in: group),
           let index = group.options.firstIndex(of: option) {
            selectedSubtitleTrackID = index + 1
        } else {
            selectedSubtitleTrackID = nil
        }
    }

    func play() {
        wantsPlayback = true
        if item?.status == .readyToPlay { player.play() }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    func selectAudioTrack(id: Int) {
        guard let group = audioGroup, group.options.indices.contains(id - 1) else { return }
        item?.select(group.options[id - 1], in: group)
        refreshSelection()
        delegate?.engineDidUpdateState(self)
    }

    func selectSubtitleTrack(id: Int?) {
        guard let group = subtitleGroup else { return }
        if let id, group.options.indices.contains(id - 1) {
            item?.select(group.options[id - 1], in: group)
        } else {
            item?.select(nil, in: group)
        }
        refreshSelection()
        delegate?.engineDidUpdateState(self)
    }

    func shutdown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        rateObservation = nil
        player.replaceCurrentItem(with: nil)
        item = nil
    }
}
