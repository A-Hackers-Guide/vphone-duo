@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// The shipped kernelcache recipes, and the steps of the mix that need no
/// root, kmutil or ipsw.
@Suite("Kernelcache mix")
struct KernelCacheMixerTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let recipes = KernelCacheRecipes(
        root: repoRoot.appending(path: "VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes"),
    )

    // MARK: - Recipes

    @Test("Every recipe has its map, its bundle list and its donor")
    func recipesAreComplete() throws {
        let bases = try Self.recipes.bases()
        #expect(bases.map(\.productVersion) == ["26.4", "26.5", "26.6", "26.7"])
        for base in bases {
            #expect(FileManager.default.fileExists(atPath: base.symbolsURL.path), "\(base.id)")
            let identifiers = try base.kextIdentifiers()
            #expect(identifiers.count > 100, "\(base.id)")
            #expect(Set(identifiers).count == identifiers.count, "\(base.id)")
            #expect(base.builderLayout == .kernelLast, "\(base.id)")
            let donor = try Self.recipes.donor(id: base.donor)
            #expect(donor.symbolsURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(URL(string: donor.cloudOSSource)?.scheme == "https")
        }
    }

    @Test("A kernelcache is matched by the SHA-256 of its container or of its payload, and nothing else")
    func matchesByHash() throws {
        let base = try #require(try Self.recipes.bases().first)
        let mixer = KernelCacheMixer(recipes: Self.recipes, verbose: false)
        #expect(throws: PatcherError.self) { try mixer.base(for: Data("not a kernelcache".utf8)) }
        #expect(base.kernel.matches(sha: base.kernel.sha256))
        #expect(base.kernel.matches(sha: base.kernel.decompressedSHA256))
        #expect(!base.kernel.matches(sha: String(repeating: "0", count: 64)))
    }

    @Test("A mix is keyed by its recipe alone, which the root link can compute without ipsw")
    func cacheKeyFollowsRecipe() throws {
        let bases = try Self.recipes.bases()
        let mixer = KernelCacheMixer(recipes: Self.recipes, verbose: false)
        let keys = try bases.map { try mixer.cacheKey(base: $0, donor: Self.recipes.donor(id: $0.donor)) }
        #expect(Set(keys).count == bases.count)
        let first = try #require(bases.first)
        #expect(try mixer.cacheKey(base: first, donor: Self.recipes.donor(id: first.donor)) == keys.first)
    }

    @Test("The volume path takes the length of the build root the base records")
    func buildRootLength() throws {
        let root = "/AppleInternal/Library/BuildRoots/4~X/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.6.Internal.sdk"
        let prelink = "<dict><key>_CodelessKextBundlePath</key><string>\(root)/System/Library/Extensions/A.kext</string></dict>"
        #expect(try KernelCacheMixer.buildRootLength(of: Data(repeating: 0, count: 64) + Data(prelink.utf8)) == root.count)
        #expect(throws: PatcherError.self) { try KernelCacheMixer.buildRootLength(of: Data("no prelink info".utf8)) }
    }

    @Test("macOS 26.4 is the first builder that links kernel-last")
    func builderLayout() {
        func layout(_ major: Int, _ minor: Int) -> KernelCacheBase.BuilderLayout {
            KernelCollectionBuilder.layout(forMacOS: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        #expect(layout(15, 6) == .kernelFirst)
        #expect(layout(26, 3) == .kernelFirst)
        #expect(layout(26, 4) == .kernelLast)
        #expect(layout(27, 0) == .kernelLast)
    }

    // MARK: - KDK

    /// A KDK with one kext per identifier, `<name>.kext/Info.plist` and an executable.
    static func kdk(at url: URL, kexts: [String: String]) throws {
        let extensions = url.appending(path: "System/Library/Extensions")
        for (identifier, path) in kexts {
            let bundle = extensions.appending(path: path)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".kext", with: "")
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appending(path: "Info.plist"))
            try Data(identifier.utf8).write(to: bundle.appending(path: name))
        }
        let coreServices = url.appending(path: "System/Library/CoreServices")
        try FileManager.default.createDirectory(at: coreServices, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["ProductVersion": "26.6", "ProductBuildVersion": "23G71"], format: .xml, options: 0,
        ).write(to: coreServices.appending(path: "SystemVersion.plist"))
        let kernels = url.appending(path: "System/Library/Kernels")
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try Data("kernel".utf8).write(to: kernels.appending(path: "kernel"))
    }

    @Test("The mix keeps the wanted base kexts, drops the others and adds the donor's")
    func mixesKDKs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appending(path: "base/KDK_26.6_23G71.kdk")
        let donor = root.appending(path: "donor/KDK_26.4_23E5207i.kdk")
        try Self.kdk(at: base, kexts: [
            "com.apple.kept": "Kept.kext",
            "com.apple.research.only": "ResearchOnly.kext",
            "com.apple.plugin": "ResearchOnly.kext/PlugIns/Plugin.kext",
        ])
        try Self.kdk(at: donor, kexts: [
            "com.apple.kept": "Kept.kext",
            "com.apple.driver.AppleParavirtGPU": "AppleParavirtGPU.kext",
        ])
        let wanted = ["com.apple.kept", "com.apple.plugin", "com.apple.driver.AppleParavirtGPU"]
        let output = root.appending(path: "mix/KDK_26.6_23G71.kdk")
        let (removed, added) = try KernelCacheKDK.mix(base: base, donor: donor, wanted: wanted, output: output)
        #expect(removed.isEmpty) // the research-only parent stays for its wanted plug-in, without its own Info.plist
        #expect(added == ["com.apple.driver.AppleParavirtGPU"])
        #expect(Set(try KernelCacheKDK.bundles(in: output).keys) == Set(wanted))

        let volume = root.appending(path: "volume")
        let kernel = try KernelCacheKDK.makeVolume(kdk: output, identifiers: wanted, output: volume)
        #expect(kernel.path.hasSuffix("Library/Developer/KDKs/KDK_26.6_23G71.kdk/System/Library/Kernels/kernel"))
        #expect(Set(try KernelCacheKDK.bundles(in: volume).keys) == Set(wanted))

        #expect(throws: PatcherError.self) {
            try KernelCacheKDK.mix(base: base, donor: donor, wanted: wanted + ["com.apple.nowhere"], output: output)
        }

        // The staged volume root links holds no link but the KDK's own.
        try KernelCacheVolumeCopy.checkLinks(in: volume, kdk: "KDK_26.6_23G71.kdk")
        try FileManager.default.createSymbolicLink(
            atPath: volume.appending(path: "System/Library/Extensions/Kept.kext/Kept2").path,
            withDestinationPath: "/etc/master.passwd",
        )
        #expect(throws: PatcherError.self) {
            try KernelCacheVolumeCopy.checkLinks(in: volume, kdk: "KDK_26.6_23G71.kdk")
        }
    }
}
