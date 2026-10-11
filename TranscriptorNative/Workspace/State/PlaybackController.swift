import Foundation
import AVFoundation
import Combine

/// Audio of the open document. Separate from the documents so that the 20 Hz clock only
/// redraws the player bar and the active segment/word (spec 7.2, 7.5).
@MainActor
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1
    /// nil = no media; otherwise the file the player has loaded.
    @Published private(set) var mediaURL: URL?
    /// Expected path when the original audio is missing (tooltip «El audio original no está disponible»).
    @Published private(set) var missingMediaPath: String?

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: Any?
    private(set) var documentId: UUID?

    var hasMedia: Bool { mediaURL != nil }

    /// Loads the media of a document, paused at `position` (restoration never auto-plays, spec 4.5).
    func load(documentId: UUID, url: URL?, fallbackDuration: TimeInterval, position: TimeInterval = 0) {
        guard documentId != self.documentId || mediaURL != url else { return }
        unload()
        self.documentId = documentId
        duration = fallbackDuration
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            missingMediaPath = url.path
            return
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        mediaURL = url
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
        Task {
            if let d = try? await item.asset.load(.duration), CMTimeGetSeconds(d).isFinite, CMTimeGetSeconds(d) > 0 {
                self.duration = CMTimeGetSeconds(d)
            }
        }
        if position > 0 { seek(to: position) }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        mediaURL = nil
        missingMediaPath = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        documentId = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Moves without changing the play/pause state (spec 7.3).
    func seek(to time: TimeInterval) {
        let t = min(max(0, time), max(duration, 0))
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { player?.rate = newRate }
    }
}
