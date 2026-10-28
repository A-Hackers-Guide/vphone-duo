import AppKit

// MARK: - Fold Menu

/// An iPhone Duo's postures, view and finish, beside the window's own fold
/// slider. Control-Command with a digit, so no guest shortcut is taken.
extension VPhoneMenuController {
    func buildFoldMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Fold", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Fold")
        let postures: [(String, Double, String)] = [
            ("Closed", 0, "1"), ("Tent", 70, "2"), ("Laptop", 110, "3"), ("Open Flat", 180, "4"),
        ]
        for (title, angle, key) in postures {
            let posture = makeItem(title, action: #selector(foldToPosture(_:)), keyEquivalent: key, modifiers: [.command, .control])
            posture.tag = Int(angle)
            menu.addItem(posture)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(
            "Face the Lit Screen", action: #selector(resetDuoView), keyEquivalent: "0",
            modifiers: [.command, .control], symbol: "scope",
        ))
        let controls = makeItem("Hide Controls", action: #selector(toggleDuoControls(_:)), keyEquivalent: "h", modifiers: [.command, .control])
        controls.representedObject = "controls"
        menu.addItem(controls)
        menu.addItem(NSMenuItem.separator())
        for finish in VPhoneDuoView.Finish.allCases {
            let title = finish == .white ? "Star White" : "Space Black"
            let choice = makeItem(title, action: #selector(chooseDuoFinish(_:)))
            choice.representedObject = finish.rawValue
            menu.addItem(choice)
        }
        menu.delegate = foldMenuDelegate
        item.submenu = menu
        item.isHidden = true
        foldMenuItem = item
        return item
    }

    @objc private func foldToPosture(_ sender: NSMenuItem) {
        duoView?.animateHinge(to: Double(sender.tag))
    }

    @objc private func toggleDuoControls(_: NSMenuItem) {
        guard let duoView else { return }
        duoView.showsControls.toggle()
    }

    @objc private func resetDuoView() {
        duoView?.resetView()
    }

    @objc private func chooseDuoFinish(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let finish = VPhoneDuoView.Finish(rawValue: name) else { return }
        duoView?.setFinish(finish)
    }
}

/// Ticks the finish in use each time the Fold menu opens.
@MainActor
final class VPhoneFoldMenuDelegate: NSObject, NSMenuDelegate {
    weak var duoView: VPhoneDuoView?

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let name = item.representedObject as? String else { continue }
            if name == "controls" {
                item.title = duoView?.showsControls == false ? "Show Controls" : "Hide Controls"
                continue
            }
            item.state = name == duoView?.finish.rawValue ? .on : .off
        }
    }
}
