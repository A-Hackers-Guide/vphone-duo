import Foundation
import GhosttyTerminal
import SwiftUI

// MARK: - Theme

/// The terminal's look. Both sides of the theme are the same dark palette:
/// this is a research instrument whose window sits beside the guest's screen,
/// not a document that should follow the system appearance.
enum VPhoneShellTerminalTheme {
    static let configuration = TerminalConfiguration {
        $0.withCursorStyle(.block)
        $0.withCursorStyleBlink(true)
        $0.withFontSize(11)
        $0.withCustom("window-padding-color", "extend")
    }

    static let theme = TerminalTheme(light: palette(), dark: palette())

    private static func palette() -> TerminalConfiguration {
        TerminalConfiguration {
            $0.withBackground("1a1a1a")
            $0.withForeground("ffffff")
            $0.withCursorColor("98989d")
            $0.withCursorText("1a1a1a")
            $0.withSelectionBackground("333333")
            $0.withSelectionForeground("ffffff")
            let colors = [
                "#1a1a1a", "#cc372e", "#26a439", "#cdac08", "#0869cb", "#9647bf", "#479ec2", "#98989d",
                "#464646", "#ff453a", "#32d74b", "#e5bc00", "#0a84ff", "#bf5af2", "#69c9f2", "#ffffff",
            ]
            for (index, color) in colors.enumerated() {
                $0.withPalette(index, color: color)
            }
        }
    }
}

// MARK: - The Session

/// Holds the terminal and the guest channel together.
///
/// Neither can be built first: the terminal needs somewhere to send what is
/// typed before a channel exists, and the channel needs the terminal to
/// deliver what the guest says. The box is what breaks that, and it is also
/// where the channel goes when the session ends, so a keystroke after the
/// fact reaches nothing instead of a closed connection.
final class VPhoneShellTerminalLink: @unchecked Sendable {
    let session: InMemoryTerminalSession

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var channel: VPhoneGuestShellChannel?

        func current() -> VPhoneGuestShellChannel? {
            lock.lock()
            defer { lock.unlock() }
            return channel
        }

        func set(_ channel: VPhoneGuestShellChannel?) {
            lock.lock()
            let previous = self.channel
            self.channel = channel
            lock.unlock()
            if channel == nil { previous?.close() }
        }
    }

    private let box = Box()
    private let opened = Date()

    init() {
        let box = self.box
        session = InMemoryTerminalSession(
            write: { data in box.current()?.send(data) },
            resize: { viewport in
                box.current()?.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            },
        )
    }

    /// Opens a session in the guest. A refusal is written into the terminal
    /// rather than thrown: the window is already on screen, and the reason is
    /// the only thing it has to show.
    func connect(control: VPhoneGuestControl, program: String?) async {
        do {
            let channel = try await VPhoneGuestShellChannel.open(
                control: control,
                options: VPhoneGuestShellChannel.Options(program: program),
                onOutput: { [session] data in session.receive(data) },
                onEnd: { [weak self] ending in self?.finish(ending) },
            )
            box.set(channel)
        } catch {
            session.receive("\r\n\(error)\r\n")
            session.finish(exitCode: 1, runtimeMilliseconds: elapsed())
        }
    }

    /// Closing the window ends the session; the guest hangs its terminal up
    /// and anything the script started goes with it.
    func disconnect() {
        box.current()?.close()
    }

    private func finish(_ ending: VPhoneGuestShellChannel.Ending) {
        let code: UInt32
        switch ending {
        case let .exited(status):
            session.receive("\r\n[session exited with status \(status)]\r\n")
            code = UInt32(truncatingIfNeeded: status)
        case let .signalled(number):
            session.receive("\r\n[session ended on signal \(number)]\r\n")
            code = UInt32(128 + number)
        case let .failed(message):
            session.receive("\r\n[\(message)]\r\n")
            code = 1
        }
        box.set(nil)
        session.finish(exitCode: code, runtimeMilliseconds: elapsed())
    }

    private func elapsed() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince(opened)) * 1000)
    }
}

// MARK: - The View

/// A terminal in the guest. `program` is nil for vphoned's own JavaScript
/// session, which needs nothing installed, or the name of a program from the
/// bootstrap.
struct VPhoneShellTerminalView: View {
    let control: VPhoneGuestControl
    let program: String?

    @StateObject private var terminal = TerminalViewState(
        theme: VPhoneShellTerminalTheme.theme,
        terminalConfiguration: VPhoneShellTerminalTheme.configuration,
    )
    @State private var link = VPhoneShellTerminalLink()

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .background(Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255))
            .task {
                terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(link.session))
                await link.connect(control: control, program: program)
            }
            .onDisappear { link.disconnect() }
    }
}
