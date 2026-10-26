import AppKit

/// One remote per VM process. Opening it never changes guest setup or pairing.
@MainActor
final class VPhoneTVRemoteWindowController: NSWindowController, NSWindowDelegate {
    private let control: VPhoneGuestControl
    private var face: VPhoneTVRemoteView?
    private let input: VPhoneTVRemoteInput

    init(control: VPhoneGuestControl) {
        self.control = control
        input = VPhoneTVRemoteInput(prepare: { [weak control] in
            await control?.waitForQueuedInput()
        }) { [weak control] event in
            guard let control else { throw VPhoneGuestControl.ControlError.notConnected }
            let hid = event.control.hid
            _ = try await control.call("input.hid", params: [
                "page": hid.page, "usage": hid.usage, "down": event.down,
            ])
            // Keep an AX tap visible even when down/up share a run-loop turn.
            if event.down { try await Task.sleep(for: .milliseconds(60)) }
        }
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if window == nil { makeWindow() }
        connectionChanged()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func connectionChanged() {
        let connected = control.isConnected && control.guestCapabilities.contains("hid")
        input.connectionChanged(connected)
        face?.enabled = connected
    }

    private func makeWindow() {
        let face = VPhoneTVRemoteView(frame: NSRect(origin: .zero, size: VPhoneTVRemoteView.preferredSize))
        face.onEvent = { [weak self] in self?.input.enqueue($0) }
        input.onError = { [weak face] in face?.showError($0) }
        self.face = face

        let panel = NSPanel(
            contentRect: face.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false,
        )
        panel.title = String(localized: "Apple TV Remote", bundle: VPhoneLocalization.bundle)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = face
        panel.contentMinSize = NSSize(width: 240, height: 582)
        panel.contentAspectRatio = VPhoneTVRemoteView.preferredSize
        panel.setFrameAutosaveName("vphone-panel-tv-remote")
        panel.delegate = self
        if !panel.setFrameUsingName("vphone-panel-tv-remote") { panel.center() }
        window = panel
    }

    private func releaseControls() {
        input.cancelPresses()
        face?.releaseControls()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { releaseControls() }
    }

    nonisolated func windowDidMiniaturize(_ notification: Notification) {
        MainActor.assumeIsolated { releaseControls() }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { releaseControls() }
    }

    override func close() {
        releaseControls()
        super.close()
    }
}
