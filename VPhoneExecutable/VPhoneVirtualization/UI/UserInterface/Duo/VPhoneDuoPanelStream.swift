import AppKit
import Metal
import RealityKit

// MARK: - Live Panels

/// Hands over the guest's current frame, or nil when there is none yet.
typealias VPhoneDuoFrameSource = @MainActor (@escaping @MainActor (CGImage?) -> Void) -> Void

/// Puts the guest's display on the lit panel of the Duo model, frame by frame.
///
/// Each frame is the VM service's last presented buffer
/// (`VPhoneGraphicsDisplayCapture`). It is drawn into one reused buffer that
/// backs a shared staging texture, then copied on the GPU into a RealityKit
/// drawable that the panel's material samples, so nothing is allocated per
/// frame. That takes about 3.5 ms for the outer panel's 1398 x 2034 frame;
/// `MTKTextureLoader`, which decodes into a new texture each time, took 35.
/// Capture is paced by the window's display link and skipped while one is
/// still in flight, so a slow guest never queues work.
@MainActor
final class VPhoneDuoPanelStream {
    var frameSource: VPhoneDuoFrameSource?
    var activePanel: VPhoneDuoModel.Panel = .inner {
        didSet { if activePanel != oldValue { attach() } }
    }

    private let model: VPhoneDuoModel
    private static let device = MTLCreateSystemDefaultDevice()
    private let queue = VPhoneDuoPanelStream.device?.makeCommandQueue()
    /// The frame's pixels, drawn on the CPU and read by the GPU.
    private var staging: (texture: MTLTexture, context: CGContext)?
    private var drawables: TextureResource.DrawableQueue?
    private var texture: TextureResource?
    private var shape: Shape?
    private var link: CADisplayLink?
    private var inFlight = false
    private var lastFrame: CFTimeInterval = 0
    /// Counts capture requests, so one answered after it was given up on is
    /// ignored.
    private var generation = 0
    /// The last copy to the drawable has not finished: the staging buffer is
    /// still being read.
    private var gpuBusy = false
    /// A capture not answered in this time is given up on.
    private static let captureTimeout: CFTimeInterval = 0.5

    /// The guest presents at up to 60 Hz; the panel need not go faster.
    private static let minimumInterval: CFTimeInterval = 1.0 / 60

    init(model: VPhoneDuoModel) {
        self.model = model
    }

    func start() {
        attach()
        guard link == nil else { return }
        let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Lights the active panel with the stream and darkens the other.
    private func attach() {
        let other: VPhoneDuoModel.Panel = activePanel == .inner ? .outer : .inner
        model.setPanelOff(other)
        if let texture, let shape {
            model.setPanelTexture(activePanel, texture, frameSize: CGSize(width: shape.width, height: shape.height))
        } else {
            model.setPanelOff(activePanel)
        }
    }

    @objc private func tick(_: CADisplayLink) {
        let now = CACurrentMediaTime()
        if inFlight, now - lastFrame > Self.captureTimeout { inFlight = false }
        guard !inFlight, !gpuBusy, now - lastFrame >= Self.minimumInterval * 0.9, let frameSource else { return }
        inFlight = true
        lastFrame = now
        generation += 1
        let request = generation
        frameSource { [weak self] image in
            guard let self, request == generation else { return }
            inFlight = false
            if let image { present(image) }
        }
    }

    private func present(_ image: CGImage) {
        let shape = Shape(width: image.width, height: image.height)
        if shape != self.shape || drawables == nil || staging == nil {
            guard rebuild(for: shape) else { return }
        }
        guard let queue, let staging, let drawables,
              let pixels = staging.context.data
        else { return }
        // Drawing converts whatever the frame's layout is to the staging
        // buffer's BGRA, which the texture then takes as it is.
        staging.context.draw(image, in: CGRect(x: 0, y: 0, width: shape.width, height: shape.height))
        staging.texture.replace(
            region: MTLRegionMake2D(0, 0, shape.width, shape.height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: staging.context.bytesPerRow,
        )
        guard let drawable = try? drawables.nextDrawable(),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder()
        else { return }
        blit.copy(
            from: staging.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: shape.width, height: shape.height, depth: 1),
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        )
        blit.endEncoding()
        gpuBusy = true
        commands.addCompletedHandler { [weak self] _ in
            Task { @MainActor in self?.gpuBusy = false }
        }
        commands.commit()
        drawable.present()
    }

    private struct Shape: Equatable {
        let width: Int
        let height: Int
    }

    private static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    private func rebuild(for shape: Shape) -> Bool {
        let descriptor = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: Self.pixelFormat, width: shape.width, height: shape.height,
            usage: [.shaderRead, .renderTarget], mipmapsMode: .none,
        )
        let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: shape.width, height: shape.height, mipmapped: false,
        )
        stagingDescriptor.usage = .shaderRead
        stagingDescriptor.storageMode = .shared
        guard let queue = try? TextureResource.DrawableQueue(descriptor),
              let stagingTexture = Self.device?.makeTexture(descriptor: stagingDescriptor),
              let context = CGContext(
                  data: nil, width: shape.width, height: shape.height, bitsPerComponent: 8, bytesPerRow: shape.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
              )
        else { return false }
        staging = (stagingTexture, context)
        queue.allowsNextDrawableTimeout = true
        do {
            let placeholder: TextureResource
            if let texture {
                placeholder = texture
            } else {
                let black = CGContext(
                    data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue,
                )!.makeImage()!
                placeholder = try TextureResource(image: black, options: .init(semantic: .color))
            }
            placeholder.replace(withDrawables: queue)
            texture = placeholder
            drawables = queue
            self.shape = shape
            attach()
            return true
        } catch {
            return false
        }
    }
}
