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

    /// kmutil records the absolute path of every codeless kext, so the length of
    /// the volume's path decides where `__PRELINK_INFO` ends and every page after
    /// it. The link gives it the length of the build root Apple linked the base
    /// with, read from the base itself: the output then depends on nothing about
    /// this Mac, and the base rebuilt from its own extraction is Apple's
    /// kernelcache byte for byte, apart from the CPU subtype.
    static func buildRootLength(of payload: Data) throws -> Int {
        let key = Data("<key>_CodelessKextBundlePath</key>".utf8)
        guard let keyRange = payload.range(of: key),
              let open = payload.range(of: Data("<string>".utf8), in: keyRange.upperBound ..< payload.endIndex),
              let extensions = payload.range(of: Data("/System/Library/Extensions/".utf8), in: open.upperBound ..< min(open.upperBound + 2048, payload.endIndex))
        else {
            throw PatcherError.invalidFormat("the base kernelcache records no codeless kext path to take its build root from")
        }
        return extensions.lowerBound - open.upperBound
    }

    /// Bump when the steps change, so cached mixes are rebuilt.
    static let revision = 3

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

    /// A research board kernelcache to rebuild, and the guest it boots.
    public struct Input {
        /// The kernelcache as shipped (IM4P or decompressed).
        public let kernelcache: Data
        /// `VPhoneGuestDevice.Family` raw value of the guest.
        public let guest: String
        /// The VM's restore tree, which holds a donor the guest's IPSW ships.
        public let restoreTree: URL

        public init(kernelcache: Data, guest: String, restoreTree: URL) {
            self.kernelcache = kernelcache
            self.guest = guest
            self.restoreTree = restoreTree
        }
    }

    public func base(for input: Input) throws -> KernelCacheBase {
        if let base = try recipes.base(forKernelcache: input.kernelcache, guest: input.guest) {
            return base
        }
        let supported = (try? recipes.bases().map { ($0.guest.map { "\($0) " } ?? "iOS ") + $0.id }.joined(separator: ", ")) ?? "none"
        throw PatcherError.invalidFormat(
            "this cloudOS has no vphone600 components, and no kernelcache recipe covers its research board kernelcache "
                + "(SHA-256 \(KernelCacheRecipes.sha256(input.kernelcache))) for this \(input.guest) guest "
                + "to rebuild with the virtualisation kexts; recipes exist for \(supported)",
        )
    }

    /// The recipe for the research board kernelcache `restoreDir` restores
    /// with. `fw prepare` asks, so a cloudOS no recipe covers is refused before
    /// anything is patched.
    public static func recipe(forRestoreTree restoreDir: URL) throws -> KernelCacheBase {
        try KernelCacheMixer(recipes: .locate(), verbose: false).base(for: input(forRestoreTree: restoreDir))
    }

    /// Throws what `mix` would for `restoreDir`, without building anything.
    /// `vm create` asks as soon as `fw prepare` finds the recipe, not at
    /// `fw patch` after the restores.
    public static func checkMixable(restoreTree restoreDir: URL) throws {
        let input = try Self.input(forRestoreTree: restoreDir)
        let mixer = try KernelCacheMixer(recipes: .locate(), verbose: false)
        let state = try mixer.state(for: input)
        guard state != .mixed else { return }
        try KernelCollectionBuilder.checkLayout(for: mixer.locations(for: input).base)
        guard geteuid() == 0 else {
            throw PatcherError.invalidFormat(linkInstructions(staged: state == .staged))
        }
        if state == .missing {
            _ = try ipsw()
        }
    }

    static func input(forRestoreTree restoreDir: URL) throws -> Input {
        let path = try FirmwarePipeline.manifestComponentPath("RestoreKernelCache", in: restoreDir)
        let data = try Data(contentsOf: restoreDir.appending(path: path), options: .mappedIfSafe)
        return Input(kernelcache: data, guest: FirmwarePipeline.guestFamily(restoreDir: restoreDir), restoreTree: restoreDir)
    }

    // MARK: - Mix

    /// What becomes of a research board kernelcache in the cache.
    public enum State: Equatable, Sendable {
        /// Linked: `fw patch` takes it from the cache.
        case mixed
        /// Extracted and staged; linking it needs root.
        case staged
        /// Neither yet.
        case missing
    }

    public func state(for input: Input) throws -> State {
        let (_, paths) = try locations(for: input)
        if FileManager.default.fileExists(atPath: paths.mixed.path) {
            return .mixed
        }
        return Self.isStaged(paths.staged) ? .staged : .missing
    }

    /// The mixed kernelcache (an IMG4 `krnl` container) for a research board
    /// one: from the cache, linked from a staged volume (root), or staged and
    /// linked in one go (root with `VPHONE_IPSW`).
    public func mix(_ input: Input) throws -> Data {
        let (base, paths) = try locations(for: input)
        log("  [kc] base \(base.id) (\(base.productVersion)), donors \(base.donors.joined(separator: ", "))")
        if let data = try? Data(contentsOf: paths.mixed), !data.isEmpty {
            log("  [kc] using the cached mix \(paths.mixed.path)")
            return data
        }
        guard geteuid() == 0 else {
            throw PatcherError.invalidFormat(Self.linkInstructions(staged: Self.isStaged(paths.staged)))
        }
        if !Self.isStaged(paths.staged) {
            try stage(input)
        }
        return try link(input)
    }

    /// Extracts both kernelcaches and stages the volume kmutil links, as the
    /// invoking user: the one step that runs `ipsw`. Does nothing when the mix
    /// or its volume is already in the cache.
    public func stage(_ input: Input, ipsw ipswPath: String? = nil) throws {
        let (base, paths) = try locations(for: input)
        guard !FileManager.default.fileExists(atPath: paths.mixed.path), !Self.isStaged(paths.staged) else { return }
        try KernelCollectionBuilder.checkLayout(for: base)
        let donors = try base.donors.map { try recipes.donor(id: $0) }
        let ipsw = try Self.ipsw(ipswPath)

        let fm = FileManager.default
        try? fm.removeItem(at: paths.staged)
        let work = paths.staged.appending(path: "work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("  [kc] staging in \(paths.staged.path)")

        let donorKDKs = try donors.map { try donorKDK($0, restoreTree: input.restoreTree, ipsw: ipsw) }
        let payload = try Self.payload(of: input.kernelcache)
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
        let sources = base.kextSources.map { source in
            base.donors.firstIndex(of: source).map { donorKDKs[$0] } ?? baseKDK
        }
        let (removed, added) = try KernelCacheKDK.mix(base: baseKDK, sources: sources, wanted: identifiers, output: mixKDK)
        let addedText = zip(donors, donorKDKs).map { "\(added[$1]?.count ?? 0) from \($0.id)" }.joined(separator: ", ")
        log("  [kc] mix: \(identifiers.count) kexts, \(removed.count) research board kexts removed, \(addedText)")
        try KernelCacheKDK.makeVolume(kdk: mixKDK, identifiers: identifiers, output: paths.staged.appending(path: "volume"))
        try fm.removeItem(at: work)
        try Data(ipsw.hash.utf8).write(to: paths.staged.appending(path: "ipsw.sha256"))
        try Data().write(to: paths.staged.appending(path: Self.stagedMarker))
        // Under sudo, so the user's later runs can replace it.
        if geteuid() == 0 {
            try VPhoneHostFilePermissions.makeAccessible(at: cacheDirectory)
        }
        log("  [kc] staged; linking needs root")
    }

    /// Links a staged volume, as root, and caches the result. Runs no `ipsw`:
    /// the volume is copied into a directory only root can reach, with nothing
    /// in it that points outside, and kmutil links that copy.
    @discardableResult
    public func link(_ input: Input) throws -> Data {
        let (base, paths) = try locations(for: input)
        if let data = try? Data(contentsOf: paths.mixed), !data.isEmpty {
            return data
        }
        try KernelCollectionBuilder.checkLayout(for: base)
        guard geteuid() == 0 else {
            throw PatcherError.invalidFormat(Self.linkInstructions(staged: Self.isStaged(paths.staged)))
        }
        guard Self.isStaged(paths.staged) else {
            throw PatcherError.fileNotFound("the staged \(base.id) kernelcache volume in \(paths.staged.path); run `vphone-cli fw kernelcache` with \(Self.ipswEnvironmentVariable) first")
        }

        let payload = try Self.payload(of: input.kernelcache)
        let copy = try KernelCacheVolumeCopy(
            staged: paths.staged.appending(path: "volume"), kdk: base.kernel.kdk, pathLength: Self.buildRootLength(of: payload),
        )
        defer { copy.remove() }
        log("  [kc] linking with kmutil")
        let identifiers = try base.kextIdentifiers()
        let kmutilLog = copy.root.appending(path: "kmutil.log")
        // Beside the mix, whether the link worked or not: kmutil leaves out a
        // kext it does not accept without failing.
        defer {
            if let text = try? Data(contentsOf: kmutilLog) {
                try? storeMix(text, at: paths.mixed.deletingPathExtension().appendingPathExtension("kmutil.log"))
            }
        }
        var output = try KernelCollectionBuilder.link(
            volume: copy.volume, kernel: copy.kernel, identifiers: identifiers, log: kmutilLog,
        )
        output = try finalize(output, original: payload, identifiers: identifiers, work: copy.root)
        try storeMix(output, at: paths.mixed)
        log("  [kc] mixed kernelcache: \(output.count) bytes, cached at \(paths.mixed.path)")
        return output
    }

    // MARK: - Cache

    static let stagedMarker = ".staged"

    static func isStaged(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: stagedMarker).path)
    }

    /// The recipe and where its mix and staged volume are kept.
    func locations(for input: Input) throws -> (base: KernelCacheBase, paths: (mixed: URL, staged: URL)) {
        let base = try base(for: input)
        let key = try cacheKey(base: base, donors: base.donors.map { try recipes.donor(id: $0) })
        return (base, (
            cacheDirectory.appending(path: "mix/\(base.id)/\(key).im4p"),
            cacheDirectory.appending(path: "staged/\(base.id)/\(key)"),
        ))
    }

    /// Writes the mix into the invoking user's cache without following a link:
    /// root writes there.
    func storeMix(_ data: Data, at url: URL) throws {
        let user = VPhoneInvokingUser.current
        let cache = cacheDirectory.standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let root = try VPhoneConfinedDirectory.pin(absolutePath: cache)
        let relative = String(url.standardizedFileURL.path.dropFirst(cache.count + 1))
        let (directory, leaf) = try root.parent(of: relative, create: true)
        try directory.writeFile(leaf, contents: data, mode: 0o644, owner: user.map { ($0.uid, $0.gid) })
    }

    public static func linkInstructions(staged: Bool) -> String {
        let link = "sudo vphone-cli fw kernelcache <vm>"
        return staged
            ? "the kernelcache mix is staged; linking it needs root (kmutil only reads kexts owned by root). Run `\(link)`, or this command with sudo."
            : "the kernelcache mix is not built yet. Stage it with `\(ipswEnvironmentVariable)=<ipsw> vphone-cli fw kernelcache <vm>`, then link it with `\(link)`, or run this command as `sudo \(ipswEnvironmentVariable)=<ipsw> vphone-cli ...`."
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
    func donorKDK(_ donor: KernelCacheDonor, restoreTree: URL, ipsw: (url: URL, hash: String)) throws -> URL {
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
        let payload = try Self.payload(of: donorKernelcache(donor, in: directory, restoreTree: restoreTree))
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

    /// The donor kernelcache: from the guest's restore tree for one its IPSW
    /// ships, else kept in `directory` once read from its cloudOS IPSW, of
    /// which only that one entry is downloaded.
    func donorKernelcache(_ donor: KernelCacheDonor, in directory: URL, restoreTree: URL) throws -> Data {
        guard let cloudOSSource = donor.cloudOSSource else {
            let data = try Data(contentsOf: restoreTree.appending(path: donor.kernel.file), options: .mappedIfSafe)
            guard donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) else {
                throw PatcherError.invalidFormat("the guest's \(donor.kernel.file) does not match the \(donor.id) recipe")
            }
            return data
        }
        let local = directory.appending(path: donor.kernel.file)
        if let data = try? Data(contentsOf: local), donor.kernel.matches(sha: KernelCacheRecipes.sha256(data)) {
            return data
        }
        guard let source = URL(string: cloudOSSource) else {
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

    /// What decides the output: the kernelcaches, maps and bundle list, the
    /// layout and this file's steps. Not the ipsw, which the root link does not
    /// run: a stage records which one made it (`ipsw.sha256`), and removing
    /// `~/.vphone/kernelcache` rebuilds everything.
    func cacheKey(base: KernelCacheBase, donors: [KernelCacheDonor]) throws -> String {
        var material = Data("\(Self.identity(base.kernel))|".utf8)
        for donor in donors {
            material += Data("\(Self.identity(donor.kernel))|".utf8)
        }
        for url in [base.symbolsURL, base.kextsURL] + donors.compactMap(\.symbolsURL) {
            material += try Data(contentsOf: url)
        }
        material += Data("\(Self.revision)|\(base.builderLayout.rawValue)".utf8)
        // A recipe with its own source order is keyed on it too.
        if base.sources != nil {
            material += Data("|\(base.kextSources.joined(separator: ","))".utf8)
        }
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

    /// The `ipsw` given, or else named by `VPHONE_IPSW`, with `kernel extract --kdk`.
    static func ipsw(_ given: String? = nil) throws -> (url: URL, hash: String) {
        let hint = "The kernelcache mix needs an ipsw with `kernel extract --kdk`; set \(ipswEnvironmentVariable) to its path "
            + "(under sudo: `sudo \(ipswEnvironmentVariable)=<path> vphone-cli ...`)."
        guard let path = given ?? ProcessInfo.processInfo.environment[ipswEnvironmentVariable], !path.isEmpty else {
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
