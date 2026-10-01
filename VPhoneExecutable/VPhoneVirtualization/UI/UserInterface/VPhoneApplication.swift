import AppKit
import VPhoneCoreKit

// MARK: - Application

/// Offers each key press in the VM window to the main menu before the VM view
/// can take it, takes Esc for the guest's back gesture, and carries the keys the
/// virtual keyboard cannot.
///
/// `capturesSystemKeys` makes `VZVirtualMachineView` install a local event
/// monitor that sends every key to the guest and swallows it. AppKit runs
/// local monitors in the order they were added, and the view adds its own
/// again each time it becomes first responder or its window becomes key, so
/// a monitor of ours always runs after it. `sendEvent(_:)` runs before any
/// local monitor, so the menu lookup, the Esc handling and the dropped keys
/// all live here.
final class VPhoneApplication: NSApplication {
    /// Keys whose key-down a menu item took. Their key-up is dropped too, so
    /// the guest never sees a release without a press.
    private var menuKeyCodes = Set<UInt16>()

    /// Keys whose key-down went to the guest through vphoned, so their key-up
    /// goes the same way.
    private var forwardedKeyCodes = Set<UInt16>()

    /// The guest 🌐 is held through, while it is held. fn's release only arrives
    /// while the window is key, so leaving the window lets go of it here.
    private weak var globeHolder: VPhoneGuestControl?
    private var resignObserver: NSObjectProtocol?

    /// `kVK_Escape`. Intercepted here instead of as a menu key equivalent:
    /// AppKit's matching for a modifier-less Esc is not dependable, and a missed
    /// match forwards the key to the guest as a plain Escape — which is what
    /// made the back gesture take a second press.
    private static let escapeKeyCode: UInt16 = 53

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged,
              let view = event.window?.firstResponder as? VPhoneVirtualMachineView
        else {
            super.sendEvent(event)
            return
        }
        if event.type == .flagsChanged {
            forwardGlobe(event, view: view)
            super.sendEvent(event)
            return
        }
        // Esc replays the guest's back gesture: iOS has no back key, and a
        // forwarded Escape only reads as cancel. The press and its release both
        // stop here, so the guest sees neither. An iPad has a real Esc key —
        // it cancels a composition, a sheet or a menu — so there it goes
        // through like any other key.
        if event.keyCode == Self.escapeKeyCode, view.escapeIsBackGesture {
            if event.type == .keyDown {
                view.performBackGesture()
            }
            return
        }
        if forwardDroppedKey(event, view: view) {
            return
        }
        if event.type == .keyUp {
            if menuKeyCodes.remove(event.keyCode) == nil {
                super.sendEvent(event)
            }
            return
        }
        if mainMenu?.performKeyEquivalent(with: event) == true {
            menuKeyCodes.insert(event.keyCode)
            return
        }
        super.sendEvent(event)
    }

    // MARK: - Keys the Virtual Keyboard Drops

    /// fn / 🌐 reaches AppKit only as a flags change, and the virtual USB
    /// keyboard has no field for it. vphoned presses the guest's 🌐 for it, held
    /// for as long as fn is, so 🌐 alone switches the input source and 🌐
    /// shortcuts work. The event still goes on to the view, which keeps the
    /// virtual keyboard's own modifier state in step.
    private func forwardGlobe(_ event: NSEvent, view: VPhoneVirtualMachineView) {
        guard event.keyCode == VPhoneGuestKeyMap.functionKeyCode, let control = view.control else { return }
        let globe = VPhoneGuestKeyMap.globe
        if event.modifierFlags.contains(.function) {
            guard globeHolder == nil else { return }
            globeHolder = control
            control.sendHIDDown(page: globe.page, usage: globe.usage)
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: event.window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseGlobe() }
            }
        } else {
            releaseGlobe()
        }
    }

    private func releaseGlobe() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        guard let holder = globeHolder else { return }
        globeHolder = nil
        let globe = VPhoneGuestKeyMap.globe
        holder.sendHIDUp(page: globe.page, usage: globe.usage)
    }

    /// Sends a key `_VZKeyboard` would drop — the JIS input-mode and character
    /// keys, Context Menu, Insert, volume — through vphoned. Returns whether the
    /// event was one of them; it then goes no further.
    private func forwardDroppedKey(_ event: NSEvent, view: VPhoneVirtualMachineView) -> Bool {
        guard let usage = VPhoneGuestKeyMap.usage(forDroppedKeyCode: event.keyCode),
              let control = view.control
        else { return false }
        if event.type == .keyDown {
            // The guest repeats a held key itself.
            guard !event.isARepeat, forwardedKeyCodes.insert(event.keyCode).inserted else { return true }
            control.sendHIDDown(page: usage.page, usage: usage.usage)
        } else if forwardedKeyCodes.remove(event.keyCode) != nil {
            control.sendHIDUp(page: usage.page, usage: usage.usage)
        }
        return true
    }
}
