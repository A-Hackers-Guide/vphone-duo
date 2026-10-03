import Foundation
import VphonedNative

/// Keeps 169.254.0.0/16 routed over the virtual iPhone's USB link while the
/// host wants it (`vp_network_usb_link_route_set` explains why).
///
/// The routes go away whenever that link does (vphoned re-enumerates USB when
/// the profile UDID changes), and the link has no 169.254 address for a few
/// seconds after boot. So the wanted state is kept here and applied again: every
/// 2 seconds until it takes, then every 30; a route that already exists is left
/// alone.
///
/// Threading: every field is touched only on `queue`. That is the invariant
/// behind `@unchecked Sendable`.
final class GuestUSBLinkRoute: @unchecked Sendable {
    static let shared = GuestUSBLinkRoute()

    private let queue = DispatchQueue(label: "vphoned.usb-link-route")
    private var timer: DispatchSourceTimer?
    private var primary = "en0"
    /// Present while enabled, holding the primary interface, so vphoned turns
    /// the routes back on as it starts, before the host has connected.
    private static let savePath = "/var/root/Library/Preferences/com.vphone.vphoned.usb-link-route"

    func restoreOnStartup() {
        guard let saved = try? String(contentsOfFile: Self.savePath, encoding: .utf8) else { return }
        let primary = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = set(enabled: true, primary: primary.isEmpty ? "en0" : primary)
    }

    func set(enabled: Bool, primary: String) -> [String: Any] {
        queue.sync {
            self.primary = primary
            timer?.cancel()
            timer = nil
            if enabled {
                try? FileManager.default.createDirectory(atPath: (Self.savePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? primary.write(toFile: Self.savePath, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: Self.savePath)
            }
            let result = apply(enabled)
            if enabled {
                schedule(pending: result["pending"] as? Bool == true)
            }
            return result
        }
    }

    private func schedule(pending: Bool) {
        timer?.cancel()
        let interval: TimeInterval = pending ? 2 : 30
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stillPending = apply(true)["pending"] as? Bool == true
            if stillPending != pending {
                schedule(pending: stillPending)
            }
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    private func apply(_ enabled: Bool) -> [String: Any] {
        var error: NSString?
        guard let result = vp_network_usb_link_route_set(enabled, primary, &error) as? [String: Any] else {
            // No link address yet: the timer comes back to it.
            return ["enabled": enabled, "pending": true, "reason": error.map(String.init) ?? "unknown"]
        }
        return result
    }
}
