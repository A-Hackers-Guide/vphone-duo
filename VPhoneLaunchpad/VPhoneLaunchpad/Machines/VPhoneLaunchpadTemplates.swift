import Foundation

// MARK: - Slimming switches

/// New Machine's system slimming switches, as `vphone-cli vm create`,
/// `vm template find`, `vm template trim` and `vm template setup` take them
/// (`VPhoneTemplateSlimmingRequest` in the bundle). Only switches that differ
/// from the CLI's defaults are passed, so the CLI's own defaults stay the one
/// source of them.
///
/// The template key holds the trim tier and the removed apps; the service
/// profile can be switched on the machine later (Guest System).
nonisolated struct VPhoneLaunchpadSlimming: Hashable, Sendable {
    enum TrimTier: String, CaseIterable, Identifiable, Sendable {
        case none
        case conservative
        case standard

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .none: String(localized: "None")
            case .conservative: String(localized: "Conservative")
            case .standard: String(localized: "Standard")
            }
        }
    }

    /// One app the setup boot removes unless it is kept.
    struct App: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// Master switch. Off is `--slim off`: nothing trimmed, every service
    /// and app kept. Setup is skipped either way.
    var slim = true
    var trim = TrimTier.standard
    /// The languages the standard tier keeps the linguistic data of, comma
    /// separated; empty keeps ``defaultLanguages``.
    var keptLanguages = ""
    /// The trimmed service profile; off is `--service-profile none`.
    var trimsServices = true
    var removesApps = true
    /// Apps of ``removableApps`` to keep.
    var keptApps: Set<String> = []
    /// Also turns off the Apple Account daemons. Needs the trimmed profile.
    var accountsOff = false

    static let defaultLanguages = "en,zh-Hans,zh"

    /// List C of the template plan, the CLI's `defaultRemovedApps`. Camera
    /// and Phone are never removed.
    static var removableApps: [App] {
        [
            App(id: "com.apple.AppStore", name: String(localized: "App Store")),
            App(id: "com.apple.Home", name: String(localized: "Home")),
            App(id: "com.apple.tv", name: String(localized: "TV")),
            App(id: "com.apple.news", name: String(localized: "News")),
            App(id: "com.apple.facetime", name: String(localized: "FaceTime")),
            App(id: "com.apple.MobileStore", name: String(localized: "iTunes Store")),
            App(id: "com.apple.MobileSMS", name: String(localized: "Messages")),
            App(id: "com.apple.games", name: String(localized: "Games")),
            App(id: "com.apple.findmy", name: String(localized: "Find My")),
            App(id: "com.apple.Passbook", name: String(localized: "Wallet")),
        ]
    }

    static func appName(_ bundleID: String) -> String {
        removableApps.first { $0.id == bundleID }?.name ?? bundleID
    }

    // MARK: Effective values

    /// The kept languages as the CLI takes them, or nil for the default (or
    /// when no tier removes language data).
    var languagesArgument: String? {
        guard slim, trim == .standard else {
            return nil
        }
        let list = Self.languageList(keptLanguages)
        guard !list.isEmpty, list.joined(separator: ",") != Self.defaultLanguages else {
            return nil
        }
        return list.joined(separator: ",")
    }

    static func languageList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why Create cannot go ahead with these switches, or nil. The CLI
    /// refuses the rest; the controls do not offer them.
    var problem: String? {
        guard let languages = languagesArgument else {
            return nil
        }
        let bad = Self.languageList(languages).filter { $0.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil }
        guard bad.isEmpty else {
            return String(localized: "\(bad.joined(separator: ", ")) is not a language code such as ja or zh-Hant.")
        }
        return nil
    }

    /// The apps the template removes.
    var removedApps: [String] {
        guard slim, removesApps else {
            return []
        }
        return Self.removableApps.map(\.id).filter { !keptApps.contains($0) }
    }

    // MARK: Arguments

    /// For `vm template find` and `vm create`.
    var arguments: [String] {
        guard slim else {
            return ["--slim", "off"]
        }
        var arguments: [String] = []
        if trim != .standard {
            arguments += ["--trim", trim.rawValue]
        }
        if let languagesArgument {
            arguments += ["--keep-languages", languagesArgument]
        }
        arguments += profileArguments
        if !removesApps {
            arguments += ["--remove-apps", "off"]
        } else {
            let kept = Self.removableApps.map(\.id).filter(keptApps.contains)
            if !kept.isEmpty {
                arguments += ["--keep-apps", kept.joined(separator: ",")]
            }
        }
        return arguments
    }

    private var profileArguments: [String] {
        if !trimsServices {
            return ["--service-profile", "none"]
        }
        return accountsOff ? ["--accounts-off"] : []
    }

    /// For `vm template setup`: the same without the trim, which the setup
    /// boot takes from what `vm template trim` recorded.
    var setupArguments: [String] {
        guard slim else {
            return ["--slim", "off"]
        }
        var arguments: [String] = []
        var index = self.arguments.startIndex
        let all = self.arguments
        while index < all.endIndex {
            let argument = all[index]
            if argument == "--trim" || argument == "--keep-languages" {
                index += 2
                continue
            }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }

    /// `vm template trim`'s options, or nil when nothing is trimmed and the
    /// step is left out.
    var trimArguments: [String]? {
        guard slim, trim != .none else {
            return nil
        }
        return ["--tier", trim.rawValue] + (languagesArgument.map { ["--keep-languages", $0] } ?? [])
    }
}

// MARK: - Commands

/// The `vphone-cli` arguments of a template-backed creation and of the
/// Templates page, without `--library-root`. One place, so the command a
/// step shows cannot drift from the one it runs.
nonisolated enum VPhoneLaunchpadTemplateCommands {
    struct Request: Hashable, Sendable {
        var iphoneSource: String
        var cloudOSSource: String
        var device: String?
        var preset: String
        var blocked: Set<String> = []
        var allowed: Set<String> = []
        var diskSizeGB: Int
        var slimming: VPhoneLaunchpadSlimming
    }

    static func find(_ request: Request) -> [String] {
        var arguments = ["vm", "template", "find", "--json",
                         "--iphone-source", request.iphoneSource, "--cloudos-source", request.cloudOSSource]
        if let device = request.device {
            arguments += ["--device", device]
        }
        arguments += ["--preset", request.preset, "--disk-size", String(request.diskSizeGB)]
        arguments += request.blocked.sorted().flatMap { ["--block", $0] }
        arguments += request.allowed.sorted().flatMap { ["--allow", $0] }
        return arguments + request.slimming.arguments
    }

    static func trim(_ machine: String, _ slimming: VPhoneLaunchpadSlimming) -> [String]? {
        slimming.trimArguments.map { ["vm", "template", "trim", machine] + $0 }
    }

    static func setup(_ machine: String, _ slimming: VPhoneLaunchpadSlimming) -> [String] {
        ["vm", "template", "setup", machine] + slimming.setupArguments
    }

    static func adopt(_ machine: String, iphoneSource: String, cloudOSSource: String) -> [String] {
        ["vm", "template", "adopt", machine, "--json", "--iphone-source", iphoneSource, "--cloudos-source", cloudOSSource]
    }

    /// The new machine, cloned with the settings a template does not fix.
    /// Its first boot is Launchpad's own.
    static func clone(_ machine: String, template: String, cpuCount: Int, memoryMB: Int, network: String) -> [String] {
        ["vm", "create", machine, "--template", template, "--skip-first-boot",
         "--cpu", String(cpuCount), "--memory", String(memoryMB), "--network", network]
    }

    static let list = ["vm", "template", "list", "--json"]

    static func delete(_ identifier: String) -> [String] {
        ["vm", "template", "delete", identifier, "--force"]
    }

    /// The line a failed `vphone-cli` ends with (`Error: …`), the reason a
    /// step failed in a sentence; nil when there is none.
    static func failureLine(_ lines: [String]) -> String? {
        lines.last { $0.hasPrefix("Error: ") }.map { String($0.dropFirst("Error: ".count)) }
    }
}

// MARK: - vm template list / show / find / adopt --json

/// One template as `vm template list --json`, `show --json` and `adopt
/// --json` print it (`VPhoneMachineTemplateReport`).
nonisolated struct VPhoneLaunchpadTemplate: Decodable, Identifiable, Hashable, Sendable {
    struct Slimming: Decodable, Hashable, Sendable {
        let trimTier: String
        let setupBoot: Bool
        let serviceProfile: String
        let serviceGroups: [String]
        let removedApps: [String]

        private enum CodingKeys: String, CodingKey {
            case trimTier = "TrimTier"
            case setupBoot = "SetupBoot"
            case serviceProfile = "ServiceProfile"
            case serviceGroups = "ServiceGroups"
            case removedApps = "RemovedApps"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            trimTier = try container.decode(String.self, forKey: .trimTier)
            setupBoot = try container.decode(Bool.self, forKey: .setupBoot)
            serviceProfile = try container.decode(String.self, forKey: .serviceProfile)
            serviceGroups = try container.decodeIfPresent([String].self, forKey: .serviceGroups) ?? []
            removedApps = try container.decode([String].self, forKey: .removedApps)
        }

        /// The tier without its list version and languages:
        /// `standard/1/en,zh` is `standard`.
        var tier: String {
            String(trimTier.split(separator: "/").first ?? "none")
        }

        /// The languages a standard trim kept, from `standard/1/en,zh`.
        var keptLanguages: String? {
            let parts = trimTier.split(separator: "/")
            return parts.count >= 3 ? String(parts[2]) : nil
        }

        var isSlimmed: Bool {
            tier != "none" || serviceProfile != "none" || !removedApps.isEmpty
        }

        /// `Standard trim · Services trimmed · 10 apps removed`, or Not
        /// slimmed.
        var summary: String {
            guard isSlimmed else {
                return String(localized: "Not slimmed")
            }
            var parts: [String] = []
            switch tier {
            case "standard": parts.append(String(localized: "Standard trim"))
            case "conservative": parts.append(String(localized: "Conservative trim"))
            case "none": parts.append(String(localized: "No trim"))
            default: parts.append(tier)
            }
            if serviceProfile == "trimmed" {
                parts.append(serviceGroups.contains("accounts")
                    ? String(localized: "Services and accounts off")
                    : String(localized: "Services trimmed"))
            }
            if !removedApps.isEmpty {
                parts.append(String(localized: "^[\(removedApps.count) app](inflect: true) removed"))
            }
            return parts.joined(separator: " · ")
        }
    }

    struct Key: Decodable, Hashable, Sendable {
        let device: String
        let iOSVersion: String
        let iOSBuild: String
        let cloudOSVersion: String
        let cloudOSBuild: String
        let patchPreset: String
        let bundleSeries: String
        let diskSizeGB: Int
        let slimming: Slimming

        private enum CodingKeys: String, CodingKey {
            case device = "Device"
            case iOSVersion = "IOSVersion"
            case iOSBuild = "IOSBuild"
            case cloudOSVersion = "CloudOSVersion"
            case cloudOSBuild = "CloudOSBuild"
            case patchPreset = "PatchPreset"
            case bundleSeries = "BundleSeries"
            case diskSizeGB = "DiskSizeGB"
            case slimming = "Slimming"
        }

        var osName: String {
            device.hasPrefix("iPad") ? "iPadOS" : "iOS"
        }
    }

    struct Sources: Decodable, Hashable, Sendable {
        let iPhone: String
        let cloudOS: String

        private enum CodingKeys: String, CodingKey {
            case iPhone = "IPhone"
            case cloudOS = "CloudOS"
        }
    }

    let id: String
    let path: String
    let key: Key
    let created: Date
    let builtWithBundleVersion: String?
    let bootChainBundleVersion: String?
    let sourceMachine: String?
    let allocatedBytes: Int64
    let machines: [String]
    let stale: Bool
    let staleReasons: [String]
    let sources: Sources?
    /// The library it was listed from. Not part of the JSON.
    var libraryRoot = ""

    private enum CodingKeys: String, CodingKey {
        case id, path, key, created, builtWithBundleVersion, bootChainBundleVersion, sourceMachine, allocatedBytes,
            machines, stale, staleReasons, sources
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// `vm template list --json`.
nonisolated struct VPhoneLaunchpadTemplateList: Decodable, Sendable {
    /// A create building a template, or a build that stopped.
    struct Building: Decodable, Hashable, Sendable {
        let name: String
        let path: String
        let id: String?
        let active: Bool
    }

    var templates: [VPhoneLaunchpadTemplate]
    var building: [Building]
    var damaged: [[String: String]]

    static func decode(_ data: Data, libraryRoot: String) throws -> Self {
        var list = try VPhoneLaunchpadTemplate.decoder().decode(Self.self, from: data)
        for index in list.templates.indices {
            list.templates[index].libraryRoot = libraryRoot
        }
        return list
    }
}

/// `vm template find --json`.
nonisolated struct VPhoneLaunchpadTemplateFind: Decodable, Sendable {
    let resolved: Bool
    let resolvedBy: String?
    let id: String?
    let summary: String?
    let template: VPhoneLaunchpadTemplate?
    let usable: Bool
    let building: Bool
    let reason: String?

    static func decode(_ data: Data) throws -> Self {
        try VPhoneLaunchpadTemplate.decoder().decode(Self.self, from: data)
    }
}

// MARK: - Last machine of a template

/// What `vm delete` notes when the machine was the last one cloned from a
/// template that is still there: the template, and what it takes.
nonisolated struct VPhoneLaunchpadTemplateNotice: Identifiable, Hashable, Sendable {
    let id: String
    /// As the CLI wrote it, `17.58 GB`.
    let size: String
    let libraryRoot: String

    /// `note: template 52b1fcc75e0c (~17.58 GB) is no longer used by any machine; …`
    static func parse(_ lines: [String], libraryRoot: String) -> Self? {
        for line in lines.reversed() {
            if let match = line.firstMatch(of: /^note: template ([0-9a-f]{12}) \(~([^)]+)\) is no longer used by any machine/) {
                return Self(id: String(match.1), size: String(match.2), libraryRoot: libraryRoot)
            }
        }
        return nil
    }
}
