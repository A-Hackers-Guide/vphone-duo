import Foundation

/// The Core Bundle a machine runs with, and the bundles that built the parts
/// of it a later bundle does not replace.
///
/// A machine is made of three layers that come from a bundle at different
/// times:
/// - the host programs (`vphone-cli`, `vphone-vm`), taken from `bundle` on
///   every command, so changing it takes effect on the next start;
/// - the guest environment (vphoned and the hook dylibs), copied in by
///   `cfw install` and again by `cfw update-environment`;
/// - the boot chain and the custom firmware patches, written by `fw patch`,
///   `restore` and `cfw install` when the machine is created. Only creating
///   the machine again changes them.
///
/// Launchpad keeps this in `launchpad.json` inside the machine folder, so it
/// moves with `vm rename` and is copied by `vm clone`. vphone-cli neither
/// reads nor writes it.
nonisolated struct VPhoneLaunchpadMachineBinding: Codable, Equatable, Sendable {
    /// The store version every command on this machine runs with.
    var bundle: String
    /// The bundle that patched and restored the boot chain. Nil for a
    /// machine created before Launchpad recorded it.
    var bootChain: String?
    /// The bundle whose guest environment was installed last. Nil while
    /// unknown.
    var guestEnvironment: String?

    static let fileName = "launchpad.json"

    init(bundle: String, bootChain: String? = nil, guestEnvironment: String? = nil) {
        self.bundle = bundle
        self.bootChain = bootChain
        self.guestEnvironment = guestEnvironment
    }

    /// True when the guest environment is known to come from another bundle
    /// than the host programs that talk to it.
    var hasMixedVersions: Bool {
        guestEnvironment.map { $0 != bundle } ?? false
    }

    // MARK: - File

    static func url(for machine: VPhoneLaunchpadMachinePath) -> URL {
        machine.url.appendingPathComponent(fileName)
    }

    /// Nil when the machine has no binding yet, or the file is not one
    /// Launchpad wrote. Every version is checked, since the file is in a
    /// folder the user owns and a version becomes a path in the store.
    static func load(_ machine: VPhoneLaunchpadMachinePath) -> VPhoneLaunchpadMachineBinding? {
        let url = url(for: machine)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let binding = try? JSONDecoder().decode(Self.self, from: data),
              VPhoneLaunchpadNames.isValidVersion(binding.bundle),
              [binding.bootChain, binding.guestEnvironment].allSatisfy({ $0.map(VPhoneLaunchpadNames.isValidVersion) ?? true })
        else {
            return nil
        }
        return binding
    }

    /// Atomic, so a `launchpad.json` that is a symbolic link is replaced
    /// rather than written through.
    func save(to machine: VPhoneLaunchpadMachinePath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: machine), options: .atomic)
    }
}
