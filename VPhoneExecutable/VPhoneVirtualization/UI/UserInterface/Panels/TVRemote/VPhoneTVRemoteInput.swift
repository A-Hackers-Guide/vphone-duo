import Foundation
import IOKit.hid

// MARK: - Remote Events

enum VPhoneTVRemoteControl: String, CaseIterable, Hashable {
    case up, down, left, right, select, back, tv, playPause, mute, volumeUp, volumeDown, siri, power

    /// Consumer usages verified against tvOS 27.2 UIKitCore's
    /// __UIEventHIDPressTypeForKeyboardHIDEvent. MenuEscape is remote Back;
    /// ACBack maps to a different press type.
    var hid: (page: UInt32, usage: UInt32) {
        let usage: Int = switch self {
        case .up: kHIDUsage_Csmr_MenuUp
        case .down: kHIDUsage_Csmr_MenuDown
        case .left: kHIDUsage_Csmr_MenuLeft
        case .right: kHIDUsage_Csmr_MenuRight
        case .select: kHIDUsage_Csmr_MenuPick
        case .tv: kHIDUsage_Csmr_Menu
        case .playPause: kHIDUsage_Csmr_PlayOrPause
        case .mute: kHIDUsage_Csmr_Mute
        case .volumeUp: kHIDUsage_Csmr_VolumeIncrement
        case .volumeDown: kHIDUsage_Csmr_VolumeDecrement
        case .siri: kHIDUsage_Csmr_VoiceCommand
        case .power: kHIDUsage_Csmr_Power
        case .back: kHIDUsage_Csmr_MenuEscape
        }
        return (UInt32(kHIDPage_Consumer), UInt32(usage))
    }

    var symbol: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .select: "circle.fill"
        case .back: "chevron.left"
        case .tv: "tv"
        case .playPause: "playpause.fill"
        case .mute: "speaker.slash.fill"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        case .siri: "mic.fill"
        case .power: "power"
        }
    }

    var label: String.LocalizationValue {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .back: "Back"
        case .tv: "TV / Control Center"
        case .playPause: "Play / Pause"
        case .mute: "Mute"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .siri: "Siri"
        case .power: "Power"
        }
    }

    static func keyboard(_ code: UInt16) -> Self? {
        switch code {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .select
        case 53: .back
        case 49: .playPause
        case 4: .tv // H
        case 46: .mute // M
        case 24, 69: .volumeUp
        case 27, 78: .volumeDown
        case 1: .siri // S
        case 35: .power // P
        default: nil
        }
    }
}

struct VPhoneTVRemoteEvent: Equatable {
    let control: VPhoneTVRemoteControl
    let down: Bool
}

// MARK: - Ordered Delivery

/// Preserves down/up ordering without blocking AppKit. A disconnected release
/// is retried before new input when the agent reconnects. Queued downs from a
/// cancelled interaction can never reach a later guest connection.
@MainActor
final class VPhoneTVRemoteInput {
    typealias Send = @MainActor (VPhoneTVRemoteEvent) async throws -> Void
    private let send: Send
    private let prepare: (@MainActor () async -> Void)?
    private var queue: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private final class PressTicket { var completed = false }
    private var pendingPresses: [VPhoneTVRemoteControl: PressTicket] = [:]
    private(set) var connected = false
    private(set) var needsRelease: Set<VPhoneTVRemoteControl> = []
    var onError: ((Error) -> Void)?

    init(prepare: (@MainActor () async -> Void)? = nil, send: @escaping Send) {
        self.prepare = prepare
        self.send = send
    }

    func connectionChanged(_ connected: Bool) {
        guard self.connected != connected else { return }
        self.connected = connected
        generation &+= 1
        connectionGeneration &+= 1
        pendingPresses.removeAll()
        if connected {
            for control in VPhoneTVRemoteControl.allCases where needsRelease.contains(control) {
                enqueue(.init(control: control, down: false))
            }
        }
    }

    func enqueue(_ event: VPhoneTVRemoteEvent) {
        guard !event.down || connected else { return }
        let ticket: PressTicket?
        if event.down {
            let press = PressTicket()
            pendingPresses[event.control] = press
            ticket = press
        } else {
            pendingPresses.removeValue(forKey: event.control)?.completed = true
            ticket = nil
        }
        let previous = queue
        let generation = generation
        let connectionGeneration = connectionGeneration
        queue = Task { [self] in
            await previous?.value
            await prepare?()
            guard connected else { return }
            if event.down {
                // A completed AX/button tap remains intentional after panel
                // focus changes. An unfinished hold is cancelled; neither may
                // cross a guest connection boundary.
                guard connectionGeneration == self.connectionGeneration,
                      generation == self.generation || ticket?.completed == true else { return }
            }
            guard event.down || needsRelease.contains(event.control) else { return }
            if event.down { needsRelease.insert(event.control) }
            do {
                try await send(event)
                if !event.down { needsRelease.remove(event.control) }
            } catch {
                onError?(error)
            }
        }
    }

    func cancelPresses() {
        generation &+= 1
        pendingPresses.removeAll()
        for control in VPhoneTVRemoteControl.allCases where needsRelease.contains(control) {
            enqueue(.init(control: control, down: false))
        }
    }

    func flush() async { await queue?.value }
}
