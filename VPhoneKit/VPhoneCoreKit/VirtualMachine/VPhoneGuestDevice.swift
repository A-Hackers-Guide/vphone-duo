import Foundation

// MARK: - Guest Device

/// The Apple device whose restore IPSW supplies the guest's OS image.
///
/// The boot chain, kernel, SEP and device tree always come from the PCC
/// `vresearch101ap` / `vphone600ap` identities. Only the userland changes with
/// the device: an iPhone17,3 IPSW gives the guest iOS, an iPad IPSW gives it
/// iPadOS. The device tree then has to present the matching idiom, artwork
/// and product type, or the iPadOS userland lays itself out as a phone.
///
/// The identity and `/product` values come from the device's own
/// `DeviceTree.<deviceClass>.im4p`, which the IPSW carries and `fw prepare`
/// keeps in the restore tree. What a device tree does not say — the panel's
/// size and density — is recorded here.
public struct VPhoneGuestDevice: Sendable, Equatable {
    public enum Family: String, Codable, Sendable {
        case iPhone
        case iPad
    }

    public let family: Family
    /// `Ap,ProductType`, e.g. `iPad16,1`.
    public let productType: String
    /// BuildManifest `DeviceClass`, and the board in `DeviceTree.<board>.im4p`.
    public let deviceClass: String
    /// The marketing name, for logs and prompts.
    public let productName: String
    /// The guest display, as the device's panel has it.
    public let screen: VPhoneVirtualMachineManifest.ScreenConfig

    public init(
        family: Family,
        productType: String,
        deviceClass: String,
        productName: String,
        screen: VPhoneVirtualMachineManifest.ScreenConfig,
    ) {
        self.family = family
        self.productType = productType
        self.deviceClass = deviceClass
        self.productName = productName
        self.screen = screen
    }

    public var isPad: Bool {
        family == .iPad
    }

    // MARK: - Known Devices

    /// iPhone 16 (D47AP), the device every catalog IPSW targets.
    public static let iPhone17_3 = VPhoneGuestDevice(
        family: .iPhone,
        productType: "iPhone17,3",
        deviceClass: "d47ap",
        productName: "iPhone 16",
        screen: .default,
    )

    private static func iPad(
        _ productType: String,
        _ deviceClass: String,
        _ productName: String,
        width: Int,
        height: Int,
        pixelsPerInch: Int = 264,
    ) -> VPhoneGuestDevice {
        VPhoneGuestDevice(
            family: .iPad,
            productType: productType,
            deviceClass: deviceClass,
            productName: productName,
            screen: .init(width: width, height: height, pixelsPerInch: pixelsPerInch, scale: 2.0),
        )
    }

    /// iPad mini (A17 Pro): 8.3-inch, 1488x2266 at 326 ppi, 744x1133 points.
    public static let iPad16_1 = iPad("iPad16,1", "j410ap", "iPad mini (A17 Pro)", width: 1488, height: 2266, pixelsPerInch: 326)
    /// iPad (A16): 11-inch, 1640x2360, 820x1180 points.
    public static let iPad15_7 = iPad("iPad15,7", "j481ap", "iPad (A16)", width: 1640, height: 2360)
    /// iPad Air 11-inch (M3): 1640x2360, 820x1180 points.
    public static let iPad15_3 = iPad("iPad15,3", "j607ap", "iPad Air 11-inch (M3)", width: 1640, height: 2360)
    /// iPad Air 13-inch (M3): 2048x2732, 1024x1366 points.
    public static let iPad15_5 = iPad("iPad15,5", "j637ap", "iPad Air 13-inch (M3)", width: 2048, height: 2732)
    /// iPad Pro 11-inch (M4): 1668x2420, 834x1210 points.
    public static let iPad16_3 = iPad("iPad16,3", "j717ap", "iPad Pro 11-inch (M4)", width: 1668, height: 2420)
    /// iPad Pro 13-inch (M4): 2064x2752, 1032x1376 points.
    public static let iPad16_5 = iPad("iPad16,5", "j720ap", "iPad Pro 13-inch (M4)", width: 2064, height: 2752)
    /// iPad Pro 11-inch (M5): 1668x2420, 834x1210 points.
    public static let iPad17_1 = iPad("iPad17,1", "j817ap", "iPad Pro 11-inch (M5)", width: 1668, height: 2420)
    /// iPad Pro 13-inch (M5): 2064x2752, 1032x1376 points.
    public static let iPad17_3 = iPad("iPad17,3", "j820ap", "iPad Pro 13-inch (M5)", width: 2064, height: 2752)

    public static let known: [VPhoneGuestDevice] = [
        iPhone17_3,
        iPad16_1,
        iPad15_7,
        iPad15_3, iPad15_5,
        iPad16_3, iPad16_5,
        iPad17_1, iPad17_3,
    ]

    /// Cellular models that ship in the same IPSW as a known Wi-Fi model and map
    /// onto it: the VM has no baseband, so it gets the Wi-Fi identity.
    static let aliases: [String: String] = [
        "iPad16,2": "iPad16,1",
        "iPad15,4": "iPad15,3",
        "iPad15,6": "iPad15,5",
        "iPad16,4": "iPad16,3",
        "iPad16,6": "iPad16,5",
        "iPad17,2": "iPad17,1",
        "iPad17,4": "iPad17,3",
    ]

    /// The device a VM has when its configuration names none: every VM made
    /// before iPad guests existed is an iPhone17,3.
    public static let `default` = iPhone17_3

    public static func named(_ productType: String?) -> VPhoneGuestDevice? {
        guard let productType else { return nil }
        let canonical = aliases[productType] ?? productType
        return known.first { $0.productType == canonical }
    }

    // MARK: - Restore Tree

    /// The folder `fw prepare` builds the restore tree in.
    ///
    /// Every reader of the tree — restore, `cfw install`, Launchpad's cleanup —
    /// matches `iPhone*_Restore`, so an iPad tree keeps that prefix: the
    /// prefix names the iPhoneOS restore format, not the device.
    public func restoreTreeName(version: String, build: String) -> String {
        switch family {
        case .iPhone: "\(productType)_\(version)_\(build)_Restore"
        case .iPad: "iPhoneOS_\(productType)_\(version)_\(build)_Restore"
        }
    }

    /// Where the restore tree keeps this device's own device tree.
    public var boardDeviceTreePath: String {
        "Firmware/all_flash/DeviceTree.\(deviceClass).im4p"
    }

    // MARK: - Detection

    /// The device a restore BuildManifest is for, from its
    /// `SupportedProductTypes`. One IPSW often covers several models — an 11-
    /// and a 13-inch iPad and their cellular twins — so `preferring` names the
    /// one wanted; without it, or when the IPSW does not cover it, the first
    /// known model wins. Nil when the manifest names no known device.
    public static func detect(buildManifest: [String: Any], preferring productType: String? = nil) -> VPhoneGuestDevice? {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        if let productType, types.contains(productType), let device = named(productType) {
            return device
        }
        for type in types {
            if let device = named(type) {
                return device
            }
        }
        return nil
    }

    public static func detect(buildManifestAt url: URL, preferring productType: String? = nil) -> VPhoneGuestDevice? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return detect(buildManifest: plist, preferring: productType)
    }

    /// Every known device a restore BuildManifest can supply.
    public static func covered(by buildManifest: [String: Any]) -> [VPhoneGuestDevice] {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        var devices: [VPhoneGuestDevice] = []
        for type in types {
            if let device = named(type), !devices.contains(device) {
                devices.append(device)
            }
        }
        return devices
    }

    /// Whether a restore BuildManifest is for an iPad at all, known or not.
    public static func isPadManifest(_ buildManifest: [String: Any]) -> Bool {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        return types.contains { $0.hasPrefix("iPad") }
    }
}
