import Darwin
import Foundation

// MARK: - Profile UDID

/// The UDID libmisfix gives misagent when it checks a provisioning profile's
/// `ProvisionedDevices` (`VPhoneGuestComponents/MISFix`). Lockdown, Xcode and
/// devicectl keep seeing the guest's own UDID; only the hooked daemon sees
/// this one.
///
/// The hook reads the first of two files that exists and re-reads it when its
/// modification time or size changes. vphoned owns the data-volume file.
/// Clearing keeps that file with the key removed rather than deleting it:
/// the file then still comes first, so a UDID left in the `/usr/lib` copy
/// cannot take over again.
///
/// A change also stops misagent, so the next profile check runs in a fresh
/// process that has cached nothing. launchd starts misagent on demand.
/// installd is left alone: it asks misagent, and stopping it would abort an
/// install in progress.
extension GuestAPI {
    /// Must match `kConfigPaths` in `MISFixConfig.c`, in the same order.
    static let udidConfigPaths = ["/var/db/vphone/misfix.plist", "/usr/lib/libmisfix.plist"]
    static let udidConfigKey = "UniqueDeviceID"

    static func executeDeviceIdentity(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "udid.get":
            udidState()
        case "udid.set":
            // Stored exactly as sent, with no format check: the API is also
            // for probing what misagent does with an unusual value. The VM
            // window's menu is what holds a person to a real UDID's shape.
            try applyUDID(string(params, "udid"))
        case "udid.clear":
            try applyUDID(nil)
        default:
            nil
        }
    }

    /// Writes the setting, reads it back the way the hook resolves it, and
    /// restarts misagent.
    private static func applyUDID(_ udid: String?) throws -> [String: Any] {
        try writeUDIDConfiguration(udid)
        var state = udidState()
        guard state["path"] as? String == udidConfigPaths[0], state["udid"] as? String == udid else {
            throw GuestAPIError.operationFailed("\(udidConfigPaths[0]) did not read back as written")
        }
        state["restarted_pids"] = stopProcesses(named: "misagent")
        return state
    }

    /// The UDID the hook answers with and the file it comes from, resolved the
    /// way `MISFixCopyConfiguredDeviceIdentifier` resolves it. `udid` is null
    /// when the guest answers with its own.
    private static func udidState() -> [String: Any] {
        guard let path = udidConfigPaths.first(where: { access($0, F_OK) == 0 }) else {
            return ["udid": NSNull(), "path": NSNull()]
        }
        let udid = (readUDIDConfiguration(path)?[udidConfigKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ["udid": udid ?? NSNull(), "path": path]
    }

    private static func readUDIDConfiguration(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Replaces the data-volume file in one rename, which is what the hook's
    /// mtime check expects. Other keys in the file are kept.
    private static func writeUDIDConfiguration(_ udid: String?) throws {
        guard let path = udidConfigPaths.first else { return }
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755],
            )
        } catch {
            throw GuestAPIError.operationFailed("Could not create \(directory): \(error.localizedDescription)")
        }
        var configuration = readUDIDConfiguration(path) ?? [:]
        configuration[udidConfigKey] = udid
        do {
            // Binary, so any string the caller sends survives the round trip;
            // XML cannot carry every control character.
            let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw GuestAPIError.operationFailed("Could not write \(path): \(error.localizedDescription)")
        }
        // misagent and installd do not run as root; the hook only reads.
        chmod(path, 0o644)
    }
}
