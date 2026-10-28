import AppKit
import AVFoundation

// MARK: - Button Feedback

/// What a hardware button press feels and sounds like on the Mac: a short
/// synthesized click, a trackpad tick, and (in `VPhoneDuoModel`) the button
/// sinking into the frame. Each button has its own click: the volume rocker
/// is light and high, the side button deeper, Camera Control a soft tap.
@MainActor
final class VPhoneDuoFeedback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var clicks: [String: (down: AVAudioPCMBuffer, up: AVAudioPCMBuffer)] = [:]
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for button in VPhoneDuoModel.Button.allCases {
            let voice = Self.voice(for: button)
            clicks[button.rawValue] = (
                Self.click(format: format, pitch: voice.pitch, body: voice.body, level: voice.level),
                Self.click(format: format, pitch: voice.pitch * 1.18, body: voice.body * 0.7, level: voice.level * 0.55),
            )
        }
    }

    /// A press or a release of `button`.
    func play(_ button: VPhoneDuoModel.Button, down: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            down ? .levelChange : .generic, performanceTime: .now,
        )
        guard let pair = clicks[button.rawValue] else { return }
        if !started {
            do {
                try engine.start()
                started = true
            } catch {
                return
            }
        }
        player.scheduleBuffer(down ? pair.down : pair.up, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        engine.stop()
        started = false
    }

    private static func voice(for button: VPhoneDuoModel.Button) -> (pitch: Double, body: Double, level: Float) {
        switch button {
        case .volumeUp: (5200, 900, 0.32)
        case .volumeDown: (4800, 850, 0.32)
        case .side: (3600, 520, 0.40)
        case .cameraControl: (2400, 380, 0.22)
        }
    }

    /// A mechanical click: a sharp, quickly damped resonance (the dome) over
    /// a lower thump (the button body), about 25 ms long.
    private static func click(format: AVAudioFormat, pitch: Double, body: Double, level: Float) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.028)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var noise: UInt32 = 0x2545_F491
        for index in 0 ..< Int(frames) {
            let t = Double(index) / rate
            noise ^= noise << 13
            noise ^= noise >> 17
            noise ^= noise << 5
            let grit = (Double(noise) / Double(UInt32.max) - 0.5) * exp(-t * 1400)
            let dome = sin(2 * .pi * pitch * t) * exp(-t * 420)
            let thump = sin(2 * .pi * body * t) * exp(-t * 180)
            let attack = min(1, t * rate / 24)
            samples[index] = Float((dome * 0.55 + thump * 0.35 + grit * 0.6) * attack) * level
        }
        return buffer
    }
}
