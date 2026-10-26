import AppKit
import SwiftUI

/// The guest's terminal, in a window of its own beside the VM's screen.
///
/// A guest has no shell and the tvos preset has no debugger, so without this
/// the only way in is an RPC at a time. One window holds one session: closing
/// it ends the session, and opening it again starts a new one.
@MainActor
final class VPhoneShellWindowController {
    private var window: NSWindow?

    /// `program` is nil for vphoned's own JavaScript session, which needs
    /// nothing installed in the guest, or the name of a program from the
    /// bootstrap such as `bash`.
    func showWindow(control: VPhoneGuestControl, program: String? = nil) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = VPhoneShellTerminalView(control: control, program: program)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = VPhoneLocalization.text(program == nil ? "Debug Session" : "Terminal")
        window.subtitle = program ?? "vphoned"
        window.contentViewController = NSHostingController(rootView: view)
        window.contentMinSize = NSSize(width: 420, height: 240)
        window.setContentSize(NSSize(width: 760, height: 460))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.delegate = closeObserver

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// The session ends with the window, and the next open starts a fresh
    /// one: a terminal whose guest has gone is not worth keeping around.
    private lazy var closeObserver: VPhoneShellWindowObserver = .init { [weak self] in
        self?.window = nil
    }
}

/// Clears the controller's window reference when the window closes. The
/// window itself is not released on close, as every programmatically created
/// window here must not be, so something has to let go of it.
@MainActor
final class VPhoneShellWindowObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
