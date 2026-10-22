import Foundation
import VphonedNative

/// Publishes MiniDisplay hardware only on firmware that carries its source
/// device tree geometry. Apple's own display service supplies every frame.
enum GuestHomePodDisplay {
    static func startOnStartup() {
        vp_homepod_display_start()
    }

    static var capabilities: [String] {
        vp_homepod_display_is_configured() ? ["homepod_display"] : []
    }

    static func state() throws -> [String: Any] {
        guard let json = vp_homepod_display_copy_json() else {
            throw GuestAPIError.operationFailed("Could not read HomePod display state")
        }
        defer { free(json) }
        let data = Data(bytes: json, count: strlen(json))
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestAPIError.operationFailed("Invalid HomePod display state")
        }
        return state
    }
}
