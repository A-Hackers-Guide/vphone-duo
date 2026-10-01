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
/// Values are copied from each device's own `DeviceTree.<board>.im4p`.
public struct VPhoneGuestDevice: Sendable, Equatable {
    public enum Family: String, Codable, Sendable {
        case iPhone
        case iPad
    }

    public let family: Family
    /// `Ap,ProductType`, e.g. `iPad16,1`.
    public let productType: String
    /// BuildManifest `DeviceClass`, e.g. `j410ap`.
    public let deviceClass: String
    /// Root `target-type`, e.g. `J410`.
    public let targetType: String
    /// Root `target-sub-type` and `/product/unique-model`, e.g. `J410AP`.
    public let uniqueModel: String
    /// `/product/product-name` and `product-description`.
    public let productName: String
    /// `/product/artwork-device-idiom`: `phone` or `pad`.
    public let artworkIdiom: String
    /// `/product/artwork-device-subtype`: the panel height class.
    public let artworkSubtype: UInt64
    /// `/product/artwork-scale-factor`.
    public let artworkScale: UInt64
    /// The guest display.
    public let screen: VPhoneVirtualMachineManifest.ScreenConfig

    public init(
        family: Family,
        productType: String,
        deviceClass: String,
        targetType: String,
        uniqueModel: String,
        productName: String,
        artworkIdiom: String,
        artworkSubtype: UInt64,
        artworkScale: UInt64,
        screen: VPhoneVirtualMachineManifest.ScreenConfig,
    ) {
        self.family = family
        self.productType = productType
        self.deviceClass = deviceClass
        self.targetType = targetType
        self.uniqueModel = uniqueModel
        self.productName = productName
        self.artworkIdiom = artworkIdiom
        self.artworkSubtype = artworkSubtype
        self.artworkScale = artworkScale
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
        targetType: "D47",
        uniqueModel: "D47AP",
        productName: "iPhone 16",
        artworkIdiom: "phone",
        artworkSubtype: 2556,
        artworkScale: 3,
        screen: .default,
    )

    /// iPad mini (A17 Pro, Wi-Fi), J410AP. The 8.3-inch 1488x2266 panel at
    /// 326 ppi keeps the VM window a manageable size on a laptop.
    public static let iPad16_1 = VPhoneGuestDevice(
        family: .iPad,
        productType: "iPad16,1",
        deviceClass: "j410ap",
        targetType: "J410",
        uniqueModel: "J410AP",
        productName: "iPad mini (A17 Pro)",
        artworkIdiom: "pad",
        artworkSubtype: 2266,
        artworkScale: 2,
        screen: .init(width: 1488, height: 2266, pixelsPerInch: 326, scale: 2.0),
    )

    public static let known: [VPhoneGuestDevice] = [iPhone17_3, iPad16_1]

    /// Product types that share a known device's IPSW and map onto it. The
    /// cellular iPad mini ships in the same IPSW as the Wi-Fi one; the VM has
    /// no baseband, so it gets the Wi-Fi identity.
    static let aliases: [String: String] = ["iPad16,2": "iPad16,1"]

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

    // MARK: - Detection

    /// The device a restore BuildManifest is for, from its
    /// `SupportedProductTypes`. Nil when it names no known device.
    public static func detect(buildManifest: [String: Any]) -> VPhoneGuestDevice? {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        for type in types {
            if let device = named(type) {
                return device
            }
        }
        return nil
    }

    public static func detect(buildManifestAt url: URL) -> VPhoneGuestDevice? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return detect(buildManifest: plist)
    }

    /// Whether a restore BuildManifest is for an iPad at all, known or not.
    public static func isPadManifest(_ buildManifest: [String: Any]) -> Bool {
        let types = buildManifest["SupportedProductTypes"] as? [String] ?? []
        return types.contains { $0.hasPrefix("iPad") }
    }
}
