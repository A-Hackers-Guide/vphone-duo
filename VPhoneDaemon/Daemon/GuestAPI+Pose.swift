import CoreFoundation
import Foundation
import VphonedNative

// MARK: - Device Pose

extension GuestAPI {
    private static let poseLock = NSLock()

    /// `display.pose.set` overrides SpringBoard's device pose through its test
    /// automation service, the way a foldable's test tools drive it without a
    /// hinge sensor. `hinge_state` is SpringBoard's hinge state (0–4; it maps
    /// 0 and 1 to 0°, 2 to 90°, 3 and 4 to 180°); `angle` picks one from the
    /// host's hinge angle instead. `display.pose.get` reads the pose back.
    static func executePose(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard ["display.pose.get", "display.pose.set"].contains(method) else {
            return nil
        }
        poseLock.lock()
        defer { poseLock.unlock() }
        if method == "display.pose.set" {
            let hinge: Int32
            if let raw = params["hinge_state"] {
                hinge = try poseInteger(raw, "hinge_state", 0...4)
            } else if let value = params["angle"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, (0...180).contains(value.doubleValue)
            {
                hinge = hingeState(forAngle: value.doubleValue)
            } else {
                throw GuestAPIError.invalidRequest("hinge_state (0-4) or angle (0-180 degrees) is required")
            }
            let orientation = try params["orientation"].map { try poseInteger($0, "orientation", 0...6) } ?? 1
            let device = try params["device_orientation"].map { try poseInteger($0, "device_orientation", 0...6) } ?? 1
            let tabletop = try params["tabletop"].map { try poseInteger($0, "tabletop", 0...255) } ?? 0
            guard vp_pose_set(Int64(orientation), device, hinge, tabletop) else {
                throw GuestAPIError.operationFailed("SpringBoard's test automation service is not available")
            }
        }
        guard let pose = vp_pose_get() as? [String: Any] else {
            throw GuestAPIError.operationFailed("SpringBoard's test automation service is not available")
        }
        return pose
    }

    /// The hinge state nearest an angle: closed below 30°, partly open below
    /// 150°, open flat from there.
    static func hingeState(forAngle angle: Double) -> Int32 {
        switch angle {
        case ..<30: 1
        case ..<150: 2
        default: 4
        }
    }

    private static func poseInteger(_ raw: Any, _ name: String, _ range: ClosedRange<Int>) throws -> Int32 {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == value.doubleValue.rounded(), range.contains(value.intValue)
        else {
            throw GuestAPIError.invalidRequest("\(name) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return value.int32Value
    }
}
