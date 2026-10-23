import Foundation
import MetalKit
import ImageIO
import VPhoneCoreKit

/// Executes the real Metal 4 compiler/queue offscreen. This needs no VM, bundle
/// installation or administrator authorization. Output PNGs support optical QA.
@main
struct HomePodMetalProbe {
    @MainActor
    static func main() async throws {
        guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
            throw VPhoneHomePodMetalError.unavailable("This probe requires a Metal 4 GPU and macOS 26 or later.")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var backend: any VPhoneHomePodMetalBackend = try VPhoneHomePodMetal4Backend(device: device, format: .bgra8Unorm_srgb)
        print("Runtime compiler and command queue: \(backend.name), \(device.name)")
        let x: [Float] = [19752, 32768, 45783, 55312, 58799, 55312, 45784, 32768, 19753, 10224, 6737, 10224, 23240, 36256, 45784, 42296, 29280, 19752, 32768].map { $0 / 65536 }
        let y: [Float] = [55312, 58799, 55312, 45784, 32768, 19753, 10224, 6737, 10224, 19752, 32768, 45783, 42296, 45784, 36256, 23240, 19752, 29280, 32768].map { $0 / 65536 }
        let size = 640

        func render(_ name: String, colors: [SIMD3<Float>], plus: Float = 0, minus: Float = 0) async throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw VPhoneHomePodMetalError.unavailable("No offscreen target.") }
            let leds = colors.enumerated().map { index, color in
                VPhoneHomePodMetalLED(position: SIMD4(x[index], y[index], 0, 0), color: SIMD4(color.x, color.y, color.z, 0))
            }
            let uniforms = VPhoneHomePodMetalUniforms(viewport: SIMD4(Float(size), Float(size), Float(size) / 2, Float(size) / 2), cap: SIMD4(304, Float(leds.count), plus, minus))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                do {
                    try backend.render(texture: texture, drawable: nil, uniforms: uniforms, leds: leds) { error in
                        if let error { continuation.resume(throwing: VPhoneHomePodMetalError.unavailable(error)) }
                        else { continuation.resume() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            var rgba = bytes
            for i in stride(from: 0, to: bytes.count, by: 4) { rgba[i] = bytes[i + 2]; rgba[i + 2] = bytes[i] }
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            return bytes
        }
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Int> {
            let offset = (y * size + x) * 4
            return SIMD3(Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
        }

        let dark = try await render("off", colors: Array(repeating: .zero, count: 19))
        let white = try await render("white", colors: Array(repeating: SIMD3(repeating: 0.75), count: 19), plus: 1, minus: 1)
        let colored = try await render("multicolor", colors: (0 ..< 19).map { i in
            let p = SIMD2(x[i] - 0.5, y[i] - 0.5)
            let angle = atan2(p.y, p.x)
            return SIMD3(0.30 + 0.28 * cos(angle), 0.28 + 0.26 * cos(angle + 2.1), 0.4 + 0.35 * cos(angle + 4.2))
        })
        let volume = try await render("volume", colors: (0 ..< 19).map { $0 >= 12 ? SIMD3(repeating: 0.7482) : .zero }, plus: 1, minus: 1)
        let red = try await render("red", colors: Array(repeating: SIMD3(0.65, 0, 0), count: 19))
        let redAgain = try await render("red-repeat", colors: Array(repeating: SIMD3(0.65, 0, 0), count: 19))
        precondition(red == redAgain, "An unchanged guest frame must not acquire host animation.")
        let centerDark = pixel(dark, 320, 320)
        let centerWhite = pixel(white, 320, 320)
        precondition(centerDark.max() < 24 && centerWhite.min() > 180, "Off/white optical output is incorrect.")
        let centerRed = pixel(red, 320, 320)
        precondition(centerRed.x > centerRed.y * 4 && centerRed.x > centerRed.z * 4, "RGB channels are crossed.")
        precondition(pixel(white, 320, 320).x > pixel(white, 320, 24).x + 100, "The opaque rim is missing.")
        precondition(pixel(white, 502, 320).x > pixel(dark, 502, 320).x + 120, "Independent plus illumination is missing.")
        precondition(pixel(volume, 320, 320).x > 100, "Neighbouring emitters did not blend through the diffuser.")
        precondition(colored != white && colored != dark)
        // Queue all three owned frame slots without waiting between submissions,
        // then repeat to exercise allocator reset and shared-input reuse.
        for _ in 0 ..< 8 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var remaining = 3
                var firstError: String?
                for channel in 0 ..< 3 {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
                    descriptor.storageMode = .shared
                    descriptor.usage = .renderTarget
                    let texture = device.makeTexture(descriptor: descriptor)!
                    var color = SIMD4<Float>.zero
                    color[channel] = 0.75
                    let leds = x.indices.map { VPhoneHomePodMetalLED(position: SIMD4(x[$0], y[$0], 0, 0), color: color) }
                    let uniforms = VPhoneHomePodMetalUniforms(viewport: SIMD4(640, 640, 320, 320), cap: SIMD4(304, 19, 0, 0))
                    do {
                        try backend.render(texture: texture, drawable: nil, uniforms: uniforms, leds: leds) { error in
                            firstError = firstError ?? error
                            var bytes = [UInt8](repeating: 0, count: size * size * 4)
                            texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
                            let center = pixel(bytes, 320, 320)
                            if center[channel] < 180 || center[(channel + 1) % 3] > 30 {
                                firstError = "In-flight frame inputs overlapped."
                            }
                            remaining -= 1
                            if remaining == 0 {
                                if let firstError { continuation.resume(throwing: VPhoneHomePodMetalError.unavailable(firstError)) }
                                else { continuation.resume() }
                            }
                        }
                    } catch {
                        firstError = error.localizedDescription
                        remaining -= 1
                        if remaining == 0 { continuation.resume(throwing: error) }
                    }
                }
            }
        }
        backend = try VPhoneHomePodMetalLegacyBackend(device: device, format: .bgra8Unorm_srgb)
        let compatible = try await render("metal3-compatibility", colors: Array(repeating: SIMD3(0.65, 0, 0), count: 19))
        precondition(zip(red, compatible).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "Compatibility rendering differs from Metal 4.")
        print("Metal 4 offscreen checks passed; PNGs: \(output.path)")
    }
}
