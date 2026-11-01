import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Virtual Hinge

extension GuestAPI {
    private static let hingeLock = NSLock()

    /// `motion.hinge.set` moves the iPhone Duo's virtual hinge (0 closed, 180
    /// flat) at once, to exactly the angle the 3D window's fold slider gives,
    /// through the same hinge `display.posture` sweeps. `motion.hinge.clear`
    /// opens it flat. Replies carry `velocity` 0: the hinge has no velocity.
    static func executeHinge(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard ["motion.hinge.get", "motion.hinge.set", "motion.hinge.clear"].contains(method) else {
            return nil
        }
        hingeLock.lock()
        defer { hingeLock.unlock() }
        if method == "motion.hinge.set" {
            guard let value = params["angle"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, (0...180).contains(value.doubleValue)
            else {
                throw GuestAPIError.invalidRequest("angle must be a number from 0 (closed) to 180 (open flat) degrees")
            }
            guard vp_hinge_set(value.doubleValue, 0) else {
                throw GuestAPIError.operationFailed("Could not publish the hinge configuration")
            }
        } else if method == "motion.hinge.clear" {
            guard vp_hinge_set(180, 0) else {
                throw GuestAPIError.operationFailed("Could not publish the hinge configuration")
            }
        }
        var reply = vp_hinge_get() as? [String: Any] ?? [:]
        reply["velocity"] = 0.0
        return reply
    }
}
