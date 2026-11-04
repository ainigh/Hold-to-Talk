import AVFoundation
import Observation

/// Plays a recording's audio; the transcript follows along by its segments' times.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: UUID?
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var isPlaying: Bool { player?.isPlaying ?? false }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    /// Plays `url` as recording `id`, from `from` seconds in.
    func play(_ url: URL, id: UUID, from: TimeInterval? = nil) {
        if playing == id, let player {
            if let from { player.currentTime = from }
            player.play()
            tick()
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        if let from { p.currentTime = from }
        p.play()
        player = p
        playing = id
        duration = p.duration
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func pause() {
        player?.pause()
        tick()
    }

    func toggle(_ url: URL, id: UUID) {
        if playing == id, isPlaying { pause() } else { play(url, id: id) }
    }

    func seek(to t: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(t, player.duration))
        tick()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        playing = nil
        time = 0
        duration = 0
    }

    private func tick() {
        time = player?.currentTime ?? 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.stop() } }
    }
}
