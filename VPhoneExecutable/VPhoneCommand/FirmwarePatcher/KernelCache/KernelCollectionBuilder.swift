// KernelCollectionBuilder.swift — Link a staged volume into an IMG4 kernelcache.
//
// kmutil only gathers the inputs; the layout comes from the kernel collection
// builder in the host's dyld shared cache. The builder of macOS 26.4 and later
// puts the kernel's `__TEXT_EXEC` after the kexts ("kernel-last"), macOS 15 and
// 26.0–26.3 put it first ("kernel-first"), and a kernel only boots in the layout
// Apple linked it with. Every iOS 26.4+ base is kernel-last, so the host links
// it when it runs macOS 26.4 or later.
//
// kmutil reads only kexts owned by root:wheel. Others it skips without a word
// and takes the host's own from /System/Library/Extensions, so the link runs as
// root on a volume chowned to root.

import Foundation
import VPhonePatchKit

enum KernelCollectionBuilder {
    /// The flags of Apple's boot kernel collections: strip all, IMG4 with split
    /// read-only and executable tags.
    static let createFlags = ["-a", "arm64e", "-n", "boot", "-s", "all", "-z", "-x"]
    static let packageFlags = ["--compress", "--img4-encode", "--split-ro-rx-tags"]

    static func layout(forMacOS version: OperatingSystemVersion) -> KernelCacheBase.BuilderLayout {
        let atLeast264 = version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
        return atLeast264 ? .kernelLast : .kernelFirst
    }

    /// Refuses before anything is extracted when this Mac cannot link `base`.
    static func checkLayout(for base: KernelCacheBase) throws {
        let host = ProcessInfo.processInfo.operatingSystemVersion
        let layout = layout(forMacOS: host)
        guard layout == base.builderLayout else {
            throw PatcherError.invalidFormat(
                "the iOS \(base.productVersion) kernelcache must be linked \(base.builderLayout.rawValue), "
                    + "and the kmutil of macOS \(host.majorVersion).\(host.minorVersion) links \(layout.rawValue): "
                    + (base.builderLayout == .kernelLast ? "update this Mac to macOS 26.4 or later" : "link it on macOS 15"),
            )
        }
    }

    /// Link the volume at `volume` and return kmutil's IMG4 kernelcache.
    static func link(volume: URL, kernel: URL, identifiers: [String], log: URL) throws -> Data {
        try KernelCacheMixer.run("/usr/sbin/chown", ["-R", "0:0", volume.path], log: log)
        let output = volume.deletingLastPathComponent().appending(path: "\(volume.lastPathComponent).kc")
        try? FileManager.default.removeItem(at: output)
        var arguments = ["create"] + createFlags
            + ["-R", volume.path, "-k", kernel.path, "-r", volume.appending(path: "System/Library/Extensions").path]
        for identifier in identifiers {
            arguments += ["-b", identifier]
        }
        // -B is relative to the volume root.
        arguments += packageFlags + ["-B", "/../\(output.lastPathComponent)"]
        try KernelCacheMixer.run("/usr/bin/kmutil", arguments, log: log)
        return try Data(contentsOf: output)
    }
}
