import AppKit

// MARK: - Features Menu

/// Sensors the host simulates for the guest: location, battery and camera.
/// Each is a titled section of this menu rather than a submenu, so every
/// control is one level down from the menu bar.
extension VPhoneMenuController {
    func buildFeaturesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Features", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Features")
        menu.autoenablesItems = false
        for section in [buildLocationSubmenu(), buildBatterySubmenu(), buildCameraSubmenu()] {
            if menu.numberOfItems > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            menu.addItem(NSMenuItem.sectionHeader(title: section.title))
            // Move, not copy: the controller keeps references to these items.
            let items = section.submenu?.items ?? []
            section.submenu?.removeAllItems()
            for child in items {
                menu.addItem(child)
            }
        }
        item.submenu = menu
        return item
    }
}
