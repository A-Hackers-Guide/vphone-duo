import Foundation
import IcliKit

// MARK: - Virtual Pointer

/// `input.pointer` and `input.scroll` go to IcliKit's virtual pointing device,
/// which lives as long as vphoned. iPadOS shows its pointer, and a button held
/// in a move is a pointer click, as a trackpad's is.
extension GuestAPI {
    private static let pointerLock = NSLock()
    /// The highest `seq` applied, under `pointerLock`.
    private nonisolated(unsafe) static var lastPointerSequence: UInt64 = 0

    /// Requests run concurrently, so a move sent earlier can land later;
    /// putting the pointer back where it was would make it jump. A move whose
    /// nonzero `sequence` is not above the last one applied is dropped, buttons
    /// and all, and still answers: a client sends button changes in order and
    /// nothing numbered past them until they are answered.
    static func movePointer(_ point: GuestPointerScroll.Point, sequence: UInt64, buttons: Int32) throws {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        if sequence != 0 {
            guard sequence > lastPointerSequence else { return }
            lastPointerSequence = sequence
        }
        _ = try pointerMove(x: point.x, y: point.y, normalized: true, buttons: PointerButtons(rawValue: Int(buttons)))
    }

    /// One scroll event to the view under the pointer, after putting the
    /// pointer at the scroll's position when it has one. The buttons held stay
    /// as they are.
    static func scrollPointer(_ scroll: GuestPointerScroll.Scroll) throws {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        if let point = scroll.pointer {
            _ = try pointerMove(x: point.x, y: point.y, normalized: true)
        }
        guard let phase = ScrollPhase(rawValue: scroll.phase.rawValue) else {
            throw GuestAPIError.invalidRequest("phase must be began, changed, ended or cancelled")
        }
        _ = try pointerScroll(phase, dx: scroll.dx, dy: scroll.dy)
    }
}
