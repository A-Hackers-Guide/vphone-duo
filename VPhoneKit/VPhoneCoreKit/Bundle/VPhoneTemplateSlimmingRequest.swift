import Foundation

// MARK: - Slimming request

/// The slimming switches of `vm create` and `vm template setup`, turned into
/// the slimming a template's key promises.
///
/// `--slim off` turns every slimming switch off: no file trim, no service
/// profile, no app removal. The setup boot still runs, because skipping Setup
/// Assistant and waiting for first-boot work are not slimming: every clone
/// would otherwise start at the Setup screen and redo that work on its own
/// disk. A nil field was not given and takes its default.
public struct VPhoneTemplateSlimmingRequest: Equatable, Sendable {
    /// `--slim on|off`; nil is on.
    public var slim: Bool?
    /// `--trim none|conservative|standard|aggressive` (offline file trim);
    /// nil is ``defaultTrimTier`` when slimming.
    public var trimTier: String?
    /// `--service-profile none|trimmed`; nil is trimmed when slimming.
    public var serviceProfile: String?
    /// `--remove-apps on|off`; nil is on when slimming.
    public var removeApps: Bool?
    /// `--keep-apps`: apps of ``defaultRemovedApps`` to keep.
    public var keepApps: [String]
    /// `--accounts-off`: also turn off the Apple Account daemons.
    public var accountsOff: Bool

    public init(
        slim: Bool? = nil,
        trimTier: String? = nil,
        serviceProfile: String? = nil,
        removeApps: Bool? = nil,
        keepApps: [String] = [],
        accountsOff: Bool = false,
    ) {
        self.slim = slim
        self.trimTier = trimTier
        self.serviceProfile = serviceProfile
        self.removeApps = removeApps
        self.keepApps = keepApps
        self.accountsOff = accountsOff
    }

    // MARK: Defaults

    /// The file-trim tier a slimmed template gets when `--trim` is not given.
    /// Offline trimming is not built yet, so it is `none`; it becomes
    /// `standard` with it.
    public static let defaultTrimTier = "none"

    public static let trimTiers = ["none", "conservative", "standard", "aggressive"]
    public static let serviceProfiles = ["none", "trimmed"]

    /// The removable system apps a slimmed template drops (list C of the
    /// template trim plan), each verified to stay removed across a respring
    /// and a reboot on iOS 27.0. Camera stays for camera passthrough checks;
    /// Phone lives on the System volume and `apps.remove_system` refuses it.
    public static let defaultRemovedApps = [
        "com.apple.AppStore",
        "com.apple.Home",
        "com.apple.tv",
        "com.apple.news",
        "com.apple.facetime",
        "com.apple.MobileStore",
        "com.apple.MobileSMS",
        "com.apple.games",
        "com.apple.findmy",
        "com.apple.Passbook",
    ]

    /// What a create without slimming switches asks for.
    public static var defaultSlimming: VPhoneMachineTemplateSlimming {
        // No switch given, so nothing can contradict another.
        (try? VPhoneTemplateSlimmingRequest().resolve()) ?? .none
    }

    /// The vphoned service group `--accounts-off` adds.
    public static let accountsGroup = "accounts"

    // MARK: Resolution

    /// Whether any switch was given; with none, a named template's own
    /// slimming is taken as it is.
    public var isEmpty: Bool {
        self == VPhoneTemplateSlimmingRequest()
    }

    /// The slimming these switches ask for, or the switches that contradict
    /// each other.
    public func resolve() throws -> VPhoneMachineTemplateSlimming {
        var problems: [String] = []
        if let trimTier, !Self.trimTiers.contains(trimTier) {
            problems.append("--trim must be one of \(Self.trimTiers.joined(separator: ", ")), not \(trimTier)")
        }
        if let serviceProfile, !Self.serviceProfiles.contains(serviceProfile) {
            problems.append("--service-profile must be none or trimmed, not \(serviceProfile)")
        }
        let unknown = keepApps.filter { !Self.defaultRemovedApps.contains($0) }
        if !unknown.isEmpty {
            problems.append(
                "--keep-apps \(unknown.joined(separator: ",")): only apps removed by default can be kept "
                    + "(\(Self.defaultRemovedApps.joined(separator: ", ")))",
            )
        }

        if slim == false {
            var contradicted: [String] = []
            if let trimTier, trimTier != "none" { contradicted.append("--trim \(trimTier)") }
            if serviceProfile == "trimmed" { contradicted.append("--service-profile trimmed") }
            if removeApps == true { contradicted.append("--remove-apps on") }
            if !keepApps.isEmpty { contradicted.append("--keep-apps") }
            if accountsOff { contradicted.append("--accounts-off") }
            if !contradicted.isEmpty {
                problems.append("--slim off turns slimming off; it cannot be combined with \(contradicted.joined(separator: ", "))")
            }
        }
        let profile = slim == false ? "none" : serviceProfile ?? "trimmed"
        if accountsOff, profile != "trimmed" {
            problems.append("--accounts-off needs --service-profile trimmed")
        }
        let removes = slim == false ? false : removeApps ?? true
        if !removes, !keepApps.isEmpty, slim != false {
            problems.append("--keep-apps has nothing to keep with --remove-apps off")
        }
        guard problems.isEmpty else {
            throw VPhoneTemplateSlimmingError(problems: problems)
        }

        let keep = Set(keepApps)
        return VPhoneMachineTemplateSlimming(
            trimTier: slim == false ? "none" : trimTier ?? Self.defaultTrimTier,
            setupBoot: true,
            serviceProfile: profile,
            serviceGroups: accountsOff ? [Self.accountsGroup] : [],
            removedApps: removes ? Self.defaultRemovedApps.filter { !keep.contains($0) } : [],
        )
    }
}

public struct VPhoneTemplateSlimmingError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var problems: [String]

    public var description: String {
        problems.joined(separator: "; ")
    }

    public var errorDescription: String? {
        description
    }
}
