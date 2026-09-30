import Darwin
import Foundation
import IcliKit
import IcliSystem

// MARK: - Setup Assistant

/// Setup Assistant (Setup.app) keeps its state in `com.apple.purplebuddy`
/// for user mobile. SpringBoard reads it once, when it starts: it runs the
/// full flow while `SetupDone` is not true, and the flow shown after a
/// software update while `SetupVersion` is below SetupAssistant.framework's
/// `BYBuddyIOSCurrentVersion`. Writing the keys while Setup is on screen does
/// not dismiss it, and killing Setup only makes SpringBoard start it again,
/// so a skip writes the keys and then restarts SpringBoard.
/// `Research/Guest/setup_assistant_skip.md` has the experiments behind this.
extension GuestAPI {
    static func executeSetupAssistant(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "setup.status":
            return try setupAssistantStatus()
        case "setup.skip":
            try requireForce(params, "skip Setup Assistant")
            return try skipSetupAssistant()
        default:
            return nil
        }
    }

    private static let buddyDomain = "com.apple.purplebuddy"

    /// `BYBuddyIOSCurrentVersion`, a 32-bit integer: 11 on iOS 26.4 and 27.0.
    /// Nil when the framework does not export it.
    static let setupAssistantCurrentVersion: Int? = {
        let path = "/System/Library/PrivateFrameworks/SetupAssistant.framework/SetupAssistant"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "BYBuddyIOSCurrentVersion")
        else { return nil }
        return Int(symbol.assumingMemoryBound(to: Int32.self).pointee)
    }()

    private static func buddyValue(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, buddyDomain as CFString, "mobile" as CFString, kCFPreferencesAnyHost)
    }

    private static var buddySetupVersion: Int? {
        (buddyValue("SetupVersion") as? NSNumber)?.intValue
    }

    /// True when SpringBoard will run Setup the next time it starts. Two
    /// preference reads, cheap enough for `/v1/health`.
    static func setupAssistantPending() -> Bool {
        guard buddyValue("SetupDone") as? Bool == true else { return true }
        guard let current = setupAssistantCurrentVersion else { return false }
        return (buddySetupVersion ?? 0) < current
    }

    private static func setupAssistantStatus() throws -> [String: Any] {
        let processes = try listProcesses(filter: "Setup")["processes"] as? [[String: Any]] ?? []
        let pid = processes.first { $0["executable"] as? String == "/Applications/Setup.app/Setup" }?["pid"]
        return [
            "pending": setupAssistantPending(),
            "running": pid != nil,
            "pid": pid ?? 0,
            "setup_done": buddyValue("SetupDone") as? Bool ?? false,
            "setup_version": buddySetupVersion.map { $0 as Any } ?? NSNull(),
            "current_version": setupAssistantCurrentVersion.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Marks setup finished for this iOS version and restarts SpringBoard.
    /// These three keys are all Setup needs: with every other key absent,
    /// SpringBoard starts to the Home Screen and no later panes appear.
    private static func skipSetupAssistant() throws -> [String: Any] {
        guard let current = setupAssistantCurrentVersion else {
            throw GuestAPIError.operationFailed("SetupAssistant.framework does not export BYBuddyIOSCurrentVersion")
        }
        let version = max(buddySetupVersion ?? 0, current)
        _ = try writePreference(domain: buddyDomain, key: "SetupDone", value: .bool(true))
        _ = try writePreference(domain: buddyDomain, key: "SetupFinishedAllSteps", value: .bool(true))
        _ = try writePreference(domain: buddyDomain, key: "SetupVersion", value: .int(Int64(version)))
        let springBoard = try respring()
        var status = try setupAssistantStatus()
        status["respring"] = springBoard
        return status
    }
}
