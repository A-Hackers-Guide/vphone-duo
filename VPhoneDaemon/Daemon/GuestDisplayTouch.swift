import Foundation
import IcliKit
import VphonedNative

// MARK: - Touches on an Identified Panel

/// Touches for a guest whose display the host gave an identifier, as an iPhone
/// Duo guest booted on its inner panel has.
///
/// backboardd routes a touch to its sender's display. icli's touches carry a
/// sender that names none, which reaches the display only while it has no
/// identifier. vphoned's injector sends them under the panel touchscreen
/// service in backboardd, which names the display
/// (`VPhoneGuestComponents/Hinge/VPhonePanelTouch.m`); these gestures go
/// through it while that service is up. Every other guest keeps icli's.
enum GuestDisplayTouch {
    static var isNeeded: Bool { vp_hid_panel_touch_available() }

    /// The screen in points, as `device.screen` reports it.
    private static func screen() throws -> (width: Double, height: Double) {
        let info = screenInfo()
        guard let width = (info["width"] as? NSNumber)?.doubleValue,
              let height = (info["height"] as? NSNumber)?.doubleValue, width > 0, height > 0
        else { throw GuestAPIError.operationFailed("the screen size is not known") }
        return (width, height)
    }

    private static func normalized(_ x: Double, _ y: Double) throws -> (Double, Double) {
        let size = try screen()
        guard x.isFinite, y.isFinite, (0 ... size.width).contains(x), (0 ... size.height).contains(y) else {
            throw GuestAPIError.invalidRequest("coordinates must be finite points inside the screen")
        }
        return (x / size.width, y / size.height)
    }

    private static func pause(_ seconds: Double) {
        usleep(useconds_t(max(seconds, 0) * 1_000_000))
    }

    /// One phase of a touch; `x` and `y` are normalized unless `normalized`
    /// is false.
    static func touch(_ phase: Int32, x: Double, y: Double, normalized isNormalized: Bool) throws {
        let point = isNormalized ? (x, y) : try normalized(x, y)
        vp_hid_touch_edge(phase, point.0, point.1, 0)
    }

    static func tap(x: Double, y: Double) throws -> [String: Any] {
        let (u, v) = try normalized(x, y)
        vp_hid_touch_edge(0, u, v, 0)
        pause(0.05)
        vp_hid_touch_edge(3, u, v, 0)
        return ["x": x, "y": y]
    }

    static func doubleTap(x: Double, y: Double, interval: Double) throws -> [String: Any] {
        _ = try tap(x: x, y: y)
        pause(min(interval, 1))
        return try tap(x: x, y: y)
    }

    static func longPress(x: Double, y: Double, seconds: Double) throws -> [String: Any] {
        let (u, v) = try normalized(x, y)
        vp_hid_touch_edge(0, u, v, 0)
        pause(min(seconds, 60))
        vp_hid_touch_edge(3, u, v, 0)
        return ["x": x, "y": y, "seconds": seconds]
    }

    static func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int) throws -> [String: Any] {
        guard (1 ... 2000).contains(steps) else { throw GuestAPIError.invalidRequest("steps must be 1–2000") }
        let (u1, v1) = try normalized(x1, y1)
        let (u2, v2) = try normalized(x2, y2)
        vp_hid_touch_edge(0, u1, v1, 0)
        for step in 1 ... steps {
            let t = Double(step) / Double(steps)
            pause(min(seconds, 60) / Double(steps))
            vp_hid_touch_edge(1, u1 + (u2 - u1) * t, v1 + (v2 - v1) * t, 0)
        }
        vp_hid_touch_edge(3, u2, v2, 0)
        return ["from": [x1, y1], "to": [x2, y2]]
    }
}
