import AppKit

/// Loops a system alert sound while a call rings. Stops immediately on accept/decline/cancel.
@MainActor
final class Ringtone {
    static let available: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let sounds = names.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        return sounds.isEmpty ? ["Submarine"] : sounds
    }()

    private var sound: NSSound?
    private var repeatTask: Task<Void, Never>?

    var isPlaying: Bool { repeatTask != nil }

    func start(name: String, volume: Double) {
        stop()
        guard let sound = NSSound(named: NSSound.Name(name)) ?? NSSound(named: "Submarine") else { return }
        sound.volume = Float(volume)
        self.sound = sound
        // Ring pattern: tone, short pause, repeat.
        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sound?.stop()
                self?.sound?.play()
                try? await Task.sleep(for: .milliseconds(1600))
            }
        }
    }

    func preview(name: String, volume: Double) {
        let s = NSSound(named: NSSound.Name(name))
        s?.volume = Float(volume)
        s?.play()
    }

    func stop() {
        repeatTask?.cancel()
        repeatTask = nil
        sound?.stop()
        sound = nil
    }
}
