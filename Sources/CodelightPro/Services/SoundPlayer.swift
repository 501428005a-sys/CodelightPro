import AppKit

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var activeSounds: [NSSound] = []

    func playTaskStarted() {
        playSystemSound("Blow")
    }

    func playTaskFinished() {
        playSystemSound("Glass")
    }

    func playPaired() {
        playSystemSound("Hero")
    }

    func playNeedsApproval() {
        playSystemSound("Sosumi")
    }

    private func playSystemSound(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 1.0
        activeSounds.append(sound)
        sound.play()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            activeSounds.removeAll { !$0.isPlaying }
        }
    }
}
