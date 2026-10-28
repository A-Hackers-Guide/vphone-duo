import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Virtual Hinge

extension GuestAPI {
    private static let hingeLock = NSLock()

    /// `motion.hinge.set` publishes the host's hinge angle (0 closed, 180 flat)
    /// to the HID hinge sensor libvphonehinge runs in backboardd for an
    /// iPhone Duo guest. The angle is passed on exactly as given.
    static func executeHinge(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard ["motion.hinge.get", "motion.hinge.set", "motion.hinge.clear"].contains(method) else {
            return nil
        }
        hingeLock.lock()
        defer { hingeLock.unlock() }
        if method != "motion.hinge.get" {
            var angle = 180.0, velocity = 0.0, state: Int32 = 0
            var enabled = method == "motion.hinge.set"
            if method == "motion.hinge.set" {
                if let flag = params["enabled"] {
                    guard let value = flag as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                        throw GuestAPIError.invalidRequest("enabled must be a boolean")
                    }
                    enabled = value.boolValue
                }
                guard let value = params["angle"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...180).contains(value.doubleValue)
                else {
                    throw GuestAPIError.invalidRequest("angle must be a number from 0 (closed) to 180 (open flat) degrees")
                }
                angle = value.doubleValue
                if let raw = params["velocity"] {
                    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                          value.doubleValue.isFinite, abs(value.doubleValue) <= 3600
                    else {
                        throw GuestAPIError.invalidRequest("velocity must be a number between -3600 and 3600 degrees/s")
                    }
                    velocity = value.doubleValue
                }
                if let raw = params["state"] {
                    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                          (0...255).contains(value.intValue)
                    else {
                        throw GuestAPIError.invalidRequest("state must be an integer from 0 to 255")
                    }
                    state = value.int32Value
                }
            }
            guard vp_hinge_set(angle, velocity, state, enabled) else {
                throw GuestAPIError.operationFailed("Could not publish the hinge configuration")
            }
        }
        return vp_hinge_get() as? [String: Any] ?? [:]
    }
}
