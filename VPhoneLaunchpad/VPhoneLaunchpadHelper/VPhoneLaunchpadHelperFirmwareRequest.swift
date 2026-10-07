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
        /// Swaps the Preboot kernelcache for the re-patched one, keeping data.
        case updateKernel
    }

    typealias MachineKey = VPhoneLaunchpadHelperFirmwareAdmission.MachineKey

    /// The installer's work parent, `VPhoneCustomFirmwareInstaller.workParent`:
    /// every run makes its private work folder there.
    static let workParent = "/private/var/tmp"

    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let machineKey: MachineKey
    /// The volumes the run writes to, by device, each with a path on it: the
    /// machine folder's and the work parent's. One entry when they share one.
    let volumes: [dev_t: String]

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
        let folder = try Self.requireMachine(libraryRoot: libraryRoot, machineName: machineName, ownedBy: callerUID)
        let machine = URL(fileURLWithPath: libraryRoot, isDirectory: true)
            .appendingPathComponent(machineName, isDirectory: true)
        var work = stat()
        guard stat(Self.workParent, &work) == 0 else {
            throw VPhoneLaunchpadHelperError("Unable to read \(Self.workParent): \(String(cString: strerror(errno)))")
        }

        var arguments: [String]
        switch operation {
        case let .install(keepArtifacts):
            arguments = ["cfw", "install", machineName, "--library-root", libraryRoot]
            if keepArtifacts {
                arguments.append("--keep-artifacts")
            }
        case .updateEnvironment:
            arguments = ["cfw", "update-environment", machineName, "--library-root", libraryRoot]
        case .updateKernel:
            arguments = ["cfw", "update-kernel", machineName, "--library-root", libraryRoot]
        }

        self.executable = executable
        self.arguments = arguments
        workingDirectory = machine
        machineKey = MachineKey(device: folder.st_dev, inode: folder.st_ino)
        // Not one literal: equal keys in a dictionary literal trap.
        var volumes = [work.st_dev: Self.workParent]
        volumes[folder.st_dev] = machine.path
        self.volumes = volumes
        // The same environment `sudo vphone-cli cfw install` sees: SUDO_UID
        // and SUDO_GID are how the installer hands root-created files back
        // to the user afterwards.
        environment = try VPhoneLaunchpadHelperLibraryPath.environment(callerUID: callerUID, callerGID: callerGID)
    }

    /// The machine a cancel names. It checks no ownership: the operation
    /// found under the key is stopped only for the user who started it.
    static func machineKey(libraryRoot: String, machineName: String) throws -> MachineKey {
        guard VPhoneLaunchpadNames.isValidMachineName(machineName) else {
            throw VPhoneLaunchpadHelperError("\"\(machineName)\" is not a valid machine name.")
        }
        let root = try VPhoneLaunchpadHelperLibraryPath.openDirectory(libraryRoot)
        defer { close(root) }
        let machine = try openMachine(root, libraryRoot: libraryRoot, machineName: machineName)
        defer { close(machine) }
        var folder = stat()
        guard fstat(machine, &folder) == 0 else {
            throw VPhoneLaunchpadHelperError("\(libraryRoot)/\(machineName) is not a folder.")
        }
        return MachineKey(device: folder.st_dev, inode: folder.st_ino)
    }

    // MARK: - Machine directory

    /// Returns the machine folder's metadata.
    private static func requireMachine(libraryRoot: String, machineName: String, ownedBy uid: uid_t) throws -> stat {
        let root = try VPhoneLaunchpadHelperLibraryPath.openDirectory(libraryRoot)
        defer { close(root) }
        try VPhoneLaunchpadHelperLibraryPath.requireOwner(root, libraryRoot, uid)

        let machinePath = libraryRoot + "/" + machineName
        let machine = try openMachine(root, libraryRoot: libraryRoot, machineName: machineName)
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
        var folder = stat()
        guard fstat(machine, &folder) == 0 else {
            throw VPhoneLaunchpadHelperError("\(machinePath) is not a folder.")
        }
        return folder
    }

    private static func openMachine(_ root: Int32, libraryRoot: String, machineName: String) throws -> Int32 {
        let machine = openat(root, machineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard machine >= 0 else {
            throw VPhoneLaunchpadHelperError("\(libraryRoot)/\(machineName) is not a folder, or is a symbolic link.")
        }
        return machine
    }
}
