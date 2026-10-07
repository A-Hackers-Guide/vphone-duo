import Foundation

// MARK: - Removable System Apps

/// The rules `apps.remove_system` and `apps.restore_system` follow, kept free
/// of IcliKit and UIKit so `VPhoneDaemon/Tests/run-system-maintenance-tests.sh`
/// checks them on the Mac.
///
/// A removable system app (App Store, Home, TV, News …) is a placeholder in
/// `/System/Library/AppPlaceholders` that installd expands on first boot into
/// its own bundle container on the data volume,
/// `/private/var/containers/Bundle/Application/<UUID>/<Name>.app`. Only an app
/// in such a container is removed; anything under `/Applications` or
/// `/System` (Phone, Settings, SpringBoard) is refused. The UUID changes with
/// every install, so the path always comes from the live app list.
/// `Research/Guest/post_setup_signin_and_appstore.md` has the measurements.
enum GuestSystemAppPolicy {
    static let containersRoot = "/private/var/containers/Bundle/Application"
    static let backupDirectory = "/private/var/mobile/Library/removed-system-apps"
    static let backupSuffix = ".container"
    static let manifestSuffix = ".manifest.json"

    /// Only Apple's apps are removable system apps. The identifier also names
    /// the backup files, so it is limited to reverse-DNS characters.
    static func validateBundleID(_ bundleID: String) throws(GuestSystemAppPolicyError) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleID.isEmpty, bundleID.count <= 255,
              bundleID.unicodeScalars.allSatisfy(allowed.contains),
              !bundleID.contains("..")
        else {
            throw .invalidBundleID(bundleID)
        }
        guard bundleID.hasPrefix("com.apple."), bundleID.count > "com.apple.".count else {
            throw .notSystemApp(bundleID)
        }
    }

    static func backupContainerPath(_ bundleID: String) -> String {
        backupDirectory + "/" + bundleID + backupSuffix
    }

    static func manifestPath(_ bundleID: String) -> String {
        backupDirectory + "/" + bundleID + manifestSuffix
    }

    /// The bundle identifier a backup directory entry belongs to, or nil for
    /// another file.
    static func bundleID(forBackupEntry name: String) -> String? {
        for suffix in [backupSuffix, manifestSuffix] where name.hasSuffix(suffix) {
            let id = String(name.dropLast(suffix.count))
            return (try? validateBundleID(id)) == nil ? nil : id
        }
        return nil
    }
}

enum GuestSystemAppPolicyError: Error, Equatable, CustomStringConvertible {
    case invalidBundleID(String)
    case notSystemApp(String)
    case notInBundleContainer(String)
    case invalidManifest(String)

    var description: String {
        switch self {
        case let .invalidBundleID(id):
            "\(id) is not a bundle identifier"
        case let .notSystemApp(id):
            "\(id) is not an Apple app; only removable system apps can be removed this way"
        case let .notInBundleContainer(path):
            "\(path) is not in a bundle container under \(GuestSystemAppPolicy.containersRoot); "
                + "apps in /Applications or /System are part of the system volume and are not removed"
        case let .invalidManifest(reason):
            "The backup manifest is not usable: \(reason)"
        }
    }
}

// MARK: - Bundle Container Location

/// Where one installed copy lives: `<containersRoot>/<UUID>/<Name>.app`.
struct GuestSystemAppLocation: Equatable {
    let containerUUID: String
    let appDirectoryName: String

    var containerPath: String { GuestSystemAppPolicy.containersRoot + "/" + containerUUID }
    var appPath: String { containerPath + "/" + appDirectoryName }

    /// Accepts the path LaunchServices reports, with or without the
    /// `/private` prefix and with a trailing slash. Anything else, a `.` or
    /// `..` component, an empty component, a container that is not named by
    /// a UUID (RootHide's `.jbroot-*` among them) or a bundle nested deeper,
    /// is refused.
    init(bundlePath: String) throws(GuestSystemAppPolicyError) {
        var path = bundlePath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasPrefix("/var/") {
            path = "/private" + path
        }
        let root = GuestSystemAppPolicy.containersRoot + "/"
        guard path.hasPrefix(root) else { throw .notInBundleContainer(bundlePath) }
        let parts = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let uuid = UUID(uuidString: parts[0]), uuid.uuidString == parts[0].uppercased(),
              Self.isAppDirectoryName(parts[1])
        else {
            throw .notInBundleContainer(bundlePath)
        }
        containerUUID = parts[0]
        appDirectoryName = parts[1]
    }

    init(containerUUID: String, appDirectoryName: String) throws(GuestSystemAppPolicyError) {
        try self.init(bundlePath: GuestSystemAppPolicy.containersRoot + "/" + containerUUID + "/" + appDirectoryName)
    }

    private static func isAppDirectoryName(_ name: String) -> Bool {
        name.hasSuffix(".app") && name.count > 4 && !name.hasPrefix(".") && !name.contains("/")
    }
}

// MARK: - Backup Manifest

/// Written beside the backup container, never inside it: the container is
/// moved back as it is, and a file in it would land in the restored app's
/// bundle container.
struct GuestSystemAppManifest: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let bundleID: String
    let containerUUID: String
    let appDirectoryName: String
    /// The container path when the app was removed, for people reading the
    /// file; the restore rebuilds it from the UUID.
    let containerPath: String
    let removedAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case bundleID = "bundle_id"
        case containerUUID = "container_uuid"
        case appDirectoryName = "app"
        case containerPath = "container_path"
        case removedAt = "removed_at"
    }

    init(bundleID: String, location: GuestSystemAppLocation, removedAt: Date) {
        version = Self.currentVersion
        self.bundleID = bundleID
        containerUUID = location.containerUUID
        appDirectoryName = location.appDirectoryName
        containerPath = location.containerPath
        self.removedAt = removedAt
    }

    /// The location the restore moves the container back to, validated as a
    /// removal is: the backup directory is the mobile user's, so the manifest
    /// is not trusted to name any other path.
    func location() throws(GuestSystemAppPolicyError) -> GuestSystemAppLocation {
        try GuestSystemAppPolicy.validateBundleID(bundleID)
        return try GuestSystemAppLocation(containerUUID: containerUUID, appDirectoryName: appDirectoryName)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decodes and validates a manifest written for `expectedBundleID`.
    static func decode(_ data: Data, expectedBundleID: String) throws(GuestSystemAppPolicyError) -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: Self
        do {
            manifest = try decoder.decode(Self.self, from: data)
        } catch {
            throw .invalidManifest("it is not a manifest (\(error.localizedDescription))")
        }
        guard manifest.version == currentVersion else {
            throw .invalidManifest("version \(manifest.version) is not \(currentVersion)")
        }
        guard manifest.bundleID == expectedBundleID else {
            throw .invalidManifest("it names \(manifest.bundleID), not \(expectedBundleID)")
        }
        _ = try manifest.location()
        return manifest
    }
}
