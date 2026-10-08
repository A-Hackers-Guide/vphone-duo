import CryptoKit
import Foundation

// MARK: - Slimming

/// What a template's guest was trimmed of before it was frozen. Part of the
/// key: a machine cloned from a trimmed template cannot get the files back,
/// and one cloned from an untrimmed template does not lose them.
///
/// Every field has a "nothing done" value. Offline file trimming records
/// `trimTier`; the setup boot records `setupBoot`, `serviceProfile`,
/// `serviceGroups` and `removedApps` (see `VPhoneTemplateSetupBoot`). What a
/// `vm create` asks for comes from its switches (`VPhoneTemplateSlimmingRequest`).
public struct VPhoneMachineTemplateSlimming: Codable, Equatable, Hashable, Sendable {
    /// The file-trimming tier applied to the System volume: `none`,
    /// `conservative`, `standard` or `aggressive`.
    public var trimTier: String
    /// Whether the template was booted once to finish Setup and first-boot
    /// work before it was frozen.
    public var setupBoot: Bool
    /// The vphoned service profile applied during the setup boot: `none` or
    /// `trimmed`.
    public var serviceProfile: String
    /// Optional service groups applied on top of the profile's defaults
    /// (`accounts` for `--accounts-off`), sorted. Empty with profile `none`.
    public var serviceGroups: [String]
    /// Bundle identifiers of the system apps removed during the setup boot,
    /// sorted.
    public var removedApps: [String]

    public static let none = VPhoneMachineTemplateSlimming()

    public init(
        trimTier: String = "none",
        setupBoot: Bool = false,
        serviceProfile: String = "none",
        serviceGroups: [String] = [],
        removedApps: [String] = [],
    ) {
        self.trimTier = trimTier
        self.setupBoot = setupBoot
        self.serviceProfile = serviceProfile
        self.serviceGroups = Array(Set(serviceGroups)).sorted()
        self.removedApps = Array(Set(removedApps)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case trimTier = "TrimTier"
        case setupBoot = "SetupBoot"
        case serviceProfile = "ServiceProfile"
        case serviceGroups = "ServiceGroups"
        case removedApps = "RemovedApps"
    }

    /// One phrase for listings: `trim none, setup boot, services trimmed+accounts, 10 apps removed`.
    public var summary: String {
        var services = serviceProfile
        if !serviceGroups.isEmpty {
            services += "+" + serviceGroups.joined(separator: "+")
        }
        return "trim \(trimTier), \(setupBoot ? "setup boot" : "no setup boot"), services \(services), "
            + "\(removedApps.count) apps removed"
    }

    /// A key of format 1 has no `ServiceGroups`; it reads as none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            trimTier: container.decode(String.self, forKey: .trimTier),
            setupBoot: container.decode(Bool.self, forKey: .setupBoot),
            serviceProfile: container.decode(String.self, forKey: .serviceProfile),
            serviceGroups: container.decodeIfPresent([String].self, forKey: .serviceGroups) ?? [],
            removedApps: container.decode([String].self, forKey: .removedApps),
        )
    }
}

// MARK: - Key

/// Everything a new machine inherits from its template and could not change
/// afterwards without a restore. Two requests with the same key can share one
/// template; any difference needs another.
///
/// Not part of it: CPU, memory, screen, network and the other `config.plist`
/// settings (`vm config` changes them on the clone), and the guest patch
/// selection, which `cfw update-environment` applies both ways. The boot chain
/// is: `bootChainPlanDigest` covers the preset's boot-chain patches as the
/// plan resolved them, and the preset itself is a field because the presets
/// also differ in what a full `cfw install` writes into Preboot.
///
/// The key is pure data. The caller resolves each field: from the requested
/// options and IPSWs before a create, or from a machine's own records when it
/// is adopted. Both must arrive at the same values for the same machine.
public struct VPhoneMachineTemplateKey: Codable, Equatable, Hashable, Sendable {
    /// Raised whenever a field is added or its meaning changes, so templates
    /// keyed by an older rule are never matched by a newer one.
    ///
    /// - 1: the first templates (nothing slimmed, never booted).
    /// - 2: `slimming.serviceGroups`; a create now asks for a setup boot.
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    /// The guest device's product type, as `fw prepare` picked it.
    public var device: String
    public var iOSVersion: String
    public var iOSBuild: String
    public var cloudOSVersion: String
    public var cloudOSBuild: String
    public var patchPreset: String
    /// ``planDigest(bootChainPatches:parameters:)`` of the resolved plan.
    public var bootChainPlanDigest: String
    /// The `VPhone.bundle` series (`2.8`) that built the boot chain.
    public var bundleSeries: String
    /// The disk image's size in decimal GB, which the restore fixed.
    public var diskSizeGB: UInt64
    public var slimming: VPhoneMachineTemplateSlimming

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        device: String,
        iOSVersion: String,
        iOSBuild: String,
        cloudOSVersion: String,
        cloudOSBuild: String,
        patchPreset: String,
        bootChainPlanDigest: String,
        bundleSeries: String,
        diskSizeGB: UInt64,
        slimming: VPhoneMachineTemplateSlimming = .none,
    ) {
        self.formatVersion = formatVersion
        self.device = device
        self.iOSVersion = iOSVersion
        self.iOSBuild = iOSBuild
        self.cloudOSVersion = cloudOSVersion
        self.cloudOSBuild = cloudOSBuild
        self.patchPreset = patchPreset
        self.bootChainPlanDigest = bootChainPlanDigest
        self.bundleSeries = bundleSeries
        self.diskSizeGB = diskSizeGB
        self.slimming = slimming
    }

    // MARK: Identifier

    /// One `name=value` line per field, in a fixed order. Lists are joined
    /// with commas after sorting, so the order a caller gathered them in does
    /// not matter.
    public var canonicalDescription: String {
        [
            "format=\(formatVersion)",
            "device=\(device)",
            "ios=\(iOSVersion)/\(iOSBuild)",
            "cloudos=\(cloudOSVersion)/\(cloudOSBuild)",
            "preset=\(patchPreset)",
            "bootchain=\(bootChainPlanDigest)",
            "series=\(bundleSeries)",
            "disk=\(diskSizeGB)",
            "trim=\(slimming.trimTier)",
            "setup=\(slimming.setupBoot ? 1 : 0)",
            "services=\(slimming.serviceProfile)",
            "service-groups=\(slimming.serviceGroups.sorted().joined(separator: ","))",
            "removed-apps=\(slimming.removedApps.sorted().joined(separator: ","))",
        ].joined(separator: "\n")
    }

    /// The template's folder name: the first 12 hex digits of the SHA-256 of
    /// ``canonicalDescription``.
    public var identifier: String {
        Self.hex(SHA256.hash(data: Data(canonicalDescription.utf8))).prefix(Self.identifierLength).description
    }

    public static let identifierLength = 12

    /// Whether `text` has the shape of an identifier. Only such a name is
    /// ever looked up under `.templates`.
    public static func isIdentifier(_ text: String) -> Bool {
        text.utf8.count == identifierLength && text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    // MARK: Plan digest

    /// SHA-256 over the sorted boot-chain patch identifiers and the preset's
    /// parameters. The caller decides which patches count as boot chain, and
    /// must decide the same way for a request and for a recorded plan.
    public static func planDigest(bootChainPatches: some Sequence<String>, parameters: [String: String]) -> String {
        let patches = Array(Set(bootChainPatches)).sorted()
        let knobs = parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }
        let text = (["patches"] + patches + ["parameters"] + knobs).joined(separator: "\n")
        return hex(SHA256.hash(data: Data(text.utf8)))
    }

    // MARK: Bundle series

    /// The first two numbers of a bundle version: `2.8.1` and
    /// `2.8.0-local.ab12cd34` are both `2.8`. Nil for anything else.
    public static func series(ofBundleVersion version: String) -> String? {
        let numbers = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }
        return "\(parts[0]).\(parts[1])"
    }

    // MARK: Comparison

    /// The fields that differ from `other`, as `name: mine → theirs`, for
    /// messages. Empty when the keys are equal.
    public func differences(from other: VPhoneMachineTemplateKey) -> [String] {
        var lines: [String] = []
        func compare(_ name: String, _ mine: String, _ theirs: String) {
            if mine != theirs {
                lines.append("\(name): \(mine) → \(theirs)")
            }
        }
        compare("key format", String(formatVersion), String(other.formatVersion))
        compare("device", device, other.device)
        compare("iOS", "\(iOSVersion) (\(iOSBuild))", "\(other.iOSVersion) (\(other.iOSBuild))")
        compare("cloudOS", "\(cloudOSVersion) (\(cloudOSBuild))", "\(other.cloudOSVersion) (\(other.cloudOSBuild))")
        compare("preset", patchPreset, other.patchPreset)
        compare("boot-chain plan", String(bootChainPlanDigest.prefix(12)), String(other.bootChainPlanDigest.prefix(12)))
        compare("bundle series", bundleSeries, other.bundleSeries)
        compare("disk size", "\(diskSizeGB) GB", "\(other.diskSizeGB) GB")
        compare("trim tier", slimming.trimTier, other.slimming.trimTier)
        compare("setup boot", slimming.setupBoot ? "yes" : "no", other.slimming.setupBoot ? "yes" : "no")
        compare("service profile", slimming.serviceProfile, other.slimming.serviceProfile)
        compare(
            "service groups",
            slimming.serviceGroups.joined(separator: ",").ifEmpty("none"),
            other.slimming.serviceGroups.joined(separator: ",").ifEmpty("none"),
        )
        compare(
            "removed apps",
            slimming.removedApps.joined(separator: ",").ifEmpty("none"),
            other.slimming.removedApps.joined(separator: ",").ifEmpty("none"),
        )
        return lines
    }

    /// One line for listings.
    public var summary: String {
        "\(device) iOS \(iOSVersion) (\(iOSBuild)) / cloudOS \(cloudOSVersion) (\(cloudOSBuild)), "
            + "\(patchPreset), \(diskSizeGB) GB, bundle \(bundleSeries), \(slimming.summary)"
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "FormatVersion"
        case device = "Device"
        case iOSVersion = "IOSVersion"
        case iOSBuild = "IOSBuild"
        case cloudOSVersion = "CloudOSVersion"
        case cloudOSBuild = "CloudOSBuild"
        case patchPreset = "PatchPreset"
        case bootChainPlanDigest = "BootChainPlanDigest"
        case bundleSeries = "BundleSeries"
        case diskSizeGB = "DiskSizeGB"
        case slimming = "Slimming"
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Request

/// The key fields a `vm create --template` names explicitly. A nil field was
/// not given and takes the template's value.
public struct VPhoneMachineTemplateRequest: Equatable, Sendable {
    public var device: String?
    public var patchPreset: String?
    public var diskSizeGB: UInt64?
    /// The slimming the switches ask for, when any slimming switch was given.
    public var slimming: VPhoneMachineTemplateSlimming?

    public init(
        device: String? = nil,
        patchPreset: String? = nil,
        diskSizeGB: UInt64? = nil,
        slimming: VPhoneMachineTemplateSlimming? = nil,
    ) {
        self.device = device
        self.patchPreset = patchPreset
        self.diskSizeGB = diskSizeGB
        self.slimming = slimming
    }

    /// Each option that asks for something the template does not have, as a
    /// sentence. A clone cannot change any of them.
    public func conflicts(with key: VPhoneMachineTemplateKey) -> [String] {
        var lines: [String] = []
        if let device, device != key.device {
            lines.append("--device \(device): the template's guest is \(key.device)")
        }
        if let patchPreset, patchPreset != key.patchPreset {
            lines.append("--preset \(patchPreset): the template was built with \(key.patchPreset)")
        }
        if let diskSizeGB, diskSizeGB != key.diskSizeGB {
            lines.append("--disk-size \(diskSizeGB): the template's disk is \(key.diskSizeGB) GB, fixed by its restore")
        }
        if let slimming, slimming != key.slimming {
            lines.append("the slimming switches ask for \(slimming.summary); the template has \(key.slimming.summary)")
        }
        return lines
    }
}

// MARK: - Bundle version

public enum VPhoneBundleVersion {
    /// `CFBundleShortVersionString` of the `VPhone.bundle` the running
    /// executable is in, read from `Contents/Info.plist` beside
    /// `Contents/MacOS`. Nil for an executable outside a bundle.
    public static func current() -> String? {
        let executable = VPhoneResources.runningExecutable().resolvingSymlinksInPath()
        let info = executable
            .deletingLastPathComponent() // Contents/MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}

private extension String {
    func ifEmpty(_ replacement: String) -> String {
        isEmpty ? replacement : self
    }
}
