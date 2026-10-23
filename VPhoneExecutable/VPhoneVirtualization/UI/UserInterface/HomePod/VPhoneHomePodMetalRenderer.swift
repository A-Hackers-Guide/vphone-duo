import AppKit
import MetalKit
import VPhoneCoreKit

// MARK: - Shader Inputs

struct VPhoneHomePodMetalUniforms {
    var viewport: SIMD4<Float>
    var cap: SIMD4<Float>
}

struct VPhoneHomePodMetalLED {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

enum VPhoneHomePodMetalError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        if case let .unavailable(message) = self { return message }
        return nil
    }
}

// MARK: - On-demand Metal View

/// Rendering follows guest snapshots and window damage, never a host animation
/// timer. At most three frames are in flight; GPU completion retries the newest
/// pending snapshot if the GPU was busy when it arrived.
@MainActor
final class VPhoneHomePodMetalView: MTKView, MTKViewDelegate {
    private var backend: (any VPhoneHomePodMetalBackend)?
    private var geometry: VPhoneHomePodDisplayGeometry?
    private var snapshot: VPhoneHomePodDisplayFrame?
    private var pending = true
    private(set) var renderingError: String?
    var backendName: String? { backend?.name }

    init(frame: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        clearColor = MTLClearColor(red: 0.0044, green: 0.0044, blue: 0.0044, alpha: 1)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        setAccessibilityElement(false)
        delegate = self
        do {
            guard let device else { throw VPhoneHomePodMetalError.unavailable("No Metal device is available.") }
            if #available(macOS 26.0, *), device.supportsFamily(.metal4) {
                backend = try VPhoneHomePodMetal4Backend(device: device, format: colorPixelFormat)
            } else {
                // The app still supports macOS 15. The same runtime-compiled
                // optical shader uses Metal's older submission API there.
                backend = try VPhoneHomePodMetalLegacyBackend(device: device, format: colorPixelFormat)
            }
            print("[homepod] \(backend!.name) top-cap renderer ready")
        } catch {
            renderingError = error.localizedDescription
            print("[homepod] Metal renderer: \(error)")
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Create the HomePod Metal view programmatically.") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(geometry: VPhoneHomePodDisplayGeometry?, snapshot: VPhoneHomePodDisplayFrame?) {
        if let geometry, let snapshot, !snapshot.matches(geometry) { return }
        self.geometry = geometry
        self.snapshot = snapshot
        pending = true
        needsDisplay = true
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            pending = true
            needsDisplay = true
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    private func render() {
        guard let backend, backend.hasFreeFrame, drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable else { return }
        let scale = drawableSize.width / max(bounds.width, 1)
        let radius = max(0, (min(bounds.width, bounds.height) - 32) / 2) * scale
        let count = geometry?.points.count ?? 0
        let uniforms = VPhoneHomePodMetalUniforms(
            viewport: SIMD4(Float(drawableSize.width), Float(drawableSize.height), Float(drawableSize.width / 2), Float(drawableSize.height / 2)),
            cap: SIMD4(Float(radius), Float(count), Float((snapshot?.plusBrightness ?? 0) * (snapshot?.brightness ?? 0)), Float((snapshot?.minusBrightness ?? 0) * (snapshot?.brightness ?? 0))),
        )
        let leds: [VPhoneHomePodMetalLED] = (geometry?.points.enumerated().map { index, point in
            let rgb = snapshot?.pixels[index] ?? [0, 0, 0]
            let brightness = Float(snapshot?.brightness ?? 0)
            return VPhoneHomePodMetalLED(
                position: SIMD4(Float(point.x), Float(point.y), Float(point.ring), 0),
                color: SIMD4(Float(rgb[0]) * brightness, Float(rgb[1]) * brightness, Float(rgb[2]) * brightness, 0),
            )
        }) ?? []
        do {
            pending = false
            try backend.render(texture: drawable.texture, drawable: drawable, uniforms: uniforms, leds: leds) { [weak self] error in
                guard let self else { return }
                if let error {
                    renderingError = error
                    print("[homepod] Metal frame: \(error)")
                }
                if pending { needsDisplay = true }
            }
        } catch {
            renderingError = error.localizedDescription
            print("[homepod] Metal frame: \(error)")
        }
    }
}

// MARK: - Frame Ownership

@MainActor
protocol VPhoneHomePodMetalBackend: AnyObject {
    var name: String { get }
    var hasFreeFrame: Bool { get }
    func render(texture: any MTLTexture, drawable: (any CAMetalDrawable)?, uniforms: VPhoneHomePodMetalUniforms,
                leds: [VPhoneHomePodMetalLED], completion: @escaping @MainActor (String?) -> Void) throws
}

@MainActor
private class VPhoneHomePodMetalFrame {
    static let maximumLEDCount = 1024
    let uniforms: any MTLBuffer
    let leds: any MTLBuffer
    var inFlight = false
    var texture: (any MTLTexture)?
    var drawable: (any CAMetalDrawable)?

    init(device: any MTLDevice) throws {
        guard let uniforms = device.makeBuffer(length: MemoryLayout<VPhoneHomePodMetalUniforms>.stride, options: .storageModeShared),
              let leds = device.makeBuffer(length: MemoryLayout<VPhoneHomePodMetalLED>.stride * Self.maximumLEDCount, options: .storageModeShared)
        else { throw VPhoneHomePodMetalError.unavailable("Could not allocate HomePod frame buffers.") }
        self.uniforms = uniforms
        self.leds = leds
    }

    func write(_ value: VPhoneHomePodMetalUniforms, leds values: [VPhoneHomePodMetalLED]) throws {
        guard values.count <= Self.maximumLEDCount else { throw VPhoneHomePodMetalError.unavailable("Too many HomePod LEDs.") }
        var value = value
        withUnsafeBytes(of: &value) { uniforms.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        values.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty { leds.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
    }

    func finish() {
        inFlight = false
        texture = nil
        drawable = nil
    }
}

// MARK: - Metal 4

@available(macOS 26.0, *)
@MainActor
final class VPhoneHomePodMetal4Backend: VPhoneHomePodMetalBackend {
    let name = "Metal 4"
    private let queue: any MTL4CommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let frames: [Frame]
    var hasFreeFrame: Bool { frames.contains { !$0.inFlight } }

    private final class Frame: VPhoneHomePodMetalFrame {
        let allocator: any MTL4CommandAllocator
        let commands: any MTL4CommandBuffer
        let arguments: any MTL4ArgumentTable
        let residency: any MTLResidencySet

        override init(device: any MTLDevice) throws {
            guard let allocator = device.makeCommandAllocator(), let commands = device.makeCommandBuffer()
            else { throw VPhoneHomePodMetalError.unavailable("Metal 4 command allocation failed.") }
            self.allocator = allocator
            self.commands = commands
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.maxBufferBindCount = 2
            descriptor.initializeBindings = true
            arguments = try device.makeArgumentTable(descriptor: descriptor)
            let residencyDescriptor = MTLResidencySetDescriptor()
            residencyDescriptor.initialCapacity = 3
            residency = try device.makeResidencySet(descriptor: residencyDescriptor)
            try super.init(device: device)
            arguments.setAddress(uniforms.gpuAddress, index: 0)
            arguments.setAddress(leds.gpuAddress, index: 1)
        }
    }

    init(device: any MTLDevice, format: MTLPixelFormat) throws {
        guard let queue = device.makeMTL4CommandQueue() else { throw VPhoneHomePodMetalError.unavailable("Metal 4 queue creation failed.") }
        self.queue = queue
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let libraryDescriptor = MTL4LibraryDescriptor()
        libraryDescriptor.source = VPhoneHomePodShader.source
        libraryDescriptor.name = "HomePod top-cap optics"
        let options = MTLCompileOptions()
        options.languageVersion = .version4_0
        libraryDescriptor.options = options
        let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
        func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
            let descriptor = MTL4LibraryFunctionDescriptor()
            descriptor.library = library
            descriptor.name = name
            return descriptor
        }
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "HomePod diffuser"
        descriptor.vertexFunctionDescriptor = function("capVertex")
        descriptor.fragmentFunctionDescriptor = function("capFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
        frames = try (0 ..< 3).map { _ in try Frame(device: device) }
    }

    func render(texture: any MTLTexture, drawable: (any CAMetalDrawable)?, uniforms: VPhoneHomePodMetalUniforms,
                leds: [VPhoneHomePodMetalLED], completion: @escaping @MainActor (String?) -> Void) throws {
        guard let frame = frames.first(where: { !$0.inFlight }) else { return }
        try frame.write(uniforms, leds: leds)
        frame.texture = texture
        frame.drawable = drawable
        frame.residency.removeAllAllocations()
        frame.residency.addAllocation(frame.uniforms)
        frame.residency.addAllocation(frame.leds)
        frame.residency.addAllocation(texture)
        frame.residency.commit()
        // Never reset command memory or rewrite inputs until feedback confirms
        // GPU completion. Capturing the frame also retains every GPU resource.
        frame.allocator.reset()
        frame.commands.beginCommandBuffer(allocator: frame.allocator)
        frame.commands.useResidencySet(frame.residency)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = frame.commands.makeRenderCommandEncoder(descriptor: pass) else {
            frame.commands.endCommandBuffer()
            frame.finish()
            throw VPhoneHomePodMetalError.unavailable("Metal 4 render encoder creation failed.")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setArgumentTable(frame.arguments, stages: .fragment)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        frame.commands.endCommandBuffer()
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { feedback in
            let error = feedback.error?.localizedDescription
            Task { @MainActor in
                frame.finish()
                completion(error)
            }
        }
        frame.inFlight = true
        if let drawable { queue.waitForDrawable(drawable) }
        queue.commit([frame.commands], options: options)
        if let drawable {
            queue.signalDrawable(drawable)
            drawable.present()
        }
    }
}

// MARK: - macOS 15 Compatibility

@MainActor
final class VPhoneHomePodMetalLegacyBackend: VPhoneHomePodMetalBackend {
    let name = "Metal (macOS 15 compatibility)"
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let frames: [VPhoneHomePodMetalFrame]
    var hasFreeFrame: Bool { frames.contains { !$0.inFlight } }

    init(device: any MTLDevice, format: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw VPhoneHomePodMetalError.unavailable("Metal queue creation failed.") }
        self.queue = queue
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: VPhoneHomePodShader.source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "capVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "capFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        frames = try (0 ..< 3).map { _ in try VPhoneHomePodMetalFrame(device: device) }
    }

    func render(texture: any MTLTexture, drawable: (any CAMetalDrawable)?, uniforms: VPhoneHomePodMetalUniforms,
                leds: [VPhoneHomePodMetalLED], completion: @escaping @MainActor (String?) -> Void) throws {
        guard let frame = frames.first(where: { !$0.inFlight }), let commands = queue.makeCommandBuffer() else { return }
        try frame.write(uniforms, leds: leds)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw VPhoneHomePodMetalError.unavailable("Metal render encoder creation failed.") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(frame.uniforms, offset: 0, index: 0)
        encoder.setFragmentBuffer(frame.leds, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        frame.inFlight = true
        commands.addCompletedHandler { commands in
            let error = commands.error?.localizedDescription
            Task { @MainActor in frame.finish(); completion(error) }
        }
        if let drawable { commands.present(drawable) }
        commands.commit()
    }
}
