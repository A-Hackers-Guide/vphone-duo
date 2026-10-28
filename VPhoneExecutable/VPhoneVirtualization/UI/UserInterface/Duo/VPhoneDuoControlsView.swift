import AppKit

// MARK: - Fold Controls

/// The bar under the phone: the fold slider with its exact angle, the
/// postures it is most often set to, the finish, and a view reset. It is
/// Liquid Glass where the system has it (macOS 26), and the HUD material
/// before that.
@MainActor
final class VPhoneDuoControlsView: NSView {
    var onAngle: ((Double, Bool) -> Void)?
    var onPreset: ((Double) -> Void)?
    var onFinish: ((VPhoneDuoView.Finish) -> Void)?
    var onResetView: (() -> Void)?

    private(set) var finish: VPhoneDuoView.Finish = VPhoneDuoControlsView.savedFinish

    private let slider = NSSlider(value: 180, minValue: 0, maxValue: 180, target: nil, action: nil)
    private let angleLabel = NSTextField(labelWithString: "180°")
    /// What the guest's sensor publishes, read back after each change.
    private let publishedLabel = NSTextField(labelWithString: "")
    private let presets = NSSegmentedControl(
        labels: ["Closed", "Tent", "Laptop", "Open"], trackingMode: .momentary, target: nil, action: nil,
    )
    private let finishControl = NSSegmentedControl(
        labels: ["White", "Black"], trackingMode: .selectOne, target: nil, action: nil,
    )

    static let presetAngles: [Double] = [0, 70, 110, 180]
    private static let finishKey = "VPhoneDuoFinish"

    private static var savedFinish: VPhoneDuoView.Finish {
        UserDefaults.standard.string(forKey: finishKey).flatMap(VPhoneDuoView.Finish.init(rawValue:)) ?? .white
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        let foldLabel = NSTextField(labelWithString: "Fold")
        foldLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        foldLabel.textColor = .secondaryLabelColor

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.controlSize = .small
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        slider.toolTip = "The hinge angle iOS is told: 0° closed, 180° open flat"

        angleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        angleLabel.alignment = .right
        angleLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        presets.target = self
        presets.action = #selector(presetChosen(_:))
        presets.controlSize = .small
        presets.segmentStyle = .rounded

        finishControl.target = self
        finishControl.action = #selector(finishChosen(_:))
        finishControl.controlSize = .small
        finishControl.selectedSegment = finish == .white ? 0 : 1

        let reset = NSButton(
            image: NSImage(systemSymbolName: "scope", accessibilityDescription: "Reset view")!,
            target: self, action: #selector(resetPressed),
        )
        reset.bezelStyle = .accessoryBarAction
        reset.isBordered = false
        reset.toolTip = "Face the lit screen"

        publishedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        publishedLabel.textColor = .secondaryLabelColor
        publishedLabel.toolTip = "The angle iOS's hinge sensor publishes, read back from the guest"
        publishedLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true

        // The keyboard belongs to the guest: a click on the bar must not take
        // focus from the VM view, or typing would move the slider instead.
        for control in [slider, presets, finishControl, reset] as [NSControl] {
            control.refusesFirstResponder = true
        }

        let stack = NSStackView(views: [foldLabel, slider, angleLabel, publishedLabel, presets, finishControl, reset])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: finishControl)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: presets)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: publishedLabel)

        let background = Self.makeBackground(holding: stack)
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Liquid Glass around the controls, or the HUD material before macOS 26.
    private static func makeBackground(holding content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.cornerCurve = .continuous
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `finish` without reporting it back.
    func setFinish(_ finish: VPhoneDuoView.Finish) {
        self.finish = finish
        finishControl.selectedSegment = finish == .white ? 0 : 1
        UserDefaults.standard.set(finish.rawValue, forKey: Self.finishKey)
    }

    /// Shows `angle` without reporting it back.
    func showAngle(_ angle: Double) {
        if abs(slider.doubleValue - angle) > 0.05 { slider.doubleValue = angle }
        angleLabel.stringValue = String(format: angle.rounded() == angle ? "%.0f°" : "%.1f°", angle)
    }

    /// Shows the angle the guest publishes; nil when it cannot be read.
    func showPublished(_ angle: Double?) {
        guard let angle else {
            publishedLabel.stringValue = ""
            return
        }
        publishedLabel.stringValue = "iOS " + String(format: angle.rounded() == angle ? "%.0f°" : "%.1f°", angle)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let final = NSApp.currentEvent?.type == .leftMouseUp
        onAngle?(sender.doubleValue, final)
    }

    @objc private func presetChosen(_ sender: NSSegmentedControl) {
        guard Self.presetAngles.indices.contains(sender.selectedSegment) else { return }
        onPreset?(Self.presetAngles[sender.selectedSegment])
    }

    @objc private func finishChosen(_ sender: NSSegmentedControl) {
        finish = sender.selectedSegment == 0 ? .white : .black
        UserDefaults.standard.set(finish.rawValue, forKey: Self.finishKey)
        onFinish?(finish)
    }

    @objc private func resetPressed() {
        onResetView?()
    }
}
