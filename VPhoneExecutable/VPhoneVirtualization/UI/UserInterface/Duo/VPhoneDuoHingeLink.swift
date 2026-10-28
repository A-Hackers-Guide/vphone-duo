import Foundation

// MARK: - Hinge Link

/// Carries the Duo window's fold to the guest's hinge sensor.
///
/// A slider drag produces far more angles than the guest needs, so one
/// `motion.hinge.set` is in flight at a time and the newest angle waits
/// behind it; the last angle of a drag is always sent. The velocity is
/// measured between the angles actually sent, in degrees per second.
@MainActor
final class VPhoneDuoHingeLink {
    private weak var control: VPhoneGuestControl?
    private var pending: Double?
    private var inFlight = false
    private var last: (angle: Double, time: TimeInterval)?
    /// The guest has the newest angle: nothing more is waiting to go.
    var onSettled: (() -> Void)?

    /// Whether the guest display follows the lit panel's size. iOS lays out
    /// once per display mode, so a resize is only made where it is followed.
    static var resizesDisplay: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DUO_RESIZE"] == "1"
    }

    init(control: VPhoneGuestControl) {
        self.control = control
    }

    func send(_ angle: Double) {
        pending = angle
        flush()
    }

    private func flush() {
        guard !inFlight, let angle = pending, let control, control.isConnected, control.supportsHinge else { return }
        pending = nil
        inFlight = true
        let now = ProcessInfo.processInfo.systemUptime
        var velocity = 0.0
        if let last, now > last.time {
            velocity = min(max((angle - last.angle) / (now - last.time), -3600), 3600)
        }
        last = (angle, now)
        Task {
            _ = try? await control.setHinge(VPhoneHingeConfiguration(enabled: true, angle: angle, velocity: velocity))
            inFlight = false
            if pending == nil { onSettled?() }
            flush()
        }
    }

    /// The HID usage each button on the model presses in the guest.
    static func hidKey(for button: VPhoneDuoModel.Button) -> (page: UInt32, usage: UInt32) {
        switch button {
        case .volumeUp: (0x0C, 0xE9)
        case .volumeDown: (0x0C, 0xEA)
        case .side: (0x0C, 0x30)
        // Camera page, shutter: what Camera Control's full press sends.
        case .cameraControl: (0x90, 0x21)
        }
    }
}
