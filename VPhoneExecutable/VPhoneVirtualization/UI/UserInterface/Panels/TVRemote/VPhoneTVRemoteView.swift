import AppKit

// MARK: - Remote Face

/// Native buttons provide hit testing and AX activation above the remote face.
/// Holds are real down/up transitions; changing focus or connection releases all.
@MainActor
final class VPhoneTVRemoteView: NSView {
    static let preferredSize = NSSize(width: 280, height: 680)
    var onEvent: ((VPhoneTVRemoteEvent) -> Void)?
    var enabled = false {
        didSet {
            if !enabled { releaseControls() }
            for button in buttons.values { button.isEnabled = enabled }
            status.stringValue = enabled ? "" : String(localized: "Guest Not Connected", bundle: VPhoneLocalization.bundle)
            needsDisplay = true
        }
    }

    private(set) var buttons: [VPhoneTVRemoteControl: VPhoneTVRemoteButton] = [:]
    private var sources: [VPhoneTVRemoteControl: Set<String>] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: String(
        localized: "Click or hold. Arrow keys navigate.\nReturn selects. Esc goes back.",
        bundle: VPhoneLocalization.bundle,
    ))

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        for control in VPhoneTVRemoteControl.allCases {
            let button = VPhoneTVRemoteButton(control: control)
            button.remote = self
            buttons[control] = button
            addSubview(button)
        }
        for label in [status, hint] {
            label.alignment = .center
            label.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            addSubview(label)
        }
        let order: [VPhoneTVRemoteControl] = [
            .power, .up, .left, .select, .right, .down, .back, .tv,
            .playPause, .mute, .volumeUp, .volumeDown, .siri,
        ]
        for (index, control) in order.enumerated() {
            buttons[control]?.nextKeyView = buttons[order[(index + 1) % order.count]]
        }
        enabled = false
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { Self.preferredSize }

    private var scale: CGFloat { min(bounds.width / 280, bounds.height / 680) }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: bounds.midX + (x - 140) * scale, y: bounds.midY + (y - 340) * scale,
               width: width * scale, height: height * scale)
    }

    override func layout() {
        super.layout()
        let pad = rect(77, 82, 126, 126)
        for control in [VPhoneTVRemoteControl.up, .down, .left, .right] {
            buttons[control]?.frame = pad
        }
        buttons[.select]?.frame = rect(108, 113, 64, 64)
        buttons[.power]?.frame = rect(182, 38, 23, 23)
        buttons[.back]?.frame = rect(83, 237, 46, 46)
        buttons[.tv]?.frame = rect(151, 237, 46, 46)
        buttons[.playPause]?.frame = rect(83, 303, 46, 46)
        buttons[.mute]?.frame = rect(83, 369, 46, 46)
        buttons[.volumeUp]?.frame = rect(151, 303, 46, 56)
        buttons[.volumeDown]?.frame = rect(151, 359, 46, 56)
        buttons[.siri]?.frame = rect(216, 223, 15, 70)
        status.frame = rect(16, 620, 248, 18)
        hint.frame = rect(16, 642, 248, 32)
        for label in [status, hint] { label.font = .monospacedSystemFont(ofSize: 11 * scale, weight: .regular) }
        for button in buttons.values { button.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()
        let body = NSBezierPath(roundedRect: rect(64, 20, 152, 590), xRadius: 28 * scale, yRadius: 28 * scale)
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        body.fill()
        NSColor(calibratedWhite: 0.56, alpha: 1).setStroke()
        body.lineWidth = scale
        body.stroke()
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect(138, 45, 4, 4)).fill()
        // The volume rocker is one capsule, with independent upper/lower hits.
        NSBezierPath(roundedRect: rect(151, 303, 46, 112), xRadius: 23 * scale, yRadius: 23 * scale).fill()
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect(132, 597, 16, 3), xRadius: scale, yRadius: scale).fill()
    }

    func change(_ control: VPhoneTVRemoteControl, source: String, down: Bool) {
        guard enabled || !down else { return }
        var held = sources[control] ?? []
        let wasPressed = !held.isEmpty
        if down { held.insert(source) } else { held.remove(source) }
        sources[control] = held.isEmpty ? nil : held
        let pressed = !held.isEmpty
        guard pressed != wasPressed else { return }
        buttons[control]?.pressed = pressed
        onEvent?(.init(control: control, down: pressed))
    }

    func releaseControls() {
        for control in VPhoneTVRemoteControl.allCases where sources[control]?.isEmpty == false {
            sources[control] = nil
            buttons[control]?.pressed = false
            onEvent?(.init(control: control, down: false))
        }
    }

    func showError(_ error: Error) {
        status.stringValue = error.localizedDescription
        status.toolTip = error.localizedDescription
    }

    func handleKey(_ event: NSEvent, down: Bool) -> Bool {
        guard let control = VPhoneTVRemoteControl.keyboard(event.keyCode) else { return false }
        let source = "key-\(event.keyCode)"
        if down {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        } else {
            // A modifier pressed after key-down must not strand the release.
            guard sources[control]?.contains(source) == true else { return false }
        }
        change(control, source: source, down: down)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event, down: true) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !handleKey(event, down: false) { super.keyUp(with: event) }
    }
}

// MARK: - Physical Button

@MainActor
final class VPhoneTVRemoteButton: NSButton {
    let control: VPhoneTVRemoteControl
    weak var remote: VPhoneTVRemoteView?
    var pressed = false { didSet { needsDisplay = true } }

    init(control: VPhoneTVRemoteControl) {
        self.control = control
        super.init(frame: .zero)
        title = ""
        // Each rocker half draws the shared capsule; bound its pressed fill.
        clipsToBounds = true
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let label = String(localized: control.label, bundle: VPhoneLocalization.bundle)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("tv-remote-\(control.rawValue)")
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    private var angle: CGFloat? {
        switch control {
        case .up: -.pi / 2
        case .down: .pi / 2
        case .left: .pi
        case .right: 0
        default: nil
        }
    }

    private var shape: NSBezierPath {
        if let angle {
            let path = NSBezierPath()
            let radius = bounds.width / 2
            for (index, step) in (0...24).enumerated() {
                let a = angle - .pi / 4 + CGFloat(step) / 24 * .pi / 2
                let point = NSPoint(x: bounds.midX + cos(a) * radius, y: bounds.midY + sin(a) * radius)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            for step in (0...24).reversed() {
                let a = angle - .pi / 4 + CGFloat(step) / 24 * .pi / 2
                path.line(to: NSPoint(x: bounds.midX + cos(a) * radius * 0.51, y: bounds.midY + sin(a) * radius * 0.51))
            }
            path.close()
            return path
        }
        if control == .volumeUp || control == .volumeDown {
            let rocker = NSRect(x: 1, y: control == .volumeUp ? 1 : -bounds.height + 1,
                                width: bounds.width - 2, height: bounds.height * 2 - 2)
            return NSBezierPath(roundedRect: rocker, xRadius: bounds.width / 2, yRadius: bounds.width / 2)
        }
        return NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                            xRadius: min(bounds.width, bounds.height) / 2,
                            yRadius: min(bounds.width, bounds.height) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shape.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        remote?.change(control, source: "pointer", down: true)
    }

    override func mouseUp(with event: NSEvent) {
        remote?.change(control, source: "pointer", down: false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else if event.keyCode == 49 {
            remote?.change(control, source: "button-space", down: true)
        } else if remote?.handleKey(event, down: true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { remote?.change(control, source: "button-space", down: false) }
        else if remote?.handleKey(event, down: false) != true { super.keyUp(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        remote?.change(control, source: "pointer", down: false)
        remote?.change(control, source: "button-space", down: false)
        return super.resignFirstResponder()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    @objc private func activate() {
        remote?.change(control, source: "activation", down: true)
        remote?.change(control, source: "activation", down: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = shape
        if control != .volumeUp && control != .volumeDown || pressed {
            NSColor(calibratedWhite: pressed ? 0.34 : 0.13, alpha: 1).setFill()
            path.fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        if control == .select { return }
        let pointSize = min(bounds.width, bounds.height) * (control == .siri ? 0.75 : angle == nil ? 0.42 : 0.11)
        let color = NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.35)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        var center = NSPoint(x: bounds.midX, y: bounds.midY)
        if let angle {
            center.x += cos(angle) * bounds.width * 0.39
            center.y += sin(angle) * bounds.height * 0.39
        }
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height))
    }
}
