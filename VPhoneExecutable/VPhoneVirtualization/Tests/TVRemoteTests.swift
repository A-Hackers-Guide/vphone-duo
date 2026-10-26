import AppKit

// The standalone host harness supplies only localization, with no VM or guest.
enum VPhoneLocalization { static let bundle = Bundle.main }

@main
struct TVRemoteTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let view = VPhoneTVRemoteView(frame: NSRect(origin: .zero, size: VPhoneTVRemoteView.preferredSize))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.enabled = true
        var events: [VPhoneTVRemoteEvent] = []
        view.onEvent = { events.append($0) }
        let expected: [VPhoneTVRemoteControl: UInt32] = [
            .up: 0x42, .down: 0x43, .left: 0x44, .right: 0x45, .select: 0x41,
            .back: 0x46, .tv: 0x40, .playPause: 0xCD, .mute: 0xE2,
            .volumeUp: 0xE9, .volumeDown: 0xEA, .siri: 0xCF, .power: 0x30,
        ]
        for control in VPhoneTVRemoteControl.allCases {
            precondition(control.hid.page == 12 && control.hid.usage == expected[control])
            let button = try require(view.buttons[control])
            precondition(button.isAccessibilityElement() && button.accessibilityLabel()?.isEmpty == false)
            precondition(button.accessibilityPerformPress())
            precondition(events.suffix(2) == [.init(control: control, down: true), .init(control: control, down: false)])
        }
        precondition(events.count == 26)

        // Ring sectors do not overlap the center or reverse horizontal arrows.
        for (point, control) in [
            (NSPoint(x: 140, y: 90), VPhoneTVRemoteControl.up),
            (NSPoint(x: 140, y: 200), .down), (NSPoint(x: 85, y: 145), .left),
            (NSPoint(x: 195, y: 145), .right), (NSPoint(x: 140, y: 145), .select),
        ] {
            let hit = view.hitTest(view.convert(point, to: view.superview)) as? VPhoneTVRemoteButton
            precondition(hit?.control == control, "Hit area for \(control): \(String(describing: hit?.control))")
        }

        let down = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let select = try require(view.buttons[.select])
        events.removeAll()
        select.mouseDown(with: down)
        select.mouseDown(with: down) // Repeats must not create extra downs.
        try await Task.sleep(for: .milliseconds(80))
        precondition(events == [.init(control: .select, down: true)])
        // A simultaneous Return retains the press after pointer release.
        view.keyDown(with: try key(36, down: true))
        select.mouseUp(with: up)
        precondition(events.count == 1)
        view.keyUp(with: try key(36, down: false))
        precondition(events == [.init(control: .select, down: true), .init(control: .select, down: false)])

        events.removeAll()
        view.keyDown(with: try key(123, down: true))
        view.keyDown(with: try key(123, down: true))
        view.keyUp(with: try key(123, down: false))
        precondition(events == [.init(control: .left, down: true), .init(control: .left, down: false)])
        events.removeAll()
        let commandDown = try key(4, down: true, modifiers: .command)
        let commandUp = try key(4, down: false, modifiers: .command)
        precondition(!view.handleKey(commandDown, down: true))
        view.keyDown(with: try key(4, down: true))
        precondition(view.handleKey(commandUp, down: false))
        precondition(events == [.init(control: .tv, down: true), .init(control: .tv, down: false)])
        view.keyDown(with: try key(126, down: true))
        view.enabled = false // Same release path as connection loss.
        precondition(events.suffix(2) == [.init(control: .up, down: true), .init(control: .up, down: false)])
        let count = events.count
        view.releaseControls()
        precondition(!select.accessibilityPerformPress() && events.count == count)

        // Queued input cancelled before dispatch never reaches the next session.
        var delivered: [VPhoneTVRemoteEvent] = []
        let input = VPhoneTVRemoteInput { delivered.append($0) }
        input.connectionChanged(true)
        input.enqueue(.init(control: .tv, down: true))
        input.cancelPresses()
        await input.flush()
        precondition(delivered.isEmpty)
        input.enqueue(.init(control: .tv, down: true))
        input.enqueue(.init(control: .tv, down: false))
        await input.flush()
        precondition(delivered == [.init(control: .tv, down: true), .init(control: .tv, down: false)])

        // Closing while another input producer owns the queue invalidates a
        // waiting down, even though the transport task has already started.
        var waiting: CheckedContinuation<Void, Never>?
        var prepared = false
        var late: [VPhoneTVRemoteEvent] = []
        let suspended = VPhoneTVRemoteInput(prepare: {
            prepared = true
            await withCheckedContinuation { waiting = $0 }
        }) { late.append($0) }
        suspended.connectionChanged(true)
        suspended.enqueue(.init(control: .power, down: true))
        while !prepared { await Task.yield() }
        suspended.cancelPresses()
        waiting?.resume()
        await suspended.flush()
        precondition(late.isEmpty && suspended.needsRelease.isEmpty)

        // An AX activation is a completed tap before AppKit can change key
        // windows. Focus loss must preserve it, while cancelling a held key.
        var taps: [VPhoneTVRemoteEvent] = []
        let activated = VPhoneTVRemoteInput { taps.append($0) }
        activated.connectionChanged(true)
        view.enabled = true
        view.onEvent = { activated.enqueue($0) }
        precondition(select.accessibilityPerformPress())
        activated.cancelPresses()
        view.releaseControls()
        await activated.flush()
        precondition(taps == [.init(control: .select, down: true), .init(control: .select, down: false)])
        taps.removeAll()
        view.keyDown(with: try key(126, down: true))
        activated.cancelPresses() // Controller cancels before releasing the view.
        view.releaseControls()
        await activated.flush()
        precondition(taps.isEmpty)
        precondition(select.accessibilityPerformPress())
        activated.connectionChanged(false)
        activated.connectionChanged(true)
        await activated.flush()
        precondition(taps.isEmpty) // Completed taps cannot reach a later guest.

        // A failed release is remembered, retried first on reconnect, then
        // removed only after acknowledgement. Cancellation sends no orphan up.
        var failRelease = true
        var recovery: [VPhoneTVRemoteEvent] = []
        let reconnecting = VPhoneTVRemoteInput { event in
            if !event.down && failRelease { throw URLError(.networkConnectionLost) }
            recovery.append(event)
        }
        reconnecting.connectionChanged(true)
        reconnecting.enqueue(.init(control: .siri, down: true))
        reconnecting.enqueue(.init(control: .siri, down: false))
        await reconnecting.flush()
        precondition(reconnecting.needsRelease == [.siri])
        reconnecting.connectionChanged(false)
        failRelease = false
        reconnecting.connectionChanged(true)
        reconnecting.enqueue(.init(control: .select, down: true))
        reconnecting.enqueue(.init(control: .select, down: false))
        await reconnecting.flush()
        precondition(recovery == [.init(control: .siri, down: true), .init(control: .siri, down: false),
                                  .init(control: .select, down: true), .init(control: .select, down: false)])
        precondition(reconnecting.needsRelease.isEmpty)
        reconnecting.cancelPresses()
        await reconnecting.flush()
        precondition(recovery.count == 4)

        if CommandLine.arguments.count > 1 {
            view.enabled = true
            let bitmap = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("TV remote HID mapping, all 13 buttons, ring hit areas, holds, keyboard, cancellation and reconnect tests passed")
    }

    static func key(_ code: UInt16, down: Bool, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try require(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "TVRemoteTests", code: 1) }
        return value
    }
}
