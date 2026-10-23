import Foundation
import Testing
@testable import VPhoneCoreKit

struct PCCGPUDriverTests {
    /// A bundle with the files `validateBundle` checks and `DTPlatformVersion` `version`.
    static func bundle(version: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "gpu-\(UUID().uuidString)/\(VPhonePCCGPUDriver.name)")
        try FileManager.default.createDirectory(at: url.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        try Data().write(to: url.appending(path: "AppleParavirtGPUMetalIOGPUFamily"))
        try Data().write(to: url.appending(path: "_CodeSignature/CodeResources"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.driver.AppleParavirtGPUMetalIOGPUFamily",
            "DTPlatformVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appending(path: "Info.plist"))
        return url
    }

    @Test func `a driver matches its cloud OS release, whatever the point release`() throws {
        let driver = try Self.bundle(version: "18.7")
        defer { try? FileManager.default.removeItem(at: driver.deletingLastPathComponent()) }
        try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.7.2")
        try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.7")
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "18.6")
        }
        #expect(throws: VPhonePCCGPUDriver.Error.self) {
            try VPhonePCCGPUDriver.validateBundle(at: driver, expectedPlatformVersion: "26.4")
        }
    }
}
