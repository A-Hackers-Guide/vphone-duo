import Foundation

// MARK: - Identity

/// Names both sides of the privileged helper agree on. The label is also the
/// helper's file name under /Library/PrivilegedHelperTools and the key of the
/// app's SMPrivilegedExecutables entry.
nonisolated enum VPhoneLaunchpadHelperIdentity {
    static let label = "com.vphone.launchpad.helper"
    static let machServiceName = label
    /// Authorization right every privileged verb requires. The helper
    /// writes its rule (an administrator, no shared credential) as root.
    static let privilegedRight = "com.vphone.launchpad.helper.privileged"
}

// MARK: - Helper interface

/// The whole root surface of vphone-launchpad. Every call is a fixed verb with
/// validated arguments; there is deliberately no "run this command" entry.
/// Every verb but `helperVersion` takes `authorization`, the caller's
/// AuthorizationExternalForm, and fails unless it holds
/// `VPhoneLaunchpadHelperIdentity.privilegedRight`.
@objc(VPhoneLaunchpadHelperProtocol)
nonisolated protocol VPhoneLaunchpadHelperProtocol {
    /// CFBundleVersion of the running helper, compared against the copy
    /// embedded in the app to decide whether to bless it again.
    func helperVersion(reply: @escaping @Sendable (String) -> Void)

    /// Copies the archive from `archive` into a root-owned staging directory,
    /// checks it against `sha256`, verifies the bundle's signature, and moves
    /// it into the root-owned bundle store. Replies with an error message, or
    /// nil on success.
    func installBundle(
        authorization: Data,
        version: String,
        archive: FileHandle,
        sha256: String,
        reply: @escaping @Sendable (String?) -> Void,
    )

    /// Removes one version from the bundle store.
    func removeBundle(authorization: Data, version: String, reply: @escaping @Sendable (String?) -> Void)

    /// Allows only the installed bundle's receipt-pinned vphone-vm through
    /// AMFI, using that bundle's vphone-escalator as root.
    func allowVirtualMachine(authorization: Data, bundleVersion: String, reply: @escaping @Sendable (String?) -> Void)

    /// Runs `vphone-cli cfw install` from a store bundle as root, on behalf of
    /// the calling user. Output lines arrive through
    /// `VPhoneLaunchpadHelperClientProtocol`. Replies with the exit status and
    /// an error message when the request was refused before running.
    func installCustomFirmware(
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        keepArtifacts: Bool,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    )

    /// Runs `vphone-cli cfw update-environment` from a store bundle as root:
    /// redeploys the bundle's guest resources into a stopped machine and
    /// nothing else. Same output channel and reply as `installCustomFirmware`,
    /// and `cancelCustomFirmware` stops it.
    func updateGuestEnvironment(
        authorization: Data,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        reply: @escaping @Sendable (Int32, String?) -> Void,
    )

    /// Runs `vphone-cli vm leases --release-orphans --json` from a store
    /// bundle as root, against the machines of `libraryRoots`, each of which
    /// the caller must own. It removes the DHCP leases on the shared NAT
    /// network that iOS guests left behind with a MAC no machine has. Replies
    /// with the command's JSON output, or with an error message.
    func releaseOrphanedLeases(
        authorization: Data,
        bundleVersion: String,
        libraryRoots: [String],
        reply: @escaping @Sendable (String?, String?) -> Void,
    )

    /// Sends SIGINT to a running CFW install started by the same user. It
    /// needs no authorization: it can only stop the caller's own install.
    func cancelCustomFirmware(reply: @escaping @Sendable () -> Void)

    /// Removes the helper's launchd job and binary, then exits.
    func uninstallHelper(authorization: Data, reply: @escaping @Sendable (String?) -> Void)
}

// MARK: - Client interface

/// Exported by the app so the helper can stream command output back.
@objc(VPhoneLaunchpadHelperClientProtocol)
nonisolated protocol VPhoneLaunchpadHelperClientProtocol {
    func helperDidEmit(line: String)
}
