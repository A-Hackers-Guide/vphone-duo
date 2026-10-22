import AppKit
import VPhoneCoreKit

// MARK: - HomePod Top Cap

/// The HomePod's light diffuser and capacitive controls. Every light comes
/// from the latest guest frame; this view has no autonomous animation clock.
@MainActor
final class VPhoneHomePodDisplayView: NSView {
    enum Control: Hashable {
        case volumeDown
        case volumeUp
        case surface
    }

    /// Paired transitions preserve a physical hold until pointer/key release.
    var onControlChange: ((Control, Bool, Duration) -> Void)?
    /// Enabled only when the caller has an evidenced guest touch mapping.
    var surfaceControlEnabled = false {
        didSet {
            surface.isHidden = !surfaceControlEnabled
            surface.setAccessibilityElement(surfaceControlEnabled)
            plus.nextKeyView = surfaceControlEnabled ? surface : minus
        }
    }
    private(set) var geometry: VPhoneHomePodDisplayGeometry?
    private(set) var displayFrame: VPhoneHomePodDisplayFrame?

    private let surface = VPhoneHomePodCapControl(control: .surface, label: "HomePod touch surface")
    private let minus = VPhoneHomePodCapControl(control: .volumeDown, label: "Decrease volume")
    private let plus = VPhoneHomePodCapControl(control: .volumeUp, label: "Increase volume")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        for button in [surface, minus, plus] {
            button.onChange = { [weak self] control, down, minimumHold in
                self?.onControlChange?(control, down, minimumHold)
            }
            addSubview(button)
        }
        surface.nextKeyView = minus
        minus.nextKeyView = plus
        plus.nextKeyView = minus
        surface.isHidden = true
        surface.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 360) }

    /// A geometry change invalidates the previous frame. Never retain old LED
    /// indices against a new device layout, or display a partial snapshot.
    func update(geometry: VPhoneHomePodDisplayGeometry, frame: VPhoneHomePodDisplayFrame) {
        guard frame.matches(geometry) else { return }
        guard self.geometry != geometry || displayFrame != frame else { return }
        self.geometry = geometry
        displayFrame = frame
        minus.illumination = frame.minusBrightness * frame.brightness
        plus.illumination = frame.plusBrightness * frame.brightness
        needsDisplay = true
    }

    func clearDisplay() {
        releaseControls()
        guard displayFrame != nil else { return }
        displayFrame = nil
        minus.illumination = 0
        plus.illumination = 0
        needsDisplay = true
    }

    func releaseControls() {
        for button in [surface, minus, plus] { button.releaseControl() }
    }

    func focusControls() {
        window?.makeFirstResponder(minus)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releaseControls()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowResignedKey(_ notification: Notification) { releaseControls() }

    private var capRect: CGRect {
        let diameter = max(0, min(bounds.width, bounds.height) - 32)
        return CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
    }

    override func layout() {
        super.layout()
        let cap = capRect
        surface.frame = cap
        let side = cap.width * 0.19
        minus.frame = CGRect(x: cap.midX - cap.width * 0.30 - side / 2, y: cap.midY - side / 2, width: side, height: side)
        plus.frame = CGRect(x: cap.midX + cap.width * 0.30 - side / 2, y: cap.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        dirtyRect.fill()
        let cap = capRect
        guard cap.width > 0 else { return }
        let path = NSBezierPath(ovalIn: cap)
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let geometry, let displayFrame, let context = NSGraphicsContext.current?.cgContext {
            // Add emitted light under the diffuser. Conversion from linear RGB
            // happens here, after multiplication by the guest's master level.
            context.setBlendMode(.screen)
            for (point, rgb) in zip(geometry.normalizedPoints, displayFrame.pixels) {
                let scaled = rgb.map { $0 * displayFrame.brightness }
                guard scaled.contains(where: { $0 > 0 }) else { continue }
                let center = CGPoint(x: cap.minX + point.x * cap.width, y: cap.minY + point.y * cap.height)
                let color = NSColor(srgbRed: Self.sRGB(scaled[0]), green: Self.sRGB(scaled[1]), blue: Self.sRGB(scaled[2]), alpha: 1)
                if let glow = NSGradient(colorsAndLocations: (color.withAlphaComponent(0.84), 0), (color.withAlphaComponent(0.32), 0.32), (color.withAlphaComponent(0), 1)) {
                    glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: cap.width * 0.24, options: [])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.20, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func sRGB(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}

// MARK: - Capacitive Hit Areas

/// The pointer's up event returns to its original view even after dragging
/// outside it. Keeping down/up separate also lets the guest recognize holds.
@MainActor
private final class VPhoneHomePodCapControl: NSButton {
    let control: VPhoneHomePodDisplayView.Control
    var onChange: ((VPhoneHomePodDisplayView.Control, Bool, Duration) -> Void)?
    var illumination: Double = 0 { didSet { needsDisplay = true } }
    private var isPressed = false

    init(control: VPhoneHomePodDisplayView.Control, label: String) {
        self.control = control
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activateControl)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(control == .surface ? "Click or hold to touch the HomePod top surface." : "Click or hold to change the HomePod volume.")
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }
    override var focusRingType: NSFocusRingType { get { .exterior } set {} }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = min(bounds.width, bounds.height) / 2
        guard hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressControl()
    }

    override func mouseUp(with event: NSEvent) { finishPress() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else if event.keyCode == 49 || event.keyCode == 36 { pressControl() }
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { finishPress() }
        else { super.keyUp(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        releaseControl()
        return super.resignFirstResponder()
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isPressed else { return false }
        activateControl()
        return true
    }

    @objc private func activateControl() {
        pressControl()
        finishPress()
    }

    private func finishPress() {
        // Give even instantaneous mouse/AX taps a usable consumer-key hold.
        // The queue measures this from the guest's key-down acknowledgement.
        releaseControl(minimumHold: .milliseconds(700))
    }

    private func pressControl() {
        guard !isPressed else { return }
        isPressed = true
        onChange?(control, true, .zero)
    }

    func releaseControl(minimumHold: Duration = .zero) {
        guard isPressed else { return }
        isPressed = false
        onChange?(control, false, minimumHold)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard control != .surface else { return }
        // The button LEDs are independent output channels, including off.
        let level = illumination <= 0.0031308 ? illumination * 12.92 : 1.055 * pow(illumination, 1 / 2.4) - 0.055
        NSColor(calibratedWhite: level, alpha: 1).setStroke()
        let path = NSBezierPath()
        let length = bounds.width * 0.40
        path.move(to: NSPoint(x: bounds.midX - length / 2, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.midX + length / 2, y: bounds.midY))
        if control == .volumeUp {
            path.move(to: NSPoint(x: bounds.midX, y: bounds.midY - length / 2))
            path.line(to: NSPoint(x: bounds.midX, y: bounds.midY + length / 2))
        }
        path.lineWidth = max(1.5, bounds.width * 0.035)
        path.lineCapStyle = .round
        path.stroke()
    }

    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}
