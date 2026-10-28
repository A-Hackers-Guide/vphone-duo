import AppKit
import Virtualization

// Stand-ins for the VM pieces the Duo view talks to.
final class VPhoneVirtualMachineView: NSView {
    var touches: [(Int, NSPoint)] = []
    var live = false
    override func draggingEntered(_: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_: any NSDraggingInfo) -> Bool { print("drop forwarded"); return true }
    private var queue: Task<Void, Never>?
    @discardableResult
    func sendNormalizedTouch(phase: Int, normalized: [NSPoint], swipeAim: Int, timestamp: TimeInterval = 0) -> Bool {
        touches.append((phase, normalized[0]))
        if ProcessInfo.processInfo.environment["DUO_QUIET"] == nil {
            print("touch phase=\(phase) x=\(String(format: "%.3f", normalized[0].x)) y=\(String(format: "%.3f", normalized[0].y))")
        }
        if live {
            let name = phase == 0 ? "down" : phase == 1 ? "move" : "up"
            let point = normalized[0]
            // In order, as the engine's input queue sends them.
            let previous = queue
            queue = Task { @MainActor in
                await previous?.value
                _ = await LiveVM.rpc("input.touch", ["phase": name, "x": point.x, "y": point.y, "normalized": true])
            }
        }
        return true
    }
}


// The core kit's edge flags, as the VM view takes them.
enum VPhoneDisplayGeometry {
    enum Edge: Int { case none = 0, top = 1, bottom = 2, right = 4, left = 8 }
}
