import AppKit
import Metal
import MetalKit
import RealityKit

// MARK: - Live Panels

/// Puts the guest's display on the lit panel of the Duo model, frame by frame.
///
/// Each frame is the VM service's last presented buffer
/// (`VPhoneGraphicsDisplayCapture`), uploaded once to the GPU and copied into
/// a RealityKit drawable that the panel's material samples, so nothing is
/// rebuilt per frame. Capture is paced by the window's display link and
/// skipped while one is still in flight, so a slow guest never queues work.
/// Hands over the guest's current frame, or nil when there is none yet.
typealias VPhoneDuoFrameSource = @MainActor (@escaping @MainActor (CGImage?) -> Void) -> Void

@MainActor
final class VPhoneDuoPanelStream {
    var frameSource: VPhoneDuoFrameSource?
    var activePanel: VPhoneDuoModel.Panel = .inner {
        didSet { if activePanel != oldValue { attach() } }
    }

    private let model: VPhoneDuoModel
    private static let device = MTLCreateSystemDefaultDevice()
    private let queue = VPhoneDuoPanelStream.device?.makeCommandQueue()
    private let loader = VPhoneDuoPanelStream.device.map(MTKTextureLoader.init(device:))
    private var drawables: TextureResource.DrawableQueue?
    private var texture: TextureResource?
    private var shape: Shape?
    private var link: CADisplayLink?
    private var inFlight = false
    private var lastFrame: CFTimeInterval = 0

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
        guard !inFlight, now - lastFrame >= Self.minimumInterval * 0.9, let frameSource else { return }
        inFlight = true
        lastFrame = now
        frameSource { [weak self] image in
            guard let self else { return }
            inFlight = false
            if let image { present(image) }
        }
    }

    private func present(_ image: CGImage) {
        guard let queue, let loader,
              let source = try? loader.newTexture(cgImage: image, options: [
                  .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                  .textureStorageMode: MTLStorageMode.private.rawValue,
                  .SRGB: true,
              ])
        else { return }
        // A blit copies texels as they are, so the drawable takes the
        // decoded frame's own pixel format and size.
        let shape = Shape(width: source.width, height: source.height, format: source.pixelFormat)
        if shape != self.shape || drawables == nil {
            guard rebuild(for: shape) else { return }
        }
        guard let drawables,
              let drawable = try? drawables.nextDrawable(),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder()
        else { return }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        )
        blit.endEncoding()
        commands.commit()
        drawable.present()
    }

    private struct Shape: Equatable {
        let width: Int
        let height: Int
        let format: MTLPixelFormat
    }

    private func rebuild(for shape: Shape) -> Bool {
        let descriptor = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: shape.format, width: shape.width, height: shape.height,
            usage: [.shaderRead, .renderTarget], mipmapsMode: .none,
        )
        guard let queue = try? TextureResource.DrawableQueue(descriptor) else { return false }
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
