import AppKit
import SwiftUI

@main
struct VPhoneLaunchpadApp: App {
    @NSApplicationDelegateAdaptor(VPhoneLaunchpadAppDelegate.self) private var delegate
    @State private var model = VPhoneLaunchpadModel()
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false

    init() {
        // AppKit must not restore saved window state. Everything starts from
        // the window's task, so a launch that restores a state with no window
        // in it never opens the control socket, and after a crash AppKit
        // holds the launch at an alert about reopening windows.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Window(Text(verbatim: "vphone-launchpad"), id: "main") {
            VPhoneLaunchpadRootView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        // Nor is any saved: the window's frame is kept under its own name.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Host Setup…") { model.present(.hostSetup) }
                Button("Core Bundle…") { model.present(.coreBundle) }
            }
        }

        MenuBarExtra(isInserted: $showsInMenuBar) {
            VPhoneLaunchpadMenuBarMenu()
                .environment(model)
        } label: {
            Label {
                Text(verbatim: "vphone-launchpad")
            } icon: {
                Image(systemName: "iphone")
            }
        }
    }
}

/// Guests keep running when Launchpad quits (their output goes to a log
/// file, not a pipe). A machine being created does not survive, so quitting
/// then asks first.
@MainActor
final class VPhoneLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPhoneLaunchpadModel?
    private let dockPolicy = VPhoneLaunchpadDockPolicy()

    func applicationDidFinishLaunching(_: Notification) {
        dockPolicy.start()
    }

    /// In menu bar mode the app stays behind in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !VPhoneLaunchpadMenuBar.isEnabled
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                return .terminateNow
            }
        #endif
        guard let model, model.machines.hasActiveCreation else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop Creating Machine?")
        alert.informativeText = String(localized: "Quitting stops creating this machine. You can retry later from the step where it stopped.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
