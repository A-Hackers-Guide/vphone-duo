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
    private var lastVelocity = 0.0
    private var settle: Task<Void, Never>?
    private var connectionWatch: Timer?
    private var wasConnected = false
    /// The hinge state SpringBoard's pose was last given, or nil when unknown.
    private var poseState: Int?
    /// Whether SpringBoard's pose follows the fold: only for a guest drawing
    /// for the inner panel. On the cover panel alone, a closed pose (state 1)
    /// has SpringBoard ignore touches, and the pose changes nothing it draws.
    var sendsPose = false
    /// The guest has the newest angle: nothing more is waiting to go.
    var onSettled: (() -> Void)?
    /// The angle the window shows, sent whenever the guest (re)connects: the
    /// guest keeps its last angle across reboots, the window starts open.
    var currentAngle: () -> Double = { 180 }

    /// Whether the guest display follows the lit panel's size. iOS lays out
    /// once per display mode, so a resize is only made where it is followed.
    static var resizesDisplay: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DUO_RESIZE"] == "1"
    }

    init(control: VPhoneGuestControl) {
        self.control = control
        connectionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchConnection() }
        }
    }

    func stop() {
        connectionWatch?.invalidate()
        connectionWatch = nil
        settle?.cancel()
    }

    /// Sends the window's angle each time the guest's agent comes up, and
    /// anything that waited while it was away.
    private func watchConnection() {
        let connected = control?.isConnected == true && control?.supportsHinge == true
        defer { wasConnected = connected }
        guard connected, !wasConnected else { return }
        last = nil
        poseState = nil
        if pending == nil { pending = currentAngle() }
        flush()
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
        lastVelocity = velocity
        settle?.cancel()
        Task {
            _ = try? await control.setHinge(VPhoneHingeConfiguration(enabled: true, angle: angle, velocity: velocity))
            await sendPose(for: angle, to: control)
            inFlight = false
            if pending == nil {
                onSettled?()
                settleVelocity(at: angle)
            }
            flush()
        }
    }

    /// SpringBoard reads no hinge sensor on a VM, so its pose is overridden
    /// through its test automation each time the fold crosses a hinge state.
    /// `VPHONE_DUO_POSE=0` leaves SpringBoard's pose alone.
    private func sendPose(for angle: Double, to control: VPhoneGuestControl) async {
        guard sendsPose, control.supportsPose, ProcessInfo.processInfo.environment["VPHONE_DUO_POSE"] != "0" else { return }
        let state = VPhoneGuestControl.poseHingeState(forAngle: angle)
        guard state != poseState else { return }
        do {
            try await control.setPose(hingeState: state)
            poseState = state
        } catch {
            print("[vphone] Duo pose not applied: \(error)")
        }
    }

    /// A fold that stops still has the speed of its last step; once nothing
    /// has moved for a moment, the guest is told the hinge is at rest.
    private func settleVelocity(at angle: Double) {
        guard lastVelocity != 0 else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, pending == nil, !inFlight,
                  let control, control.isConnected
            else { return }
            lastVelocity = 0
            _ = try? await control.setHinge(VPhoneHingeConfiguration(enabled: true, angle: angle, velocity: 0))
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
