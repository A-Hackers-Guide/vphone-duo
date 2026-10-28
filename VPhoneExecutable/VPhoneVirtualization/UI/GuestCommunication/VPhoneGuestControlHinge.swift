import CoreFoundation
import Foundation

// MARK: - Hinge RPC

/// What the iPhone Duo's virtual hinge sensor reports: 0 degrees closed,
/// 180 degrees open flat, published to the guest exactly as given.
struct VPhoneHingeConfiguration: Equatable, Sendable {
    var enabled: Bool
    var angle: Double
    var velocity: Double
}

struct VPhoneHingeReply: Equatable, Sendable {
    var configuration: VPhoneHingeConfiguration
    var providerRunning: Bool
    /// The angle the sensor in backboardd last published to iOS, when it runs.
    var publishedAngle: Double?
}

extension VPhoneGuestControl {
    var supportsHinge: Bool { guestCapabilities.contains("motion_hinge") }

    func readHinge() async throws -> VPhoneHingeReply {
        guard supportsHinge else { throw ControlError.unsupportedCapability("motion_hinge") }
        return try hingeReply(try await call("motion.hinge.get"))
    }

    func setHinge(_ value: VPhoneHingeConfiguration) async throws -> VPhoneHingeReply {
        guard supportsHinge else { throw ControlError.unsupportedCapability("motion_hinge") }
        let result = try await call("motion.hinge.set", params: [
            "enabled": value.enabled, "angle": value.angle, "velocity": value.velocity,
        ])
        return try hingeReply(result)
    }

    private func hingeReply(_ result: [String: Any]) throws -> VPhoneHingeReply {
        guard let enabled = result["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(),
              let angle = result["angle"] as? NSNumber, CFGetTypeID(angle) != CFBooleanGetTypeID(),
              (0...180).contains(angle.doubleValue),
              let velocity = result["velocity"] as? NSNumber, velocity.doubleValue.isFinite
        else { throw ControlError.protocolError("invalid hinge configuration") }
        return VPhoneHingeReply(
            configuration: VPhoneHingeConfiguration(enabled: enabled.boolValue, angle: angle.doubleValue,
                                                    velocity: velocity.doubleValue),
            providerRunning: result.bool("provider_running") ?? false,
            publishedAngle: ((result["provider"] as? [String: Any])?["configuration"] as? [String: Any])
                .flatMap { ($0["angle"] as? NSNumber)?.doubleValue },
        )
    }
}
