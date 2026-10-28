import AppKit
import Foundation
import RealityKit
import simd

// MARK: - iPhone Duo 3D Model

/// The iPhone Duo as a RealityKit entity tree built from `DuoModel.usdz`
/// (VPhone.bundle/Contents/Resources/DuoModel). The model is authored in
/// Blender units of 210.45 mm; the root scales it to metres.
///
/// As authored, the phone lies open flat, Y up, the hinge spine on the
/// scene's Y axis, the outer display facing +Z and the inner display -Z.
///
/// The hinge is one number, the angle between the two halves: 0 degrees
/// closed, 180 open flat. Each half turns about the spine by half of
/// (180 - angle), and each of the 12 bend bones per side by a twelfth of
/// that, so the inner panel's bend and the halves always meet.
@MainActor
final class VPhoneDuoModel {
    enum Panel: Sendable { case outer, inner }

    enum Button: String, CaseIterable, Sendable {
        case volumeUp = "hit_volume_up"
        case volumeDown = "hit_volume_down"
        case side = "hit_side"
        case cameraControl = "hit_camera_control"

        /// `volume_up`, `volume_down`, `side` or `camera_control`.
        init?(name: String) {
            self.init(rawValue: "hit_" + name)
        }

        /// The visible part that sinks while the button is held.
        var meshName: String {
            switch self {
            case .volumeUp, .volumeDown: "button_volume"
            case .side: "button_side"
            case .cameraControl: "button_camera_control"
            }
        }
    }

    /// What a hit on the phone is.
    enum Target: Equatable, Sendable {
        /// A point on a live panel, normalized to its framebuffer (0...1,
        /// origin top left, as the guest's touch space).
        case panel(Panel, CGPoint)
        case button(Button)
        case body
    }

    enum FinishPart { case metal, matte, sapphire }

    static let metresPerUnit: Float = 0.21045
    static let outerPixels = SIMD2<Int>(1398, 2034)
    static let innerPixels = SIMD2<Int>(1878, 2670)
    /// Hit zones reach this far past a button, in model units (1.2 mm).
    private static let buttonReach: Float = 0.0012 / metresPerUnit

    let root = Entity()
    private(set) var hingeAngle: Double = 180

    /// The loaded scene, in model units; everything is measured in its frame.
    private var scene = Entity()
    private var halves: [(entity: Entity, rest: Transform, sign: Float)] = []
    /// The spine in the halves' parent frame: a point on it and its direction.
    private var spine: (point: SIMD3<Float>, axis: SIMD3<Float>) = (.zero, [0, 1, 0])
    private var skinned: [(entity: ModelEntity, rest: [Transform], bend: [Int])] = []
    private var panels: [Panel: PanelSlot] = [:]
    private var buttons: [Button: ButtonPart] = [:]
    private var finishSlots: [(entity: ModelEntity, index: Int, part: FinishPart)] = []
    /// Each hit zone's centre at rest, in the scene frame.
    private var zoneCenters: [ObjectIdentifier: SIMD3<Float>] = [:]
    /// The volume rocker's middle along the edge, and which end is up.
    private var rocker: (middle: Float, upIsBelow: Bool)?

    /// A live panel: the material slot that shows the guest, and how to turn
    /// a point on it into the guest's touch space.
    private struct PanelSlot {
        let entity: ModelEntity
        let index: Int
        /// Hit zones, each riding the part of the phone it covers.
        var zones: [Entity] = []
        /// Which way the panel faces at rest, in the scene frame.
        var normal: SIMD3<Float> = [0, 0, 1]
        /// Where the frame sits on the panel.
        var fit = PanelFit(frame: 1, panel: 1)
        /// Maps a point in the scene frame, at rest, to texture coordinates.
        let mapping: PanelMapping
    }

    private struct ButtonPart {
        let mesh: Entity
        let rest: Transform
        /// Into the frame, in the mesh's parent frame.
        let inward: SIMD3<Float>
    }

    /// Apple's two finishes: Star White (polished silver-white titanium
    /// around matte white glass) and Space Black (dark polished titanium
    /// around matte black glass).
    private static func finish(_ finish: VPhoneDuoView.Finish, _ part: FinishPart) -> (color: NSColor, metallic: Float, roughness: Float) {
        switch (finish, part) {
        case (.white, .metal): (NSColor(srgbRed: 0.91, green: 0.90, blue: 0.88, alpha: 1), 1, 0.07)
        case (.white, .matte): (NSColor(srgbRed: 0.937, green: 0.929, blue: 0.902, alpha: 1), 0, 0.48)
        case (.black, .metal): (NSColor(srgbRed: 0.34, green: 0.34, blue: 0.36, alpha: 1), 1, 0.11)
        case (.black, .matte): (NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1), 0, 0.42)
        // Camera Control's sapphire takes the finish's tone.
        case (.white, .sapphire): (NSColor(srgbRed: 0.70, green: 0.69, blue: 0.67, alpha: 1), 0, 0.02)
        case (.black, .sapphire): (NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1), 0, 0.02)
        }
    }

    // MARK: - Loading

    static func load(from url: URL) async throws -> VPhoneDuoModel {
        let model = VPhoneDuoModel()
        let scene = try await Entity(contentsOf: url)
        model.scene = scene
        model.root.addChild(scene)
        model.root.scale = SIMD3(repeating: metresPerUnit)
        model.prepare()
        return model
    }

    private func find(_ name: String, in entity: Entity? = nil) -> Entity? {
        let entity = entity ?? scene
        if entity.name == name { return entity }
        for child in entity.children {
            if let found = find(name, in: child) { return found }
        }
        return nil
    }

    private func allEntities(_ entity: Entity) -> [Entity] {
        [entity] + entity.children.flatMap(allEntities)
    }

    private func prepare() {
        // Halves: the back half sits on -X, the front on +X; each folds
        // toward the inner (-Z) side.
        for (name, sign) in [("half_back", Float(-1)), ("half_front", Float(1))] {
            if let half = find(name) { halves.append((half, half.transform, sign)) }
        }
        if let parent = halves.first?.entity.parent {
            let spineCenter = find("hinge_spine").map { $0.visualBounds(relativeTo: scene).center } ?? .zero
            spine = (
                parent.convert(position: SIMD3(0, spineCenter.y, spineCenter.z), from: scene),
                simd_normalize(parent.convert(direction: [0, 1, 0], from: scene)),
            )
        }

        // Bend bones: per chain, every bone but the long last one turns.
        for case let model as ModelEntity in allEntities(scene) where !model.jointNames.isEmpty {
            let names = model.jointNames.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let bend = names.indices.filter { index in
                guard let number = VPhoneDuoModel.boneNumber(names[index]) else { return false }
                return number != 12 && number != 25
            }
            skinned.append((model, model.jointTransforms, bend))
        }

        preparePanels()
        prepareButtons()
        collectFinishSlots()
        setHinge(180)
    }

    /// "Bone" is 0, "Bone_007" (USD's rename of Blender's "Bone.007") is 7.
    static func boneNumber(_ name: String) -> Int? {
        if name == "Bone" { return 0 }
        guard name.hasPrefix("Bone_") || name.hasPrefix("Bone.") else { return nil }
        return Int(name.dropFirst(5))
    }

    // MARK: - Panels

    /// Finds the mesh part named `partName` anywhere in the scene.
    private func slot(forPart partName: String) -> (ModelEntity, MeshResource.Part)? {
        for case let model as ModelEntity in allEntities(scene) {
            guard let mesh = model.model?.mesh else { continue }
            for meshModel in mesh.contents.models {
                if let part = meshModel.parts.first(where: { $0.id == partName }) {
                    return (model, part)
                }
            }
        }
        return nil
    }

    private func preparePanels() {
        // Each live panel is a group whose child names the mesh part; the
        // inner one is a part of the skinned hinge mesh, the outer a mesh of
        // its own on the front half.
        for (panel, name) in [(Panel.outer, "display_outer_panel"), (.inner, "display_inner_panel")] {
            guard let group = find(name),
                  let partName = group.children.first?.name ?? (group as? ModelEntity)?.name,
                  let (entity, part) = slot(forPart: partName) ?? group.firstModel.flatMap({ model in
                      model.model?.mesh.contents.models.first?.parts.first.map { (model, $0) }
                  }),
                  var mapping = PanelMapping(part: part, from: entity, to: scene)
            else { continue }
            // A screen is never seen mirrored: with u to the right and v up,
            // u × v points out of the glass, away from the body it is set in.
            // Measured otherwise (a skinned part, placed by its skeleton),
            // the geometry is mirrored across the panel; mirror it back.
            let body = scene.visualBounds(relativeTo: scene).center
            if simd_dot(mapping.restNormal, SIMD3(0, 0, mapping.center.z - body.z)) < 0,
               let mirrored = mapping.mirroredAcrossU()
            {
                mapping = mirrored
            }
            var slot = PanelSlot(entity: entity, index: part.materialIndex, mapping: mapping)
            slot.normal = mapping.restNormal

            slot.zones = makeZones(for: mapping, panel: panel)
            panels[panel] = slot
        }
    }

    /// Flat hit boxes over a panel at rest, one per half it lies on, each a
    /// child of that half so it folds with it.
    private func makeZones(for mapping: PanelMapping, panel: Panel) -> [Entity] {
        var zones: [Entity] = []
        for half in halves {
            let points = mapping.restPoints.filter { ($0.x >= 0) == (half.sign > 0) }
            guard points.count >= 3 else { continue }
            var low = points[0], high = points[0]
            for point in points {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
            let zone = Entity()
            zone.name = "zone_\(panel)_\(half.sign > 0 ? "front" : "back")"
            let size = simd_max(high - low, SIMD3(repeating: 0.004))
            zone.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
            half.entity.addChild(zone)
            // Axis-aligned with the scene while the phone is open flat.
            zone.setTransformMatrix(Transform(translation: (low + high) / 2).matrix, relativeTo: scene)
            zoneCenters[ObjectIdentifier(zone)] = (low + high) / 2
            zones.append(zone)
        }
        return zones
    }

    /// Fits frames of `frameSize` to both panels before any has arrived, so
    /// a touch made before the first frame lands where the frame will be.
    func expectFrames(of frameSize: CGSize) {
        guard frameSize.width > 0, frameSize.height > 0 else { return }
        for (panel, var slot) in panels {
            slot.fit = PanelFit(frame: Float(frameSize.width / frameSize.height), panel: slot.mapping.aspect)
            panels[panel] = slot
        }
    }

    /// Lights a panel with `texture`, a frame of `frameSize` pixels, fitted
    /// to the panel at its own aspect ratio with black bars around it.
    ///
    /// A screen gives off its own light, so the material is unlit: the
    /// frame shows at its true colours whatever the studio light does.
    func setPanelTexture(_ panel: Panel, _ texture: TextureResource, frameSize: CGSize) {
        guard var slot = panels[panel], frameSize.width > 0, frameSize.height > 0 else { return }
        slot.fit = PanelFit(frame: Float(frameSize.width / frameSize.height), panel: slot.mapping.aspect)
        panels[panel] = slot
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToZero
        sampler.tAddressMode = .clampToZero
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture, sampler: .init(sampler)))
        material.textureCoordinateTransform = .init(offset: slot.fit.offset, scale: slot.fit.scale, rotation: 0)
        setPanelMaterial(panel, material)
    }

    /// A panel that is off: black glass that still reflects the studio.
    func setPanelOff(_ panel: Panel) {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(white: 0.012, alpha: 1))
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.05)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.03)
        setPanelMaterial(panel, material)
    }

    private func setPanelMaterial(_ panel: Panel, _ material: any Material) {
        guard let slot = panels[panel], var materials = slot.entity.model?.materials,
              materials.indices.contains(slot.index)
        else { return }
        materials[slot.index] = material
        slot.entity.model?.materials = materials
    }

    // MARK: - Buttons

    private func prepareButtons() {
        for button in Button.allCases {
            guard let mesh = find(button.meshName), let parent = mesh.parent else { continue }
            let bounds = mesh.visualBounds(relativeTo: scene)
            // One zone per key, a little larger than it so it is easy to hit.
            // The volume keys share one rocker and one zone; where on it a
            // click lands decides which key it is.
            if find(zoneName(for: button)) == nil {
                let reach = SIMD3<Float>(repeating: Self.buttonReach)
                let zone = Entity()
                zone.name = zoneName(for: button)
                zone.components.set(CollisionComponent(shapes: [.generateBox(size: bounds.extents + reach * 2)]))
                parent.addChild(zone)
                zone.setTransformMatrix(Transform(translation: bounds.center).matrix, relativeTo: scene)
                zoneCenters[ObjectIdentifier(zone)] = bounds.center
            }
            if button == .volumeUp {
                // Up is the half nearer the free edge, away from the hinge.
                rocker = (middle: bounds.center.x, upIsBelow: abs(bounds.min.x) > abs(bounds.max.x))
            }

            // Into the frame: from the button toward the middle of its half,
            // along whichever edge it sits on (the top, or the free side).
            let half = parent.visualBounds(relativeTo: scene)
            var inward = half.center - bounds.center
            inward.z = 0
            if abs(inward.x) / max(half.extents.x, 1e-4) > abs(inward.y) / max(half.extents.y, 1e-4) {
                inward.y = 0
            } else {
                inward.x = 0
            }
            let direction = simd_length(inward) > 0 ? simd_normalize(inward) : .zero
            buttons[button] = ButtonPart(
                mesh: mesh, rest: mesh.transform,
                inward: simd_normalize(parent.convert(direction: direction, from: scene)),
            )
        }
    }

    private static let rockerZone = "hit_volume"

    private func zoneName(for button: Button) -> String {
        button == .volumeUp || button == .volumeDown ? Self.rockerZone : button.rawValue
    }

    /// The middle of a key, in `reference`'s frame.
    func center(of button: Button, relativeTo reference: Entity?) -> SIMD3<Float>? {
        guard let zone = find(zoneName(for: button)) else { return nil }
        guard button == .volumeUp || button == .volumeDown, let rocker,
              let center = zoneCenters[ObjectIdentifier(zone)], let mesh = find(button.meshName)
        else { return zone.convert(position: .zero, to: reference) }
        // A quarter of the rocker in from its middle, toward that key's end.
        let length = mesh.visualBounds(relativeTo: scene).extents.x
        let towardLow = (button == .volumeUp) == rocker.upIsBelow
        let offset = SIMD3<Float>(length / 4 * (towardLow ? -1 : 1), 0, 0)
        return zone.convert(position: SIMD3(rocker.middle, center.y, center.z) - center + offset, to: reference)
    }

    /// Sinks a button into the frame by `depth` metres while it is held.
    func setButton(_ button: Button, pressed: Bool, depth: Float = 0.0003) {
        guard let part = buttons[button], let parent = part.mesh.parent else { return }
        var transform = part.rest
        if pressed, part.inward.x.isFinite {
            let scale = simd_length(parent.convert(direction: [1, 0, 0], from: scene))
            transform.translation += part.inward * (depth / Self.metresPerUnit) * scale
        }
        part.mesh.move(to: transform, relativeTo: parent, duration: pressed ? 0.05 : 0.09, timingFunction: .easeOut)
    }

    // MARK: - Finish

    private func collectFinishSlots() {
        let live = Set(panels.values.map { "\(ObjectIdentifier($0.entity))/\($0.index)" })
        if let sapphire = find(Button.cameraControl.meshName)?.firstModel {
            finishSlots.append((sapphire, 0, .sapphire))
        }
        for case let entity as ModelEntity in allEntities(scene) {
            guard let materials = entity.model?.materials,
                  !finishSlots.contains(where: { $0.entity === entity })
            else { continue }
            for (index, material) in materials.enumerated() {
                guard !live.contains("\(ObjectIdentifier(entity))/\(index)"),
                      let pbr = material as? PhysicallyBasedMaterial
                else { continue }
                let tint = pbr.baseColor.tint.usingColorSpace(.sRGB) ?? .white
                let bright = tint.redComponent > 0.8 && tint.greenComponent > 0.8 && tint.blueComponent > 0.75
                if pbr.metallic.scale > 0.9, pbr.roughness.scale < 0.2 {
                    finishSlots.append((entity, index, .metal))
                } else if bright, pbr.metallic.scale < 0.1, pbr.roughness.scale > 0.3 {
                    finishSlots.append((entity, index, .matte))
                }
            }
        }
    }

    func setFinish(_ finish: VPhoneDuoView.Finish) {
        for slot in finishSlots {
            guard var materials = slot.entity.model?.materials,
                  var pbr = materials[slot.index] as? PhysicallyBasedMaterial
            else { continue }
            let look = Self.finish(finish, slot.part)
            pbr.baseColor = .init(tint: look.color, texture: pbr.baseColor.texture)
            pbr.metallic = .init(floatLiteral: look.metallic)
            pbr.roughness = .init(floatLiteral: look.roughness)
            if slot.part == .matte {
                pbr.clearcoat = .init(floatLiteral: 0.25)
                pbr.clearcoatRoughness = .init(floatLiteral: 0.35)
            }
            materials[slot.index] = pbr
            slot.entity.model?.materials = materials
        }
    }

    // MARK: - Hinge

    /// Each bend bone's turn for a hinge angle, in radians.
    static func boneTurn(forHingeAngle angle: Double) -> Float {
        let clamped: Double = min(max(angle, 0), 180)
        let degrees: Double = (180 - clamped) / 24
        return Float(degrees * Double.pi / 180)
    }

    func setHinge(_ angle: Double) {
        hingeAngle = min(max(angle, 0), 180)
        let t = VPhoneDuoModel.boneTurn(forHingeAngle: hingeAngle)
        for half in halves {
            // Turn about the spine, in the parent's frame, from rest.
            let turn = simd_quatf(angle: 12 * t * half.sign, axis: spine.axis)
            var transform = half.rest
            transform.rotation = turn * half.rest.rotation
            transform.translation = spine.point + turn.act(half.rest.translation - spine.point)
            half.entity.transform = transform
        }
        for part in skinned {
            var joints = part.rest
            for index in part.bend {
                joints[index].rotation = part.rest[index].rotation * simd_quatf(angle: t, axis: [0, 0, 1])
            }
            part.entity.jointTransforms = joints
        }
    }

    /// The phone's bounds as it is folded now, in `reference`'s frame.
    func bounds(relativeTo reference: Entity?) -> BoundingBox {
        scene.visualBounds(relativeTo: reference)
    }

    /// Which way a panel faces, in `reference`'s frame.
    func facing(_ panel: Panel, relativeTo reference: Entity?) -> SIMD3<Float>? {
        guard let slot = panels[panel], let zone = slot.zones.first else { return nil }
        let normal = slot.normal
        // The zone was placed scene-aligned at rest, so the rest normal in
        // its frame is the scene normal; carry it to the reference.
        return simd_normalize(zone.convert(direction: normal, to: reference))
    }

    /// Where a point of the guest's screen is on a panel now, in
    /// `reference`'s frame: the inverse of a touch.
    func position(of point: CGPoint, on panel: Panel, relativeTo reference: Entity?) -> SIMD3<Float>? {
        guard let slot = panels[panel] else { return nil }
        let uv = slot.fit.panel(at: SIMD2(Float(point.x), Float(point.y)))
        guard let rest = slot.mapping.restPoint(at: uv) else { return nil }
        // The zone on the half that point lies on carries it to where it is now.
        guard let zone = slot.zones.first(where: { zone in
            guard let center = zoneCenters[ObjectIdentifier(zone)] else { return false }
            return (center.x >= 0) == (rest.x >= 0)
        }) ?? slot.zones.first, let center = zoneCenters[ObjectIdentifier(zone)] else { return nil }
        return zone.convert(position: rest - center, to: reference)
    }

    // MARK: - Hit testing

    /// Classifies a ray hit, given the entity it hit, the world position of
    /// the hit and where the ray came from.
    func target(for entity: Entity, at world: SIMD3<Float>, from eye: SIMD3<Float>) -> Target {
        if entity.name == Self.rockerZone, let rocker, let center = zoneCenters[ObjectIdentifier(entity)] {
            // Where the ray passes nearest the rocker's own axis: a ray that
            // grazes the zone enters it well before the key it is aimed at.
            let origin = entity.convert(position: eye, from: nil) + center
            let direction = entity.convert(position: world, from: nil) + center - origin
            let axisPoint = SIMD3(rocker.middle, center.y, center.z)
            let w = origin - axisPoint
            let a = simd_dot(direction, direction), b = direction.x, e = w.x
            let denominator = a - b * b
            let along = denominator > 1e-12 ? (a * e - b * simd_dot(direction, w)) / denominator : e
            let x = rocker.middle + along
            return .button((x < rocker.middle) == rocker.upIsBelow ? .volumeUp : .volumeDown)
        }
        if let button = Button(rawValue: entity.name) { return .button(button) }
        for (panel, slot) in panels where slot.zones.contains(where: { $0 === entity }) {
            // The zone's frame is the scene's at rest, offset to the zone's
            // centre, so this is where the point was with the phone open flat.
            guard let center = zoneCenters[ObjectIdentifier(entity)] else { return .body }
            let rest = entity.convert(position: world, from: nil) + center
            guard let uv = slot.mapping.uv(atRestPoint: rest) else { return .body }
            // Through the fit to the frame; a touch on the bars misses it.
            let frame = slot.fit.frame(at: uv)
            guard (0 ... 1).contains(frame.x), (0 ... 1).contains(frame.y) else { return .body }
            return .panel(panel, CGPoint(x: CGFloat(frame.x), y: CGFloat(frame.y)))
        }
        return .body
    }
}

// MARK: - Panel Fit

/// A frame fitted inside a panel of another aspect ratio, centred.
struct PanelFit: Equatable {
    /// Texture coordinates on the panel to coordinates in the frame.
    let scale: SIMD2<Float>
    let offset: SIMD2<Float>

    init(frame: Float, panel: Float) {
        if frame < panel {
            // Narrower: bars at the sides.
            let width = frame / panel
            scale = [1 / width, 1]
            offset = [-(1 - width) / 2 / width, 0]
        } else {
            let height = panel / frame
            scale = [1, 1 / height]
            offset = [0, -(1 - height) / 2 / height]
        }
    }

    func frame(at panel: SIMD2<Float>) -> SIMD2<Float> {
        panel * scale + offset
    }

    func panel(at frame: SIMD2<Float>) -> SIMD2<Float> {
        (frame - offset) / scale
    }
}

// MARK: - Panel Mapping

/// The texture coordinates across a flat panel, fitted from its own mesh:
/// three of its vertices, far apart, fix the affine map from position to
/// texture coordinates, which a flat UV layout follows exactly.
private struct PanelMapping {
    /// Every vertex of the panel, in the scene frame, at rest.
    let restPoints: [SIMD3<Float>]
    private let uvs: [SIMD2<Float>]
    let restNormal: SIMD3<Float>
    /// Width over height, as the panel's texture is laid on it.
    let aspect: Float
    private let origin: SIMD3<Float>
    private let edgeU: SIMD3<Float>
    private let edgeV: SIMD3<Float>
    private let uv0: SIMD2<Float>
    private let uvU: SIMD2<Float>
    private let uvV: SIMD2<Float>

    @MainActor
    init?(part: MeshResource.Part, from entity: ModelEntity, to scene: Entity) {
        guard let uvs = part.textureCoordinates?.elements else { return nil }
        let local = Self.posedPositions(of: part, in: entity)
        guard local.count == uvs.count, local.count >= 3 else { return nil }
        self.init(points: local.map { scene.convert(position: $0, from: entity) }, uvs: uvs)
    }

    /// The same panel reflected across its middle, along u.
    func mirroredAcrossU() -> PanelMapping? {
        let axis = simd_normalize(edgeU)
        let middle = center
        let points = restPoints.map { $0 - 2 * simd_dot($0 - middle, axis) * axis }
        return PanelMapping(points: points, uvs: uvs)
    }

    var center: SIMD3<Float> {
        restPoints.reduce(SIMD3<Float>.zero, +) / Float(restPoints.count)
    }

    private init?(points: [SIMD3<Float>], uvs: [SIMD2<Float>]) {
        // Vertices nearest three corners of texture space.
        func nearest(_ corner: SIMD2<Float>) -> Int {
            uvs.indices.min(by: { simd_distance(uvs[$0], corner) < simd_distance(uvs[$1], corner) })!
        }
        let a = nearest([0, 0]), b = nearest([1, 0]), c = nearest([0, 1])
        guard Set([a, b, c]).count == 3 else { return nil }
        restPoints = points
        self.uvs = uvs
        origin = points[a]
        edgeU = points[b] - points[a]
        edgeV = points[c] - points[a]
        uv0 = uvs[a]
        uvU = uvs[b] - uvs[a]
        uvV = uvs[c] - uvs[a]
        let normal = simd_cross(edgeU, edgeV)
        guard simd_length(normal) > 1e-9 else { return nil }
        restNormal = simd_normalize(normal)
        // Physical length of one unit of u, and of v.
        let lengthU = simd_length(edgeU) / max(abs(uvU.x), 1e-6)
        let lengthV = simd_length(edgeV) / max(abs(uvV.y), 1e-6)
        aspect = lengthU / lengthV
    }

    /// A part's vertices where the entity draws them: a skinned part's are
    /// stored in bind space and moved by its joints, so they are skinned
    /// here with the joints as they stand.
    @MainActor
    private static func posedPositions(of part: MeshResource.Part, in entity: ModelEntity) -> [SIMD3<Float>] {
        let positions = part.positions.elements
        guard let skeletonID = part.skeletonID,
              let skeleton = entity.model?.mesh.contents.skeletons[skeletonID],
              let influences = part.jointInfluences?.influences.elements
        else { return positions }
        // The buffer holds the same number of influences for every vertex.
        guard !positions.isEmpty, influences.count % positions.count == 0 else { return positions }
        let perVertex = influences.count / positions.count
        let joints = skeleton.joints
        let local = entity.jointTransforms
        guard local.count == joints.count, influences.count >= positions.count * perVertex else { return positions }
        // Each joint in the mesh's space, then the skinning matrix.
        var modelSpace = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for (index, joint) in joints.enumerated() {
            let own = local[index].matrix
            modelSpace[index] = joint.parentIndex.map { modelSpace[$0] * own } ?? own
        }
        let skin = joints.indices.map { modelSpace[$0] * joints[$0].inverseBindPoseMatrix }
        return positions.indices.map { vertex in
            var sum = SIMD4<Float>.zero
            var weights: Float = 0
            for slot in 0 ..< perVertex {
                let influence = influences[vertex * perVertex + slot]
                guard influence.weight > 0, skin.indices.contains(influence.jointIndex) else { continue }
                sum += influence.weight * (skin[influence.jointIndex] * SIMD4(positions[vertex], 1))
                weights += influence.weight
            }
            guard weights > 0 else { return positions[vertex] }
            let point = sum / weights
            return SIMD3(point.x, point.y, point.z)
        }
    }

    /// The point on the panel at rest with these touch-space coordinates.
    func restPoint(at touch: SIMD2<Float>) -> SIMD3<Float>? {
        // Back from touch space to texture coordinates, then solve
        // st = uv0 + s * uvU + t * uvV for s and t.
        let st = SIMD2(touch.x, 1 - touch.y) - uv0
        let det = uvU.x * uvV.y - uvU.y * uvV.x
        guard abs(det) > 1e-12 else { return nil }
        let s = (st.x * uvV.y - st.y * uvV.x) / det
        let t = (uvU.x * st.y - uvU.y * st.x) / det
        return origin + s * edgeU + t * edgeV
    }

    /// Texture coordinates at a point on the panel at rest, as the guest's
    /// touch space: origin top left, y down.
    func uv(atRestPoint point: SIMD3<Float>) -> SIMD2<Float>? {
        // Solve point - origin = s * edgeU + t * edgeV in the panel's plane.
        let d = point - origin
        let uu = simd_dot(edgeU, edgeU), uvDot = simd_dot(edgeU, edgeV), vv = simd_dot(edgeV, edgeV)
        let du = simd_dot(d, edgeU), dv = simd_dot(d, edgeV)
        let det = uu * vv - uvDot * uvDot
        guard abs(det) > 1e-12 else { return nil }
        let s = (du * vv - dv * uvDot) / det
        let t = (dv * uu - du * uvDot) / det
        let st = uv0 + s * uvU + t * uvV
        // USD texture coordinates run up from the bottom; touches run down.
        return SIMD2(st.x, 1 - st.y)
    }
}

private extension Entity {
    var firstModel: ModelEntity? {
        if let model = self as? ModelEntity { return model }
        for child in children {
            if let model = child.firstModel { return model }
        }
        return nil
    }
}
