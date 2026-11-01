import AppKit
import UniformTypeIdentifiers

/// The preset pickers' Other…: a preset plist, which `vphone-cli` reads as it
/// reads a named preset and keeps a copy of in the machine.
@MainActor
enum VPhoneLaunchpadPresetFilePanel {
    static func choose(_ choose: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.propertyList]
        panel.message = String(localized: "Choose a patch preset plist.")
        panel.present { url in
            choose(url.path)
        }
    }
}
