// DeviceTreeGuestDevicePatches.swift — The iPad presentation of the vphone600 tree.
//
// vphone600ap is a virtual iPhone: `artwork-device-idiom` is "phone", the root
// `model` is iPhone99,11, and most `/product` properties are `syscfg/xxxx`
// placeholders (flag 0x8000) that no syscfg on a VM ever fills. An iPadOS
// userland reads the same nodes, so a guest restored from an iPad IPSW lays
// itself out as a phone unless the tree it boots says otherwise.
//
// The answers come from the iPad's own device tree, `DeviceTree.<board>.im4p`,
// which the IPSW carries and the restore tree keeps:
//
//   - the `/product` properties in `copiedProductProperties` take the board's
//     values, and are removed where the board has none — so an iPad mini keeps
//     `disable-chamois` and an M-series iPad, which has Stage Manager, does not;
//   - the phone-only placeholders no iPad carries (Dynamic Island,
//     reachability, ringer switch, volume-button geometry, CarPlay, Watch
//     pairing) are removed, which is what "absent" means to MobileGestalt;
//   - the root and `/product` identity becomes the board's, with VPHONE600AP
//     kept second in `compatible` so the platform expert still binds.
//
// What stays vphone600: everything that describes the virtual hardware —
// `graphics-featureset-class` (the paravirtual GPU is APPLE7, not the iPad's),
// `framebuffer-identifier`, `has-virtualization`, the guest agent port, memory
// class and boot flags.
//
// Only the installed tree carries these. Restore boots `RestoreDeviceTree`,
// which keeps the iPhone99,11 identity `restored_external` checks against the
// manifest; see `FirmwareManifest.separateGuestDeviceTree`.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

extension DeviceTreePatcher {
    // MARK: - Role

    /// Which of the VM's device trees a patcher is rewriting.
    public enum TreeRole: Sendable {
        /// The one file an iPhone guest restores and boots with.
        case shared
        /// An iPad guest's `RestoreDeviceTree`: patched exactly as an iPhone
        /// guest's tree, so restore sees the board it always has.
        case restore
        /// An iPad guest's installed `DeviceTree`, which carries its identity.
        case installed
    }

    // MARK: - Patch IDs

    static let iPadArtworkPatch = "devicetree-cfw-ipad_artwork"
    static let iPadProductPatch = "devicetree-cfw-ipad_product"
    static let iPadButtonsPatch = "devicetree-cfw-ipad_buttons"
    static let iPadIdentityPatch = "devicetree-cfw-ipad_identity"

    // MARK: - What Is Copied

    /// `/product` properties taken from the board's tree, by patch.
    static let copiedProductProperties: [(name: String, patchID: String)] = [
        // What UIKit and SpringBoard lay out against.
        ("artwork-device-idiom", iPadArtworkPatch),
        ("artwork-device-subtype", iPadArtworkPatch),
        ("artwork-scale-factor", iPadArtworkPatch),
        // The device MobileGestalt reports.
        ("fdr-product-type", iPadIdentityPatch),
        ("sub-product-type", iPadIdentityPatch),
        ("unique-model", iPadIdentityPatch),
        // Name, chrome, and the panel and camera geometry.
        ("product-name", iPadProductPatch),
        ("product-description", iPadProductPatch),
        ("chrome-identifier", iPadProductPatch),
        ("compatible-device-fallback", iPadProductPatch),
        ("display-corner-radius", iPadProductPatch),
        ("display-mirroring", iPadProductPatch),
        ("side-button-location", iPadProductPatch),
        ("front-cam-offset-from-center", iPadProductPatch),
        ("rear-cam-offset-from-center", iPadProductPatch),
        ("thin-bezel", iPadProductPatch),
        ("ui-pip", iPadProductPatch),
        ("ui-background-quality", iPadProductPatch),
        ("ui-weather-quality", iPadProductPatch),
        ("assistant", iPadProductPatch),
        ("dictation", iPadProductPatch),
        ("offline-dictation", iPadProductPatch),
        ("builtin-mics", iPadProductPatch),
        // Multitasking: Slide Over, the overlay and pinned app slots, and
        // `disable-chamois`, which turns Stage Manager off where the board has it.
        ("medusa-overlay-app-capability", iPadProductPatch),
        ("ui-floating-live-app", iPadProductPatch),
        ("ui-overlay-app", iPadProductPatch),
        ("ui-pinned-app", iPadProductPatch),
        ("disable-chamois", iPadProductPatch),
        ("natural-volume-arrangement", iPadProductPatch),
    ]

    /// vphone600 `/product` properties that describe a phone. Removed unless the
    /// board's tree has them too.
    static let iPhoneOnlyProductProperties = [
        "island-notch-location",
        "large-format-phone",
        "ui-reachability",
        "oled-display",
        "siri-gesture",
        "hme-in-arkit",
        "location-reminders",
        "volume-up-button-location",
        "volume-down-button-location",
        "watch-companion",
        "carplay-2",
        "car-integration",
    ]

    /// Root properties taken from the board's tree. `compatible` is rebuilt.
    static let copiedRootProperties = ["model", "target-type", "target-sub-type"]

    /// The placeholder bit in a property's flags: the value is a `syscfg/` key,
    /// not data.
    static let placeholderFlag: UInt16 = 0x8000

    // MARK: - Edits

    /// One change to an existing node: a property set (added when missing) or
    /// removed.
    struct GuestEdit {
        enum Action {
            case set(Data)
            case remove
        }

        let nodePath: [String]
        let property: String
        let action: Action
        let patchID: String
    }

    /// The edits that make the vphone600 tree present the board whose tree is
    /// `source`.
    static func guestEdits(from source: DTNode) throws -> [GuestEdit] {
        let product = ["device-tree", "product"]
        let sourceProduct = try child(of: source, named: "product")
        var edits: [GuestEdit] = []

        func value(_ node: DTNode, _ name: String) -> Data? {
            guard let property = node.properties.first(where: { $0.name == name }),
                  property.flags & placeholderFlag == 0
            else { return nil }
            return property.value
        }

        for (name, patchID) in copiedProductProperties {
            let action: GuestEdit.Action = value(sourceProduct, name).map { .set($0) } ?? .remove
            edits.append(GuestEdit(nodePath: product, property: name, action: action, patchID: patchID))
        }
        for name in iPhoneOnlyProductProperties {
            if let board = value(sourceProduct, name) {
                edits.append(GuestEdit(nodePath: product, property: name, action: .set(board), patchID: iPadProductPatch))
            } else {
                edits.append(GuestEdit(nodePath: product, property: name, action: .remove, patchID: iPadProductPatch))
            }
        }

        // An iPad has no ring/silent switch.
        let sourceButtons = try? child(of: source, named: "buttons")
        if sourceButtons.flatMap({ value($0, "function-button_ringeren") }) == nil {
            edits.append(GuestEdit(nodePath: ["device-tree", "buttons"], property: "function-button_ringeren",
                                   action: .remove, patchID: iPadButtonsPatch))
        }

        for name in copiedRootProperties {
            guard let board = value(source, name) else {
                throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no root \(name)")
            }
            edits.append(GuestEdit(nodePath: ["device-tree"], property: name, action: .set(board), patchID: iPadIdentityPatch))
        }
        guard let compatible = value(source, "compatible"),
              let first = compatible.split(separator: 0, omittingEmptySubsequences: true).first
        else {
            throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no root compatible")
        }
        edits.append(GuestEdit(nodePath: ["device-tree"], property: "compatible",
                               action: .set(Self.compatible(board: Data(first))), patchID: iPadIdentityPatch))
        return edits
    }

    /// `compatible` with the board first, so `hw.model` reads it, and
    /// VPHONE600AP kept for the platform expert's AppleVMApple1IO match.
    static func compatible(board: Data) -> Data {
        board + Data("\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8)
    }

    private static func child(of node: DTNode, named name: String) throws -> DTNode {
        for child in node.children {
            for property in child.properties where property.name == "name" {
                if property.value.prefix(while: { $0 != 0 }) == Data(name.utf8) {
                    return child
                }
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: the board's tree has no \(name) node")
    }

    // MARK: - Application

    /// Applies `guestEdits(from:)` to the parsed tree and records each change.
    func applyGuestEdits(root: DTNode) throws {
        guard let sourceTree else {
            throw PatcherError.fileNotFound(
                "DeviceTree: \(device.productType)'s own device tree (\(device.boardDeviceTreePath)) is needed to present it",
            )
        }
        let source = try parsePayload(sourceTree)
        for edit in try Self.guestEdits(from: source) {
            guard gateAllows(edit.patchID) else { continue }
            let node = try resolveNode(root, path: edit.nodePath)
            let index = node.properties.firstIndex { $0.name == edit.property }
            let before = index.map { node.properties[$0].value } ?? Data()

            let after: Data?
            switch edit.action {
            case .remove:
                guard let index else { continue }
                node.properties.remove(at: index)
                after = nil
            case let .set(value):
                if let index {
                    let property = node.properties[index]
                    guard property.value != value || property.flags != 0 else { continue }
                    property.value = value
                    property.flags = 0
                } else {
                    node.properties.append(DTProperty(name: edit.property, flags: 0, value: value, valueOffset: 0))
                }
                after = value
            }

            let path = (edit.nodePath + [edit.property]).joined(separator: "/")
            let description = switch edit.action {
            case .remove: "Remove \(path) (not on \(device.productType))"
            case .set: "Set \(path) as on \(device.productType)"
            }
            patches.append(PatchRecord(
                patchID: edit.patchID,
                component: component,
                fileOffset: 0,
                virtualAddress: nil,
                originalBytes: before,
                patchedBytes: after ?? Data(),
                description: description,
            ))
            if verbose {
                print("  \(after == nil ? "-prop " : "=prop "): /\(path) \(before.hex) → \((after ?? Data()).hex)  [\(edit.patchID)]")
            }
        }
    }
}
