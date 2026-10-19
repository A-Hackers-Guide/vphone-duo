// KernelCacheRecipes.swift — What a kernelcache mix is built from.
//
// `Contents/Resources/kernelcache_recipes` holds one directory per supported
// base, the research board's kernelcache of a cloudOS without vphone600
// components, and one per donor of the iPhone virtualisation kexts. See the
// README there for the layout and how a recipe is made.

import CryptoKit
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// A kernelcache a recipe names, identified by its SHA-256.
public struct KernelCacheFile: Decodable, Sendable {
    /// File name in the cloudOS restore tree.
    public let file: String
    /// SHA-256 of the IM4P container as shipped.
    public let sha256: String
    /// SHA-256 of the decompressed kernel collection.
    public let decompressedSHA256: String
    /// The KDK `ipsw kernel extract --kdk` makes of it.
    public let kdk: String

    func matches(sha: String) -> Bool {
        sha == sha256 || sha == decompressedSHA256
    }
}

/// One base kernelcache (`bases/<id>/manifest.json`).
public struct KernelCacheBase: Decodable, Sendable {
    /// Where the kernel collection builder puts the kernel's `__TEXT_EXEC`. The
    /// builder of macOS 26.4 and later puts it after the kexts, older ones
    /// before them, and a kernel only boots in the layout Apple linked it with.
    public enum BuilderLayout: String, Decodable, Sendable {
        case kernelFirst = "kernel-first"
        case kernelLast = "kernel-last"
    }

    public let id: String
    public let productVersion: String
    public let kernel: KernelCacheFile
    /// Symbol map of the stripped kernelcache: address (decimal) to names.
    public let symbols: String
    /// Bundle identifiers of the mix, one per line.
    public let kexts: String
    public let donor: String
    public let builderLayout: BuilderLayout

    public internal(set) var directory = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey {
        case id, productVersion, kernel, symbols, kexts, donor, builderLayout
    }

    public var symbolsURL: URL {
        directory.appending(path: symbols)
    }

    public var kextsURL: URL {
        directory.appending(path: kexts)
    }

    public func kextIdentifiers() throws -> [String] {
        try String(contentsOf: kextsURL, encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// A donor of the virtualisation kexts (`donors/<id>/manifest.json`).
public struct KernelCacheDonor: Decodable, Sendable {
    public let id: String
    public let description: String?
    public let kernel: KernelCacheFile
    /// The cloudOS IPSW the donor kernelcache is read from.
    public let cloudOSSource: String
    /// Symbol map, for a stripped donor.
    public let symbols: String?

    public internal(set) var directory = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey {
        case id, description, kernel, cloudOSSource, symbols
    }

    public var symbolsURL: URL? {
        symbols.map { directory.appending(path: $0) }
    }
}

public struct KernelCacheRecipes: Sendable {
    public static let directoryName = "kernelcache_recipes"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The recipes beside the running `vphone-cli`: `Contents/Resources` in the
    /// bundle, or the source tree for a plain Xcode build.
    public static func locate() throws -> KernelCacheRecipes {
        let bundled = VPhoneResources.resolve().base.appending(path: directoryName)
        var candidates = [bundled]
        var directory = VPhoneResources.runningExecutable().deletingLastPathComponent()
        for _ in 0 ..< 8 {
            candidates.append(directory.appending(path: "VPhoneExecutable/VPhoneVirtualization/Resources/\(directoryName)"))
            directory = directory.deletingLastPathComponent()
        }
        guard let root = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "bases").path) }) else {
            throw PatcherError.fileNotFound("the kernelcache recipes (\(bundled.path))")
        }
        return KernelCacheRecipes(root: root)
    }

    public func bases() throws -> [KernelCacheBase] {
        try manifests(in: "bases").map { url in
            var base = try JSONDecoder().decode(KernelCacheBase.self, from: Data(contentsOf: url))
            base.directory = url.deletingLastPathComponent()
            return base
        }
    }

    public func donor(id: String) throws -> KernelCacheDonor {
        let url = root.appending(path: "donors/\(id)/manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound("the kernelcache donor recipe \(url.path)")
        }
        var donor = try JSONDecoder().decode(KernelCacheDonor.self, from: Data(contentsOf: url))
        donor.directory = url.deletingLastPathComponent()
        return donor
    }

    /// The recipe for a kernelcache, given as its IM4P or decompressed bytes.
    public func base(forKernelcache data: Data) throws -> KernelCacheBase? {
        let sha = Self.sha256(data)
        return try bases().first { $0.kernel.matches(sha: sha) }
    }

    private func manifests(in subdirectory: String) throws -> [URL] {
        let directory = root.appending(path: subdirectory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries
            .map { $0.appending(path: "manifest.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
