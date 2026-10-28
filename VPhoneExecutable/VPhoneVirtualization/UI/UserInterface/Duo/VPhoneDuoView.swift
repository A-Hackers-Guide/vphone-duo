import AppKit
import RealityKit

// MARK: - iPhone Duo Window Content

/// The iPhone Duo window: the phone as a 3D model in a studio, its panels
/// showing the guest live, under a fold slider.
///
/// Everything on the model is hit-tested from wherever it is seen: a click on
/// a lit panel is a touch at that point of the guest's screen, a click on a
/// button presses that button (with its click, a trackpad tick, and the key
/// sinking into the frame), and a drag anywhere else turns the phone.
///
/// The VM view stays in the window, hidden, so touches, the keyboard and host
/// automation keep their usual routes through it.
@MainActor
final class VPhoneDuoView: NSView {
    enum Finish: String, CaseIterable {
        case white, black
    }

    var finish: Finish { controls.finish }

    /// The hinge angle the guest is told, in degrees: 0 closed, 180 open flat.
    var onHingeChange: ((Double) -> Void)?
    /// A button went down (true) or up (false).
    var onButton: ((VPhoneDuoModel.Button, Bool) -> Void)?
    /// The lit panel changed; the guest display should take its size.
    var onActivePanelChange: ((VPhoneDuoModel.Panel) -> Void)?
    /// The angle iOS's hinge sensor publishes now, or nil when it cannot be read.
    var readPublishedAngle: (() async -> Double?)?
    private var readback: Task<Void, Never>?

    weak var virtualMachineView: VPhoneVirtualMachineView?
    /// The guest display's size in pixels, known before its first frame.
    var guestScreenSize: CGSize = .zero
    /// Where the lit panel's frames come from.
    var frameSource: VPhoneDuoFrameSource? {
        didSet { stream?.frameSource = frameSource }
    }

    private let arView = ARView(frame: .zero)
    private let overlay = VPhoneDuoEventView()
    private let controls = VPhoneDuoControlsView()
    private let feedback = VPhoneDuoFeedback()
    private let anchor = AnchorEntity(world: .zero)
    private let pivot = Entity()
    private let camera = PerspectiveCamera()
    private(set) var model: VPhoneDuoModel?
    private(set) var stream: VPhoneDuoPanelStream?

    // Camera orbit, in radians and metres.
    private var yaw: Float = -0.38
    private var pitch: Float = 0.16
    private var distance: Float = 0.36
    private var orbitGoal = SIMD3<Float>(-0.38, 0.16, 0.36)
    private var orbitLink: CADisplayLink?

    private(set) var hingeAngle: Double = 180
    private(set) var activePanel: VPhoneDuoModel.Panel = .inner
    private var pressed: VPhoneDuoModel.Button?
    private var touching: VPhoneDuoModel.Panel?
    private var dragStart: NSPoint?
    private var hingeAnimation: (from: Double, to: Double, start: CFTimeInterval)?

    /// Panels switch with some hysteresis, as SpringBoard does: the outer
    /// panel lights once the phone is nearly shut, the inner once it is
    /// opened well past a tent.
    static let innerOnAbove: Double = 95
    static let outerOnBelow: Double = 60

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        arView.environment.background = .color(Self.backdrop(for: controls.finish))
        arView.autoresizingMask = [.width, .height]
        addSubview(arView)

        overlay.autoresizingMask = [.width, .height]
        overlay.owner = self
        overlay.registerForDraggedTypes([.fileURL])
        addSubview(overlay)

        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            controls.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        controls.onAngle = { [weak self] angle, final in self?.setHinge(angle, fromUser: true, final: final) }
        controls.onPreset = { [weak self] angle in self?.animateHinge(to: angle) }
        controls.onFinish = { [weak self] finish in self?.applyFinish(finish) }
        controls.onResetView = { [weak self] in self?.resetView() }

        camera.camera.fieldOfViewInDegrees = 30
        camera.camera.near = 0.01
        camera.camera.far = 10
        anchor.addChild(pivot)
        anchor.addChild(camera)
        arView.scene.addAnchor(anchor)
        addLights()
        applyOrbit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        arView.frame = bounds
        overlay.frame = bounds
    }

    // MARK: - Loading

    /// Loads the model and the studio lighting from `resources`
    /// (VPhone.bundle/Contents/Resources/DuoModel).
    func load(resources: URL) async {
        if let lighting = await Self.studioLighting(resources.appendingPathComponent("DuoStudio.exr")) {
            arView.environment.lighting.resource = lighting
            arView.environment.lighting.intensityExponent = 0.35
        }
        do {
            let model = try await VPhoneDuoModel.load(from: resources.appendingPathComponent("DuoModel.usdz"))
            pivot.addChild(model.root)
            self.model = model
            model.setFinish(controls.finish)
            model.expectFrames(of: guestScreenSize)
            model.setHinge(hingeAngle)
            recenter()
            resetView(animated: false)
            let stream = VPhoneDuoPanelStream(model: model)
            stream.frameSource = frameSource
            stream.activePanel = activePanel
            stream.start()
            self.stream = stream
        } catch {
            print("[vphone] Duo model failed to load: \(error)")
        }
    }

    func stop() {
        stream?.stop()
        feedback.stop()
        orbitLink?.invalidate()
        orbitLink = nil
    }

    private static func studioLighting(_ url: URL) async -> EnvironmentResource? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return try? await EnvironmentResource(equirectangular: image, withName: "DuoStudio")
    }

    private func addLights() {
        // A soft key from above left for the specular line along the frame,
        // and a dim rim from behind so the edges read against the backdrop.
        let key = DirectionalLight()
        key.light.intensity = 2200
        key.light.color = NSColor(calibratedRed: 1, green: 0.98, blue: 0.95, alpha: 1)
        key.look(at: .zero, from: [-0.6, 0.9, 0.8], relativeTo: nil)
        anchor.addChild(key)
        let rim = DirectionalLight()
        rim.light.intensity = 900
        rim.look(at: .zero, from: [0.7, 0.3, -0.9], relativeTo: nil)
        anchor.addChild(rim)
    }

    // MARK: - Hinge

    /// Moves the hinge to `angle` and tells the guest. A slider drag reports
    /// every step, so the guest sees the fold move, not just where it ends.
    func setHinge(_ angle: Double, fromUser: Bool = false, final: Bool = true) {
        if fromUser { hingeAnimation = nil }
        let clamped = min(max(angle, 0), 180)
        hingeAngle = clamped
        model?.setHinge(clamped)
        recenter()
        controls.showAngle(clamped)
        onHingeChange?(clamped)
        updateActivePanel()
        if final { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// Asks the guest what its sensor publishes, once the last angle sent
    /// has arrived, so the bar shows what iOS reads beside what was set.
    func hingeDelivered() {
        readback?.cancel()
        guard let readPublishedAngle else { return }
        readback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let published = await readPublishedAngle()
            guard !Task.isCancelled else { return }
            self?.controls.showPublished(published)
        }
    }

    /// Eases the hinge to `angle` over about half a second.
    func animateHinge(to angle: Double) {
        hingeAnimation = (hingeAngle, angle, CACurrentMediaTime())
        startLink()
    }

    private func updateActivePanel() {
        let next: VPhoneDuoModel.Panel = switch activePanel {
        case .inner: hingeAngle < Self.outerOnBelow ? .outer : .inner
        case .outer: hingeAngle > Self.innerOnAbove ? .inner : .outer
        }
        guard next != activePanel else { return }
        activePanel = next
        stream?.activePanel = next
        onActivePanelChange?(next)
    }

    func setFinish(_ finish: Finish) {
        controls.setFinish(finish)
        applyFinish(finish)
    }

    private func applyFinish(_ finish: Finish) {
        model?.setFinish(finish)
        arView.environment.background = .color(Self.backdrop(for: finish))
    }

    /// Near black behind Star White; a lifted graphite behind Space Black,
    /// so its dark edges still read.
    private static func backdrop(for finish: Finish) -> NSColor {
        finish == .white ? NSColor(srgbRed: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    }

    /// Presses and releases `button` as a click on the model would.
    func pressButton(_ button: VPhoneDuoModel.Button, holdMilliseconds: Int) async {
        press(button, down: true)
        try? await Task.sleep(for: .milliseconds(holdMilliseconds))
        press(button, down: false)
    }

    /// Keeps the phone, however folded, centred under the camera.
    private func recenter() {
        guard let model else { return }
        let bounds = model.bounds(relativeTo: pivot)
        model.root.position -= bounds.center
    }

    // MARK: - Camera

    private func applyOrbit() {
        let position = SIMD3<Float>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw),
        )
        camera.look(at: .zero, from: position, relativeTo: nil)
    }

    /// Turns the view to face the lit panel, a little from the side.
    func resetView(animated: Bool = true) {
        var facing: Float = 0
        if let normal = model?.facing(activePanel, relativeTo: nil) {
            facing = atan2(normal.x, normal.z)
        }
        // Take the nearer way round.
        var goal = facing - 0.38
        while goal - yaw > .pi { goal -= 2 * .pi }
        while goal - yaw < -.pi { goal += 2 * .pi }
        orbitGoal = SIMD3(goal, 0.16, 0.36)
        if animated {
            startLink()
        } else {
            (yaw, pitch, distance) = (orbitGoal.x, orbitGoal.y, orbitGoal.z)
            applyOrbit()
        }
    }

    /// Turns the view to `yaw` and `pitch` at once, for previews and tests.
    func debugOrbit(yaw: Float, pitch: Float) {
        orbitGoal = SIMD3(yaw, pitch, distance)
        (self.yaw, self.pitch) = (yaw, pitch)
        applyOrbit()
    }

    fileprivate func orbit(by delta: NSPoint) {
        orbitGoal.x -= Float(delta.x) * 0.008
        orbitGoal.y = min(max(orbitGoal.y + Float(delta.y) * 0.008, -1.4), 1.4)
        yaw = orbitGoal.x
        pitch = orbitGoal.y
        applyOrbit()
    }

    fileprivate func zoom(by factor: CGFloat) {
        orbitGoal.z = min(max(orbitGoal.z * Float(factor), 0.16), 0.9)
        distance = orbitGoal.z
        applyOrbit()
    }

    private func startLink() {
        guard orbitLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        orbitLink = link
    }

    @objc private func step(_: CADisplayLink) {
        var moving = false
        // The view eases toward its goal.
        let current = SIMD3(yaw, pitch, distance)
        let next = current + (orbitGoal - current) * 0.18
        if simd_length(orbitGoal - current) > 0.0005 {
            (yaw, pitch, distance) = (next.x, next.y, next.z)
            moving = true
        } else {
            (yaw, pitch, distance) = (orbitGoal.x, orbitGoal.y, orbitGoal.z)
        }
        applyOrbit()
        if let animation = hingeAnimation {
            let t = min(1, (CACurrentMediaTime() - animation.start) / 0.55)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            setHinge(animation.from + (animation.to - animation.from) * eased, final: t >= 1)
            if t >= 1 { hingeAnimation = nil } else { moving = true }
        }
        if !moving {
            orbitLink?.invalidate()
            orbitLink = nil
        }
    }

    // MARK: - Pointer

    private func target(at point: NSPoint) -> VPhoneDuoModel.Target? {
        guard let model else { return nil }
        let viewPoint = arView.convert(point, from: overlay)
        guard let hit = arView.hitTest(viewPoint, query: .nearest, mask: .all).first else { return nil }
        return model.target(for: hit.entity, at: hit.position, from: camera.position(relativeTo: nil))
    }

    fileprivate func pointerDown(at point: NSPoint) {
        switch target(at: point) {
        case let .button(button):
            press(button, down: true)
        case let .panel(panel, location) where panel == activePanel:
            touching = panel
            touch(phase: 0, at: location)
        default:
            dragStart = point
        }
    }

    fileprivate func pointerDragged(to point: NSPoint, delta: NSPoint) {
        if let touching {
            // Keep the finger on its panel as it slides, even off the edge.
            if case let .panel(panel, location) = target(at: point), panel == touching {
                touch(phase: 1, at: location)
            }
        } else if dragStart != nil {
            orbit(by: delta)
        }
    }

    fileprivate func pointerUp(at point: NSPoint) {
        if let pressed {
            press(pressed, down: false)
        }
        if touching != nil {
            if case let .panel(_, location) = target(at: point) {
                touch(phase: 3, at: location)
            } else {
                touch(phase: 3, at: lastTouch)
            }
            touching = nil
        }
        dragStart = nil
    }

    fileprivate func cursor(at point: NSPoint) -> NSCursor {
        switch target(at: point) {
        case .button: .pointingHand
        case let .panel(panel, _) where panel == activePanel: .arrow
        default: .openHand
        }
    }

    private var lastTouch = CGPoint(x: 0.5, y: 0.5)
    /// A two-finger scroll that began on the lit screen: a finger dragged
    /// across the guest, which follows the 3D surface under it.
    private var scrollFinger: (start: NSPoint, travelled: NSPoint)?

    fileprivate func scroll(_ event: NSEvent, at point: NSPoint) {
        guard event.hasPreciseScrollingDeltas else {
            zoom(by: exp(-event.scrollingDeltaY * 8 * 0.004))
            return
        }
        // Momentum after the fingers lift is left alone: the guest's own
        // scrolling decelerates once the finger is up.
        if event.momentumPhase != [] { return }
        if event.phase.contains(.began) {
            if case let .panel(panel, location) = target(at: point), panel == activePanel, touching == nil {
                scrollFinger = (point, .zero)
                touch(phase: 0, at: location)
            } else {
                scrollFinger = nil
            }
        }
        guard var finger = scrollFinger else {
            zoom(by: exp(-event.scrollingDeltaY * 0.004))
            return
        }
        // The deltas follow the content; with natural scrolling off they
        // run the other way, so turn them back into the fingers' path.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        finger.travelled.x += event.scrollingDeltaX * sign
        finger.travelled.y -= event.scrollingDeltaY * sign
        scrollFinger = finger
        let at = NSPoint(x: finger.start.x + finger.travelled.x, y: finger.start.y + finger.travelled.y)
        if case let .panel(panel, location) = target(at: at), panel == activePanel {
            touch(phase: 1, at: location)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            touch(phase: 3, at: lastTouch)
            scrollFinger = nil
        }
    }

    // MARK: - Touch Indicator

    /// A soft white dot where a finger is down, riding the screen as it
    /// folds, so a recording shows where the touch went.
    private lazy var touchDot: ModelEntity = {
        // About a fingertip, grey and half clear like iOS's own touch marks.
        var material = UnlitMaterial(color: NSColor(white: 0.82, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.7))
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.0034), materials: [material])
        dot.isEnabled = false
        anchor.addChild(dot)
        return dot
    }()

    private func showTouch(_ location: CGPoint?) {
        guard let location, let model,
              let world = model.position(of: location, on: activePanel, relativeTo: nil)
        else {
            touchDot.isEnabled = false
            return
        }
        // A hair off the glass toward the viewer, so it never sinks into it.
        let lift = model.facing(activePanel, relativeTo: nil).map { $0 * 0.0006 } ?? .zero
        touchDot.setPosition(world + lift, relativeTo: nil)
        touchDot.isEnabled = true
    }

    // MARK: - Files

    fileprivate func dragEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        virtualMachineView?.draggingEntered(info) ?? []
    }

    fileprivate func dragExited(_ info: (any NSDraggingInfo)?) {
        virtualMachineView?.draggingExited(info)
    }

    fileprivate func performDrop(_ info: any NSDraggingInfo) -> Bool {
        virtualMachineView?.performDragOperation(info) ?? false
    }

    private func touch(phase: Int, at location: CGPoint) {
        lastTouch = location
        showTouch(phase == 3 ? nil : location)
        _ = virtualMachineView?.sendNormalizedTouch(
            phase: phase, normalized: [NSPoint(x: location.x, y: location.y)], swipeAim: 0,
        )
    }

    private func press(_ button: VPhoneDuoModel.Button, down: Bool) {
        pressed = down ? button : nil
        model?.setButton(button, pressed: down)
        feedback.play(button, down: down)
        onButton?(button, down)
    }
}

// MARK: - Event View

/// Takes the pointer over the 3D view, so RealityKit's own handling stays out.
private final class VPhoneDuoEventView: NSView {
    weak var owner: VPhoneDuoView?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        owner?.pointerDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.pointerDragged(
            to: convert(event.locationInWindow, from: nil), delta: NSPoint(x: event.deltaX, y: event.deltaY),
        )
    }

    override func mouseUp(with event: NSEvent) {
        owner?.pointerUp(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func rightMouseDragged(with event: NSEvent) {
        owner?.orbit(by: NSPoint(x: event.deltaX, y: event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        owner?.scroll(event, at: convert(event.locationInWindow, from: nil))
    }

    // Dropped files go where the VM view sends them: an .ipa or .tipa is
    // installed, anything else lands in the Files app.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.dragEntered(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.dragExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.performDrop(sender) ?? false
    }

    override func magnify(with event: NSEvent) {
        owner?.zoom(by: 1 / (1 + event.magnification))
    }
}
