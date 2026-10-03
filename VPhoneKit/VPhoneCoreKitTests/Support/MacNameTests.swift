import Foundation
import Testing
@testable import VPhoneCoreKit

/// This Mac's `.local` name in the guest: where it points in each mode, and
/// how it is turned off.
struct MacNameTests {
    typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig

    private let shared = VPhoneIPv4Address(192, 168, 64, 1)

    @Test func `the Mac's name points where the guest reaches the Mac`() {
        #expect(VPhoneNetworking.macStaticNames(NetworkConfig(mode: .nat, macAddress: ""), macName: "Lab-Mac", sharedNATHost: shared) == [
            .init(address: shared, names: ["Lab-Mac.local"]),
        ])
        #expect(
            VPhoneNetworking.macStaticNames(NetworkConfig(mode: .tunnel, macAddress: ""), macName: "Lab-Mac", sharedNATHost: shared).first?.address
                == VPhoneUserspaceNetworkConfiguration.default.hostAddress,
        )
        let bridged = NetworkConfig(mode: .bridged, macAddress: "", bridgeInterface: "en0")
        #expect(VPhoneNetworking.macStaticNames(bridged, macName: "Lab-Mac", sharedNATHost: shared).isEmpty)
        #expect(
            VPhoneNetworking.macStaticNames(bridged, macName: "Lab-Mac", sharedNATHost: shared, bridgedAddress: VPhoneIPv4Address(10, 0, 0, 7)).first?.address
                == VPhoneIPv4Address(10, 0, 0, 7),
        )
        #expect(VPhoneNetworking.macStaticNames(NetworkConfig(mode: .off, macAddress: ""), macName: "Lab-Mac", sharedNATHost: shared).isEmpty)
        #expect(VPhoneNetworking.macStaticNames(NetworkConfig(mode: .nat, macAddress: ""), macName: nil, sharedNATHost: shared).isEmpty)
    }

    /// On by default and stored as an absent key, so only `off` reaches the
    /// plist, and changing the mode keeps it.
    @Test func `the Mac's name can be turned off and stays off`() throws {
        let off = try VPhoneNetworking.merge(into: .default, mode: nil, bridgeInterface: nil, resolvesMacName: false)
        #expect(off.resolvesMacName == false)
        #expect(VPhoneNetworking.macStaticNames(off, macName: "Lab-Mac", sharedNATHost: shared).isEmpty)
        let tunnel = try VPhoneNetworking.merge(into: off, mode: .tunnel, bridgeInterface: nil)
        #expect(tunnel.resolvesMacName == false)
        let on = try VPhoneNetworking.merge(into: tunnel, mode: nil, bridgeInterface: nil, resolvesMacName: true)
        #expect(on.resolvesMacName == nil)
    }

    @Test func `configs without the key decode with the default`() throws {
        let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>mode</key><string>nat</string><key>macAddress</key><string></string></dict></plist>
        """.utf8)
        let decoded = try PropertyListDecoder().decode(NetworkConfig.self, from: plist)
        #expect(decoded.resolvesMacName == nil)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        #expect(!String(decoding: try encoder.encode(decoded), as: UTF8.self).contains("resolvesMacName"))
    }
}
