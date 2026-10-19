// KernelCacheMixer.swift — A vphone600-capable kernelcache from the research board's.
//
// A cloudOS without vphone600 components ships only the research board's
// kernelcache, which lacks the iPhone virtualisation kexts (paravirtual GPU,
// touch, audio, FairPlay, ...). The mix:
//
//   1. extracts the donor kernelcache, the vphone600 one of the 26.4 beta
//      cloudOS, into a KDK, naming its stripped symbols from the recipe's map
//      (cached);
//   2. extracts the base, the cloudOS's `kernelcache.release.vresearch101`, the
//      same way;
//   3. keeps the recipe's bundle list: the base without its research-board-only
//      kexts, plus the donor's virtualisation kexts;
//   4. stages the bundles as a volume and links it with kmutil;
//   5. restores Apple's CPU subtype if the builder wrote another, checks every
//      bundle was linked, and caches the result.
//
// The maps are research results: BinDiff symbolication against a symbolicated
// KDK of the same family, plus verified fixes (see the README beside the
// recipes). Extracting needs an `ipsw` with `kernel extract --kdk`, which
// vphone-cli does not ship: `VPHONE_IPSW` names it.

import Foundation
import Img4tool
import VPhoneCoreKit
import VPhonePatchKit

public final class KernelCacheMixer {
    let recipes: KernelCacheRecipes
    let cacheDirectory: URL
    let verbose: Bool

    /// The length of Apple's build volume name. kmutil records the plug-in
    /// paths, and the `__PRELINK_INFO` page rounding then matches Apple's builds.
    static let volumeName = String(repeating: "b", count: 170)

    /// Bump when the steps change, so cached mixes are rebuilt.
    static let revision = 1

    public static let ipswEnvironmentVariable = "VPHONE_IPSW"

    public init(
        recipes: KernelCacheRecipes,
        cacheDirectory: URL = VPhoneResources.userDataRoot().appending(path: "kernelcache"),
        verbose: Bool = true,
    ) {
        self.recipes = recipes
        self.cacheDirectory = cacheDirectory
        self.verbose = verbose
    }

    // MARK: - Identification

    public func base(for kernelcache: Data) throws -> KernelCacheBase {
        if let base = try recipes.base(forKernelcache: kernelcache) {
            return base
        }
        let supported = (try? recipes.bases().map(\.id).joined(separator: ", ")) ?? "none"
        throw PatcherError.invalidFormat(
            "this cloudOS has no vphone600 components, and no kernelcache recipe covers its research board kernelcache "
                + "(SHA-256 \(KernelCacheRecipes.sha256(kernelcache))) to rebuild with the virtualisation kexts; "
                + "recipes exist for iOS \(supported)",
        )
    }

    /// The recipe for the research board kernelcache `restoreDir` restores
    /// with. `fw prepare` asks, so a cloudOS no recipe covers is refused before
    /// anything is patched.
    public static func recipe(forRestoreTree restoreDir: URL) throws -> KernelCacheBase {
        try KernelCacheMixer(recipes: .locate(), verbose: false).base(for: kernelcache(inRestoreTree: restoreDir))
    }

    /// Throws what `mix` would for `restoreDir`, without building anything.
    /// `vm create` asks as soon as `fw prepare` finds the recipe, not at
    /// `fw patch` after the restores.
    public static func checkMixable(restoreTree restoreDir: URL) throws {
        let mixer = try KernelCacheMixer(recipes: .locate(), verbose: false)
        let base = try mixer.base(for: kernelcache(inRestoreTree: restoreDir))
        let cached = try mixer.cachedMix(base: base, ipsw: ipsw())
        if !FileManager.default.fileExists(atPath: cached.path) {
            try KernelCollectionBuilder.checkHost(for: base)
        }
    }

    static func kernelcache(inRestoreTree restoreDir: URL) throws -> Data {
        let path = try FirmwarePipeline.manifestComponentPath("RestoreKernelCache", in: restoreDir)
        return try Data(contentsOf: restoreDir.appending(path: path), options: .mappedIfSafe)
    }

    // MARK: - Mix

    /// The mixed kernelcache (an IMG4 `krnl` container) for a research board one.
    public func mix(kernelcache: Data) throws -> Data {
        let base = try base(for: kernelcache)
        let donor = try recipes.donor(id: base.donor)
        let ipsw = try Self.ipsw()
        let cached = try cachedMix(base: base, ipsw: ipsw)
        log("  [kc] base \(base.id) (iOS \(base.productVersion)), donor \(donor.id)")
        if let data = try? Data(contentsOf: cached), !data.isEmpty {
            log("  [kc] using the cached mix \(cached.path)")
            return data
        }
        try KernelCollectionBuilder.checkHost(for: base)

        // A directory per run: a failed run keeps its logs.
        let fm = FileManager.default
        let workRoot = cacheDirectory.appending(path: "work")
        for stale in (try? fm.contentsOfDirectory(atPath: workRoot.path)) ?? [] where stale.hasPrefix(base.id + ".") {
            try? fm.removeItem(at: workRoot.appending(path: stale))
        }
        let work = workRoot.appending(path: "\(base.id).\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("  [kc] work directory \(work.path)")

        let donorKDK = try donorKDK(donor, ipsw: ipsw)

        let payload = try Self.payload(of: kernelcache)
        try Self.check(payload, base.kernel.decompressedSHA256, "decompressed \(base.kernel.file)")
        let decompressed = work.appending(path: "\(base.kernel.file).decompressed")
        try payload.write(to: decompressed)
        log("  [kc] extracting the base kernelcache with its symbol map")
        let baseKDK = try extract(
            kernelcache: decompressed, symbols: base.symbolsURL, kdk: base.kernel.kdk,
            into: work.appending(path: "base"), ipsw: ipsw.url,
        )

        let identifiers = try base.kextIdentifiers()
        let mixKDK = work.appending(path: "mix/\(base.kernel.kdk)")
        let (removed, added) = try KernelCacheKDK.mix(base: baseKDK, donor: donorKDK, wanted: identifiers, output: mixKDK)
        log("  [kc] mix: \(identifiers.count) kexts, \(removed.count) research board kexts removed, \(added.count) added from the donor")

        let volume = work.appending(path: "volume/\(Self.volumeName)")
        let kernel = try KernelCacheKDK.makeVolume(kdk: mixKDK, identifiers: identifiers, output: volume)
        log("  [kc] linking with kmutil")
        var output = try KernelCollectionBuilder.link(
            volume: volume, kernel: kernel, identifiers: identifiers, log: work.appending(path: "kmutil.log"),
        )

        output = try finalize(output, original: payload, identifiers: identifiers, work: work)
        try fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: cached)
        try? fm.removeItem(at: work)
        try VPhoneHostFilePermissions.makeAccessible(at: cacheDirectory)
        log("  [kc] mixed kernelcache: \(output.count) bytes, cached at \(cached.path)")
        return output
    }

    // MARK: - Steps

    /// Puts back Apple's CPU subtype (the 26.x builder writes 0xc0000002 where
    /// some kernelcaches have 0x2) and checks every requested bundle was linked.
    func finalize(_ im4pData: Data, original: Data, identifiers: [String], work: URL) throws -> Data {
        guard let im4p = try? IM4P(im4pData) else {
            throw PatcherError.invalidFormat("kmutil's output is not an IM4P container")
        }
        var payload = try im4p.payload()
        guard payload.count > 12, original.count > 12, payload.prefix(4) == original.prefix(4) else {
            throw PatcherError.invalidFormat("kmutil's output is not a Mach-O kernel collection")
        }
        let missing = identifiers.filter { payload.range(of: Data(">\($0)<".utf8)) == nil }
        guard missing.isEmpty else {
            throw PatcherError.invalidFormat("kexts missing from the linked kernelcache: \(missing.joined(separator: ", "))")
        }
        let start = payload.startIndex
        let subtype = payload[start + 8 ..< start + 12]
        let wanted = original[original.startIndex + 8 ..< original.startIndex + 12]
        guard subtype != wanted else { return im4pData }
        log("  [kc] restoring CPU subtype \(Data(wanted).hex) (the builder wrote \(Data(subtype).hex))")
        payload.replaceSubrange(start + 8 ..< start + 12, with: wanted)
        let url = work.appending(path: "subtype.im4p")
        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: url)
        return try Data(contentsOf: url)
    }

    /// `ipsw kernel extract --kdk` into `directory`, returning the KDK named
    /// `kdk`. A kernelcache whose kexts carry no `DTPlatformBuild` gives
    /// `KDK_<version>_.kdk`; the recipe supplies the build.
    func extract(kernelcache: URL, symbols: URL?, kdk: String, into directory: URL, ipsw: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(path: "extract.log")
        var arguments = ["kernel", "extract", "--kdk", "--force"]
        if let symbols {
            let compressed = directory.appending(path: "symbols.json.gz")
            try fm.copyItem(at: symbols, to: compressed)
            try Self.run("/usr/bin/gzip", ["-d", compressed.path], log: log)
            arguments += ["--symbols", directory.appending(path: "symbols.json").path]
        }
        arguments += [kernelcache.path, "-o", directory.path]
        try Self.run(ipsw.path, arguments, environment: ["NO_COLOR": "1"], log: log)

        let produced = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("KDK_") && $0.hasSuffix(".kdk") }
        guard produced.count == 1, let name = produced.first else {
            throw PatcherError.fileNotFound("the KDK `ipsw kernel extract --kdk` wrote into \(directory.path) (found \(produced))")
        }
        var url = directory.appending(path: name)
        if name != kdk {
            let parts = kdk.dropFirst(4).dropLast(4).split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count == 2, name == "KDK_\(parts[0])_.kdk" else {
                throw PatcherError.invalidFormat("extracted \(name), the recipe expects \(kdk)")
            }
            let systemVersion = url.appending(path: "System/Library/CoreServices/SystemVersion.plist")
            var plist = try KernelCacheKDK.plist(at: systemVersion)
            plist["ProductBuildVersion"] = String(parts[1])
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: systemVersion)
            let renamed = directory.appending(path: kdk)
            try fm.moveItem(at: url, to: renamed)
            url = renamed
        }
        return url
    }

    /// The donor's KDK, extracted once into `donors/<id>`.
    func donorKDK(_ donor: KernelCacheDonor, ipsw: (url: URL, hash: String)) throws -> URL {
        let fm = FileManager.default
        let directory = cacheDirectory.appending(path: "donors/\(donor.id)")
        let kdk = directory.appending(path: "extract/\(donor.kernel.kdk)")
        let marker = directory.appending(path: "extract/.complete")
        var keyMaterial = Data(Self.identity(donor.kernel).utf8)
        if let symbols = donor.symbolsURL {
            keyMaterial += try Data(contentsOf: symbols)
        }
        keyMaterial += Data(ipsw.hash.utf8)
        let key = KernelCacheRecipes.sha256(keyMaterial)
        if (try? String(contentsOf: marker, encoding: .utf8)) == key, fm.fileExists(atPath: kdk.path) {
            log("  [kc] using the cached donor KDK \(kdk.path)")
            return kdk
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = try Self.payload(of: donorKernelcache(donor, in: directory))
        try Self.check(payload, donor.kernel.decompressedSHA256, "decompressed donor \(donor.kernel.file)")
        let decompressed = directory.appending(path: "\(donor.kernel.file).decompressed")
        try payload.write(to: decompressed)
        defer { try? fm.removeItem(at: decompressed) }
        log("  [kc] extracting the donor kernelcache \(donor.id)")
        let extracted = try extract(
            kernelcache: decompressed, symbols: donor.symbolsURL, kdk: donor.kernel.kdk,
            into: directory.appending(path: "extract"), ipsw: ipsw.url,
        )
        try key.write(to: marker, atomically: true, encoding: .utf8)
        return extracted
    }

    /// The donor kernelcache, kept in `directory` once read from its cloudOS
    /// IPSW. Only that one entry is downloaded.
    func donorKernelcache(_ donor: KernelCacheDonor, in directory: URL) throws -> Data {
        let local = directory.appending(path: donor.kernel.file)
        if let data = try? Data(contentsOf: local), donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) {
            return data
        }
        guard let source = URL(string: donor.cloudOSSource) else {
            throw PatcherError.invalidFormat("the \(donor.id) recipe has no valid cloudOS URL")
        }
        log("  [kc] reading \(donor.kernel.file) from \(source.absoluteString)")
        let file = donor.kernel.file
        let data = try vphoneRunBlocking {
            let zip = try await VPhoneRemoteZip.open(source)
            return try await zip.read(zip.entry(endingWith: file))
        }
        guard donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) else {
            throw PatcherError.invalidFormat("the downloaded \(file) does not match the \(donor.id) recipe")
        }
        try data.write(to: local)
        return data
    }

    // MARK: - Helpers

    /// Where the mix of `base` is cached.
    func cachedMix(base: KernelCacheBase, ipsw: (url: URL, hash: String)) throws -> URL {
        let key = try cacheKey(base: base, donor: recipes.donor(id: base.donor), ipswHash: ipsw.hash)
        return cacheDirectory.appending(path: "mix/\(base.id)/\(key).im4p")
    }

    /// Everything that decides the output: the kernelcaches, maps and bundle
    /// list, the extracting ipsw, the layout and this file's steps.
    func cacheKey(base: KernelCacheBase, donor: KernelCacheDonor, ipswHash: String) throws -> String {
        var material = Data("\(Self.identity(base.kernel))|\(Self.identity(donor.kernel))|".utf8)
        for url in [base.symbolsURL, base.kextsURL] + (donor.symbolsURL.map { [$0] } ?? []) {
            material += try Data(contentsOf: url)
        }
        material += Data("\(Self.revision)|\(ipswHash)|\(base.builderLayout.rawValue)|\(Self.volumeName.count)".utf8)
        return String(KernelCacheRecipes.sha256(material).prefix(16))
    }

    static func identity(_ kernel: KernelCacheFile) -> String {
        "\(kernel.file)|\(kernel.sha256)|\(kernel.decompressedSHA256)|\(kernel.kdk)"
    }

    static func check(_ data: Data, _ sha: String, _ what: String) throws {
        let actual = KernelCacheRecipes.sha256(data)
        guard actual == sha else {
            throw PatcherError.invalidFormat("\(what): SHA-256 \(actual), the recipe expects \(sha)")
        }
    }

    static func payload(of data: Data) throws -> Data {
        if let im4p = try? IM4P(data) {
            return try im4p.payload()
        }
        return data
    }

    /// The `ipsw` named by `VPHONE_IPSW`, with `kernel extract --kdk`.
    static func ipsw() throws -> (url: URL, hash: String) {
        let hint = "The kernelcache mix needs an ipsw with `kernel extract --kdk`; set \(ipswEnvironmentVariable) to its path "
            + "(under sudo: `sudo \(ipswEnvironmentVariable)=<path> vphone-cli ...`)."
        guard let path = ProcessInfo.processInfo.environment[ipswEnvironmentVariable], !path.isEmpty else {
            throw PatcherError.fileNotFound("ipsw. \(hint)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let help = try? VPhoneProcessRunner.runCapturing(url, ["kernel", "extract", "--help"]),
              help.stdout.contains("--kdk"), help.stdout.contains("--symbols")
        else {
            throw PatcherError.invalidFormat("\(path) is not an ipsw with `kernel extract --kdk --symbols`. \(hint)")
        }
        // Its own hash, not `ipsw version`, which a local build leaves empty.
        let binary = try Data(contentsOf: url, options: .mappedIfSafe)
        return (url, KernelCacheRecipes.sha256(binary))
    }

    /// Runs a tool with its output in `log`, which a failure quotes the end of.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], log: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: log.path) {
            fm.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            throw PatcherError.invalidFormat("\((executable as NSString).lastPathComponent) failed with exit code \(process.terminationStatus) (log: \(log.path)):\n\(tail)")
        }
    }

    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
