import Darwin
import Foundation

/// A validated `vphone-cli cfw install` or `cfw update-environment`
/// invocation. Built only from a store bundle whose cdhash still matches its
/// receipt, and only for a VM directory the calling user owns.
struct VPhoneLaunchpadHelperFirmwareRequest {
    enum Operation {
        /// The full install, which needs the prepared restore tree.
        case install(keepArtifacts: Bool)
        /// Redeploys the bundle's guest resources into a stopped machine and
        /// nothing else.
        case updateEnvironment
    }

    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    init(
        operation: Operation,
        bundleVersion: String,
        machineName: String,
        libraryRoot: String,
        callerUID: uid_t,
        callerGID: gid_t,
    ) throws {
        guard VPhoneLaunchpadNames.isCompatibleBundleVersion(bundleVersion) else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not supported. Use \(VPhoneLaunchpadNames.minimumBundleVersion) or newer.")
        }
        guard let receipt = VPhoneLaunchpadBundleReceipt.load(version: bundleVersion) else {
            throw VPhoneLaunchpadHelperError("VPhone.bundle \(bundleVersion) is not installed. Install it in Core Bundle, then try again.")
        }
        let executable = VPhoneLaunchpadBundleStore.executable(version: bundleVersion, named: "vphone-cli")
        try VPhoneLaunchpadHelperCodeCheck.requireCDHash(executable, receipt.cdhashes["vphone-cli"])

        guard VPhoneLaunchpadNames.isValidMachineName(machineName) else {
            throw VPhoneLaunchpadHelperError("\"\(machineName)\" is not a valid machine name.")
        }
        // Checked by walking the path from "/" without following any link:
        // the library folder, the machine folder and its Disk.img must belong
        // to the caller. The caller can still rename these afterwards, so this
        // only refuses a bad request up front; the root vphone-cli child pins
        // the machine directory again itself before it touches anything.
        try Self.requireMachine(libraryRoot: libraryRoot, machineName: machineName, ownedBy: callerUID)
        let machine = URL(fileURLWithPath: libraryRoot, isDirectory: true)
            .appendingPathComponent(machineName, isDirectory: true)

        var arguments: [String]
        switch operation {
        case let .install(keepArtifacts):
            arguments = ["cfw", "install", machineName, "--library-root", libraryRoot]
            if keepArtifacts {
                arguments.append("--keep-artifacts")
            }
        case .updateEnvironment:
            arguments = ["cfw", "update-environment", machineName, "--library-root", libraryRoot]
        }

        self.executable = executable
        self.arguments = arguments
        workingDirectory = machine
        // The same environment `sudo vphone-cli cfw install` sees: SUDO_UID
        // and SUDO_GID are how the installer hands root-created files back
        // to the user afterwards.
        environment = try VPhoneLaunchpadHelperLibraryPath.environment(callerUID: callerUID, callerGID: callerGID)
    }

    // MARK: - Machine directory

    private static func requireMachine(libraryRoot: String, machineName: String, ownedBy uid: uid_t) throws {
        let root = try VPhoneLaunchpadHelperLibraryPath.openDirectory(libraryRoot)
        defer { close(root) }
        try VPhoneLaunchpadHelperLibraryPath.requireOwner(root, libraryRoot, uid)

        let machinePath = libraryRoot + "/" + machineName
        let machine = openat(root, machineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard machine >= 0 else {
            throw VPhoneLaunchpadHelperError("\(machinePath) is not a folder, or is a symbolic link.")
        }
        defer { close(machine) }
        try VPhoneLaunchpadHelperLibraryPath.requireOwner(machine, machinePath, uid)

        var disk = stat()
        guard fstatat(machine, "Disk.img", &disk, AT_SYMLINK_NOFOLLOW) == 0,
              (disk.st_mode & S_IFMT) == S_IFREG,
              disk.st_nlink == 1
        else {
            throw VPhoneLaunchpadHelperError("\(machinePath)/Disk.img must be a regular file, not a link.")
        }
        guard disk.st_uid == uid else {
            throw VPhoneLaunchpadHelperError("\(machinePath)/Disk.img is not owned by your user account.")
        }
    }
}
