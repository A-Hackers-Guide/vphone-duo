import AppKit

// MARK: - Fold Controls

/// The bar under the phone: the fold slider with its exact angle, the
/// postures it is most often set to, the finish, and a view reset.
@MainActor
final class VPhoneDuoControlsView: NSVisualEffectView {
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
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

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

        let stack = NSStackView(views: [foldLabel, slider, angleLabel, publishedLabel, presets, finishControl, reset])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: finishControl)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: presets)
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: publishedLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
