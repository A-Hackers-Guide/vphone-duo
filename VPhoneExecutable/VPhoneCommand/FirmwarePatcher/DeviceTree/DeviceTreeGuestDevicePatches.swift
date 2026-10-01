// DeviceTreeGuestDevicePatches.swift — The iPad presentation of the vphone600 tree.
//
// vphone600ap is a virtual iPhone: `artwork-device-idiom` is "phone", the root
// `model` is iPhone99,11, and most `/product` properties are `syscfg/xxxx`
// placeholders (flag 0x8000) that no syscfg on a VM ever fills. An iPadOS
// userland reads the same nodes, so a guest restored from an iPad IPSW lays
// itself out as a phone unless the tree it boots says otherwise.
//
// The edits below give the installed tree the iPad's own answers, copied from
// that device's `DeviceTree.<board>.im4p` in the same IPSW:
//
//   - `/product` placeholders the iPad carries get its values; the phone-only
//     placeholders it does not carry (Dynamic Island, reachability, ringer,
//     volume-button geometry, CarPlay, Watch pairing...) are removed, which is
//     what "absent" means to MobileGestalt.
//   - The iPad-only multitasking capabilities are added.
//   - The root and `/product` identity becomes the iPad's, with VPHONE600AP kept
//     second in `compatible` so the platform expert still binds.
//
// What stays vphone600: everything that describes the virtual hardware —
// `graphics-featureset-class` (the paravirtual GPU is APPLE7, not the A17's
// APPLE9), `framebuffer-identifier`, `has-virtualization`, the guest agent port,
// memory class and boot flags.
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

    // MARK: - Edits

    /// One change to an existing node: a property set (added when missing) or
    /// removed.
    struct GuestEdit {
        enum Action {
            case set(PropertyValue)
            /// A present-or-absent boolean, stored with no value.
            case setEmpty
            case remove
        }

        let nodePath: [String]
        let property: String
        let action: Action
        let patchID: String
    }

    /// The edits that make the vphone600 tree present `device`.
    static func guestEdits(for device: VPhoneGuestDevice) -> [GuestEdit] {
        guard device.isPad else { return [] }
        let product = ["device-tree", "product"]
        var edits: [GuestEdit] = []

        // Idiom and artwork: what UIKit and SpringBoard lay out against.
        edits.append(GuestEdit(nodePath: product, property: "artwork-device-idiom",
                               action: .set(.string(device.artworkIdiom)), patchID: iPadArtworkPatch))
        edits.append(GuestEdit(nodePath: product, property: "artwork-device-subtype",
                               action: .set(.integer(device.artworkSubtype)), patchID: iPadArtworkPatch))
        edits.append(GuestEdit(nodePath: product, property: "artwork-scale-factor",
                               action: .set(.integer(device.artworkScale)), patchID: iPadArtworkPatch))

        // The rest of `/product`, as the device's own tree has it.
        for (name, value) in productProperties(for: device) {
            let action: GuestEdit.Action = switch value {
            case .none: .setEmpty
            case let .some(value): .set(value)
            }
            edits.append(GuestEdit(nodePath: product, property: name, action: action, patchID: iPadProductPatch))
        }
        for name in iPhoneOnlyProductProperties {
            edits.append(GuestEdit(nodePath: product, property: name, action: .remove, patchID: iPadProductPatch))
        }

        // An iPad has no ring/silent switch.
        edits.append(GuestEdit(nodePath: ["device-tree", "buttons"], property: "function-button_ringeren",
                               action: .remove, patchID: iPadButtonsPatch))

        // Identity: the product type MobileGestalt derives the device class from.
        let root = ["device-tree"]
        edits.append(GuestEdit(nodePath: root, property: "model",
                               action: .set(.string(device.productType)), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: root, property: "target-type",
                               action: .set(.string(device.targetType)), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: root, property: "target-sub-type",
                               action: .set(.string(device.uniqueModel)), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: root, property: "compatible",
                               action: .set(.bytes(compatible(for: device))), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: product, property: "fdr-product-type",
                               action: .set(.string(device.productType)), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: product, property: "sub-product-type",
                               action: .set(.string(device.productType)), patchID: iPadIdentityPatch))
        edits.append(GuestEdit(nodePath: product, property: "unique-model",
                               action: .set(.string(device.uniqueModel)), patchID: iPadIdentityPatch))
        return edits
    }

    /// `compatible` with the device's board first, so `hw.model` reads it, and
    /// VPHONE600AP kept for the platform expert's AppleVMApple1IO match.
    static func compatible(for device: VPhoneGuestDevice) -> Data {
        Data("\(device.uniqueModel)\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8)
    }

    /// vphone600 `/product` placeholders a real iPad does not carry. Left in,
    /// an unresolved placeholder would read as present.
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

    /// `/product` values copied from the device's own tree. A nil value is a
    /// present-or-absent boolean.
    static func productProperties(for device: VPhoneGuestDevice) -> [(String, PropertyValue?)] {
        switch device.productType {
        case VPhoneGuestDevice.iPad16_1.productType: j410Product
        default: []
        }
    }

    /// iPad mini (A17 Pro), `DeviceTree.j410ap.im4p` from iPadOS 26.6.2 (23G90).
    static let j410Product: [(String, PropertyValue?)] = [
        ("product-name", .string("iPad mini (A17 Pro)")),
        ("product-description", .string("iPad mini (A17 Pro)")),
        ("chrome-identifier", .string("com.apple.dt.devicekit.chrome.tablet3")),
        ("compatible-device-fallback", .string("iPad14,1")),
        ("display-corner-radius", .bytes(Data([0x2B, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]))),
        ("display-mirroring", .integer(1)),
        ("side-button-location", .bytes(Data([
            0x60, 0xC5, 0x01, 0x00, 0x6C, 0xB2, 0x02, 0x00, 0x49, 0x0D,
            0x00, 0x00, 0x78, 0x42, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00,
        ]))),
        ("front-cam-offset-from-center", .bytes(Data([
            0x64, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68, 0x12,
            0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))),
        ("rear-cam-offset-from-center", .bytes(Data([
            0x1E, 0x4C, 0x01, 0x00, 0x99, 0xD5, 0x00, 0x00, 0x71, 0x0C,
            0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))),
        ("thin-bezel", .integer(1)),
        ("ui-pip", nil),
        ("ui-background-quality", .integer(100)),
        ("ui-weather-quality", .integer(100)),
        ("assistant", .integer(1)),
        ("dictation", .integer(1)),
        ("offline-dictation", .integer(1)),
        ("builtin-mics", .integer(2)),
        // iPad multitasking: Slide Over, the overlay and pinned app slots.
        ("medusa-overlay-app-capability", .integer(1)),
        ("ui-floating-live-app", nil),
        ("ui-overlay-app", nil),
        ("ui-pinned-app", nil),
        // The iPad mini has no Stage Manager.
        ("disable-chamois", .integer(1)),
        ("natural-volume-arrangement", nil),
    ]

    // MARK: - Application

    /// Applies `guestEdits(for:)` to the parsed tree and records each change.
    func applyGuestEdits(root: DTNode) throws {
        for edit in Self.guestEdits(for: device) {
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
            case .setEmpty:
                after = Data()
            case let .set(value):
                after = try Self.encode(value)
            }

            if let after {
                if let index {
                    let property = node.properties[index]
                    guard property.value != after || property.flags != 0 else { continue }
                    property.value = after
                    property.flags = 0
                } else {
                    node.properties.append(DTProperty(name: edit.property, flags: 0, value: after, valueOffset: 0))
                }
            }

            let path = (edit.nodePath + [edit.property]).joined(separator: "/")
            let description = switch edit.action {
            case .remove: "Remove \(path) (not on \(device.productType))"
            case .setEmpty, .set: "Set \(path) for \(device.productType)"
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

    /// A value at its natural size: a NUL-terminated string, a 32-bit integer.
    private static func encode(_ value: PropertyValue) throws -> Data {
        switch value {
        case let .string(text):
            var data = Data(text.utf8)
            data.append(0)
            return data
        case let .integer(number):
            var little = UInt32(truncatingIfNeeded: number).littleEndian
            return Data(bytes: &little, count: 4)
        case let .bytes(data):
            return data
        }
    }
}
