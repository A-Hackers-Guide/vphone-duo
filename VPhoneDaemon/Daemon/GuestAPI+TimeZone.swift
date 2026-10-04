import Darwin
import Foundation

// MARK: - Time Zone

/// The system time zone is the `/var/db/timezone/localtime` symlink into
/// `/var/db/timezone/zoneinfo`. Only tzlinkd (`com.apple.tzlink`) moves it:
/// libutil's `tzlink(name)` hands it an Olson name, tzlinkd accepts the request
/// from a holder of `com.apple.tzlink.allow`, re-points the link and posts
/// `SignificantTimeChangeNotification`. timed owns the automatic time zone and
/// would put its own zone back, so a set first turns that off through
/// CoreTime, which timed accepts only from a holder of `com.apple.timed`.
/// Neither function is in the SDK headers; both are looked up at run time.
extension GuestAPI {
    static func executeTimeZone(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard method == "time.timezone" else { return nil }
        let changed: Bool
        if let identifier = optionalString(params, "identifier") {
            changed = try pinTimeZone(identifier)
        } else if let automatic = params["automatic"] as? Bool {
            changed = try setAutomaticTimeZone(automatic)
        } else {
            return timeZoneState()
        }
        var state = timeZoneState()
        state["changed"] = changed
        return state
    }

    private static let zoneInfoDirectory = "/var/db/timezone/zoneinfo/"
    private static let localTimeLink = "/var/db/timezone/localtime"

    /// `{identifier, automatic, seconds_from_gmt}`. `automatic` is null when
    /// CoreTime does not answer.
    private static func timeZoneState() -> [String: Any] {
        let identifier = systemTimeZoneIdentifier()
        let zone = identifier.flatMap(TimeZone.init(identifier:))
        return [
            "identifier": identifier.map { $0 as Any } ?? NSNull(),
            "automatic": automaticTimeZoneEnabled().map { $0 as Any } ?? NSNull(),
            "seconds_from_gmt": zone.map { $0.secondsFromGMT() as Any } ?? NSNull(),
        ]
    }

    /// Read from the link, not `TimeZone.current`, which this process caches.
    private static func systemTimeZoneIdentifier() -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: localTimeLink) else {
            return nil
        }
        return target.hasPrefix(zoneInfoDirectory) ? String(target.dropFirst(zoneInfoDirectory.count)) : target
    }

    /// Turns the automatic time zone off and links `identifier`. Returns false
    /// when the guest was already pinned to it.
    private static func pinTimeZone(_ identifier: String) throws -> Bool {
        let components = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
              FileManager.default.fileExists(atPath: zoneInfoDirectory + identifier)
        else {
            throw GuestAPIError.invalidRequest("\(identifier) is not a time zone in \(zoneInfoDirectory)")
        }
        let automaticChanged = try setAutomaticTimeZone(false)
        guard systemTimeZoneIdentifier() != identifier else { return automaticChanged }
        guard let tzlink = symbol("/usr/lib/libutil.dylib", "tzlink", as: TimeZoneLink.self) else {
            throw GuestAPIError.operationFailed("libutil does not export tzlink")
        }
        let error = tzlink(identifier)
        guard error == 0 else {
            throw GuestAPIError.operationFailed("tzlink \(identifier) failed: \(String(cString: strerror(error)))")
        }
        guard systemTimeZoneIdentifier() == identifier else {
            throw GuestAPIError.operationFailed("tzlinkd accepted \(identifier) but \(localTimeLink) did not change")
        }
        return true
    }

    /// Returns false when timed already had that setting.
    private static func setAutomaticTimeZone(_ enabled: Bool) throws -> Bool {
        guard let current = automaticTimeZoneEnabled(),
              let set = symbol(coreTimePath, "TMSetAutomaticTimeZoneEnabled", as: SetAutomaticTimeZone.self)
        else {
            throw GuestAPIError.operationFailed("CoreTime does not export the automatic time zone functions")
        }
        guard current != enabled else { return false }
        // timed takes the command without a reply; ask until it reports the
        // new setting so a later tzlink is not undone by the old one.
        set(enabled)
        var attempts = 0
        while automaticTimeZoneEnabled() != enabled, attempts < 20 {
            usleep(50000)
            attempts += 1
        }
        guard automaticTimeZoneEnabled() == enabled else {
            throw GuestAPIError.operationFailed("timed did not turn the automatic time zone \(enabled ? "on" : "off")")
        }
        return true
    }

    private static func automaticTimeZoneEnabled() -> Bool? {
        symbol(coreTimePath, "TMIsAutomaticTimeZoneEnabled", as: IsAutomaticTimeZone.self).map { $0() }
    }

    private typealias TimeZoneLink = @convention(c) (UnsafePointer<CChar>) -> Int32
    private typealias SetAutomaticTimeZone = @convention(c) (Bool) -> Void
    private typealias IsAutomaticTimeZone = @convention(c) () -> Bool

    private static let coreTimePath = "/System/Library/PrivateFrameworks/CoreTime.framework/CoreTime"

    private static func symbol<Function>(_ library: String, _ name: String, as _: Function.Type) -> Function? {
        guard let handle = dlopen(library, RTLD_LAZY), let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: Function.self)
    }
}
