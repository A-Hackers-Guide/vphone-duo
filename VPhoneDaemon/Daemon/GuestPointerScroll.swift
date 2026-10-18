import Foundation

// MARK: - Pointer Scroll

/// The parameters of `input.pointer` and `input.scroll`.
///
/// A scroll goes in phases, the way a trackpad's does: `began` before the
/// first delta, `changed` for each delta, then `ended` or `cancelled`. iPadOS
/// moves the view under the pointer by each delta, in interface points, and
/// does not decelerate by itself after `ended`: a client that wants the
/// content to run on (a trackpad's momentum) sends that as more `changed`
/// deltas before it ends the scroll.
///
/// Nothing here touches the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh`
/// builds this file on the Mac.
enum GuestPointerScroll {
    enum Phase: String {
        case began
        case changed
        case ended
        case cancelled

        /// The `IOHIDEventPhaseBits` value the scroll event carries.
        var bits: Int32 {
            switch self {
            case .began: 1
            case .changed: 2
            case .ended: 4
            case .cancelled: 8
            }
        }
    }

    /// A position in the interface as it is shown, 0...1 from the top-left
    /// corner, so the same in every orientation.
    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    struct Scroll: Equatable {
        var phase: Phase
        var dx: Double
        var dy: Double
        /// Where to put the pointer first; the scroll goes to the view under it.
        var pointer: Point?
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    /// The largest delta one event may carry, in points. A trackpad's are a
    /// few dozen; this only refuses nonsense.
    static let maximumDelta = 10000.0

    static func point(_ params: [String: Any]) throws(Problem) -> Point {
        guard let x = number(params["x"]), let y = number(params["y"]),
              (0 ... 1).contains(x), (0 ... 1).contains(y)
        else {
            throw Problem(message: "x and y must be numbers within 0...1")
        }
        return Point(x: x, y: y)
    }

    /// The largest `seq`: what a JSON number holds exactly.
    static let maximumSequence: UInt64 = 1 << 53

    /// `input.pointer`'s optional `seq`, 0 when there is none. A client that
    /// sends moves without waiting for each answer numbers them in increasing
    /// order; one that arrives after a higher number is dropped.
    static func sequence(_ params: [String: Any]) throws(Problem) -> UInt64 {
        guard let value = params["seq"] else { return 0 }
        guard let sequence = number(value), sequence >= 0, sequence <= Double(maximumSequence),
              sequence.rounded() == sequence
        else {
            throw Problem(message: "seq must be a whole number within 0...\(maximumSequence)")
        }
        return UInt64(sequence)
    }

    static func scroll(_ params: [String: Any]) throws(Problem) -> Scroll {
        guard let name = params["phase"] as? String, let phase = Phase(rawValue: name) else {
            throw Problem(message: "phase must be began, changed, ended or cancelled")
        }
        var deltas: [Double] = []
        for key in ["dx", "dy"] {
            guard let value = params[key] else {
                deltas.append(0)
                continue
            }
            guard let delta = number(value), abs(delta) <= maximumDelta else {
                throw Problem(message: "\(key) must be a number within ±\(Int(maximumDelta))")
            }
            deltas.append(delta)
        }
        var pointer: Point?
        if params["x"] != nil || params["y"] != nil {
            pointer = try point(params)
        }
        return Scroll(phase: phase, dx: deltas[0], dy: deltas[1], pointer: pointer)
    }

    /// A finite JSON number; a boolean is not one.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
