// CustomFirmwareMobileGestaltCacheTests.swift — the installer drops the guest's cached answers.
//
// `cfw install` and `cfw update-environment` remove the MobileGestalt cache
// from the mounted Data volume after a Preboot repair changed the device tree.
// These run the removal against a scratch folder standing in for that volume.

import Darwin
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit

@Suite("MobileGestalt cache removal")
struct CustomFirmwareMobileGestaltCacheTests {
    /// A canonical scratch folder: `data/` stands in for the Data volume,
    /// `outside/` for anything a link in it could point at.
    private struct Volume {
        let base: URL
        let data: URL
        let outside: URL

        init() throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            guard let resolved = realpath(temporary.path, nil) else { throw POSIXError(.ENOENT) }
            base = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            data = base.appendingPathComponent("data")
            outside = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        var cache: URL {
            data.appendingPathComponent(CustomFirmwareMobileGestaltCache.path)
        }

        func root() throws -> VPhoneConfinedDirectory {
            try VPhoneConfinedDirectory.pin(absolutePath: data.path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    // MARK: - Tests

    @Test func `the cache is removed and its folder kept`() throws {
        let volume = try Volume()
        defer { volume.remove() }
        let caches = volume.cache.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: volume.cache)
        try Data("other".utf8).write(to: caches.appendingPathComponent("other.plist"))

        #expect(try CustomFirmwareMobileGestaltCache.remove(fromDataVolume: volume.root()))
        #expect(!Self.exists(volume.cache))
        #expect(Self.exists(caches.appendingPathComponent("other.plist")))
    }

    @Test func `a guest that never booted has nothing to remove`() throws {
        let volume = try Volume()
        defer { volume.remove() }
        #expect(try !CustomFirmwareMobileGestaltCache.remove(fromDataVolume: volume.root()))

        // The folder without the file, as after a removal in the guest.
        try FileManager.default.createDirectory(
            at: volume.cache.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        #expect(try !CustomFirmwareMobileGestaltCache.remove(fromDataVolume: volume.root()))
    }

    @Test func `a link on the way is refused, not followed`() throws {
        let volume = try Volume()
        defer { volume.remove() }
        // `containers/Shared` points outside the volume, where a file sits at
        // the rest of the cache's path.
        let shared = volume.data.appendingPathComponent("containers/Shared")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: volume.outside)
        let rest = CustomFirmwareMobileGestaltCache.path.dropFirst("containers/Shared/".count)
        let target = volume.outside.appendingPathComponent(String(rest))
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("outside".utf8).write(to: target)

        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try CustomFirmwareMobileGestaltCache.remove(fromDataVolume: volume.root())
        }
        #expect(Self.exists(target))
    }

    @Test func `something other than a file at the path is left`() throws {
        let volume = try Volume()
        defer { volume.remove() }
        try FileManager.default.createDirectory(at: volume.cache, withIntermediateDirectories: true)

        #expect(try !CustomFirmwareMobileGestaltCache.remove(fromDataVolume: volume.root()))
        #expect(Self.exists(volume.cache))
    }
}
