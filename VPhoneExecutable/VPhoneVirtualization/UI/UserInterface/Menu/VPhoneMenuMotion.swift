import AppKit

// MARK: - Motion Sensors

extension VPhoneMenuController {
    func buildMotionSensorsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Motion Sensors", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Motion Sensors")
        menu.autoenablesItems = false
        menu.addItem(makePanelItem(.gyroscope, "3D Gyroscope", keyEquivalent: "", symbol: "gyroscope"))
        item.submenu = menu
        return item
    }
}
