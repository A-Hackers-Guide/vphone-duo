import Foundation

/// The guest product type the Machines table and inspector read from a
/// machine folder, and the OS name it gives.
@main
struct MachineProductTypeTests {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        precondition(condition, "line \(line): \(message())")
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("machine-product-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        // config.plist's key wins over the restore tree.
        let pad = root.appendingPathComponent("ipad-mini-01", isDirectory: true)
        try manager.createDirectory(at: pad.appendingPathComponent("FirmwareOriginals/iPhone17,3_26.6.2_23G90_Restore"), withIntermediateDirectories: true)
        let config: NSDictionary = ["guestProductType": "iPad16,1", "cpuCount": 8]
        try config.write(to: pad.appendingPathComponent("config.plist"))
        expect(VPhoneLaunchpadMachine.guestProductType(in: pad) == "iPad16,1", "config.plist")

        // A config written before the key: the iPad restore tree's name.
        let older = root.appendingPathComponent("ipad-pro-13", isDirectory: true)
        try manager.createDirectory(at: older.appendingPathComponent("FirmwareOriginals/AVPBooter.vresearch1.bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: older.appendingPathComponent("FirmwareOriginals/iPhoneOS_iPad17,3_26.6.2_23G90_Restore"), withIntermediateDirectories: true)
        try (["cpuCount": 8] as NSDictionary).write(to: older.appendingPathComponent("config.plist"))
        expect(VPhoneLaunchpadMachine.guestProductType(in: older) == "iPad17,3", "iPad restore tree")

        let phone = root.appendingPathComponent("research-01", isDirectory: true)
        try manager.createDirectory(at: phone.appendingPathComponent("FirmwareOriginals/iPhone17,3_27.0_24A435_Restore"), withIntermediateDirectories: true)
        expect(VPhoneLaunchpadMachine.guestProductType(in: phone) == "iPhone17,3", "iPhone restore tree")
        let tv = root.appendingPathComponent("tv-01", isDirectory: true)
        try manager.createDirectory(at: tv.appendingPathComponent("FirmwareOriginals/iPhoneOS_AppleTV5,3_26.6_23L773_Restore"), withIntermediateDirectories: true)
        expect(VPhoneLaunchpadMachine.guestProductType(in: tv) == "AppleTV5,3", "Apple TV restore tree")
        let homePod = root.appendingPathComponent("homepod-mini", isDirectory: true)
        try manager.createDirectory(at: homePod.appendingPathComponent("FirmwareOriginals/AudioAccessory5,1_27.0_24J361_Restore"), withIntermediateDirectories: true)
        expect(VPhoneLaunchpadMachine.guestProductType(in: homePod) == "AudioAccessory5,1", "HomePod restore tree")
        expect(VPhoneLaunchpadMachine.guestProductType(in: root.appendingPathComponent("missing")) == nil, "nothing to read")


        // restore-info.json's device is the restore identity's, not the guest's.
        let json = #"""
        {"name":"ipad-mini-01","cpuCount":8,"memoryMB":8192,"diskSizeBytes":64000000000,
         "network":{"mode":"nat","macAddress":"9a:84:18:78:7a:31"},
         "restoreInfo":{"ios":{"version":"26.6.2","build":"23G90"},"cloudOS":{"version":"26.4","build":"23E5207q"},"variant":"jb","device":"iPhone99,11"}}
        """#
        var machine = try JSONDecoder().decode(VPhoneLaunchpadMachine.self, from: Data(json.utf8))
        expect(machine.osName == "iOS" && !machine.isPad, "unknown type reads as iOS")
        machine.guestProductType = VPhoneLaunchpadMachine.guestProductType(in: pad)
        expect(machine.isPad && machine.osName == "iPadOS", "iPad guest")
        machine.guestProductType = VPhoneLaunchpadMachine.guestProductType(in: tv)
        expect(machine.isAppleTV && !machine.isPad && machine.osName == "tvOS", "Apple TV guest")

        machine.guestProductType = VPhoneLaunchpadMachine.guestProductType(in: homePod)
        expect(machine.isHomePod && !machine.isAppleTV && !machine.isPad && machine.osName == "HomePod Software", "HomePod guest")
        let homePodDevice = VPhoneLaunchpadFirmwareCatalog.Device(productType: "AudioAccessory5,1", name: "HomePod mini", family: "homePod", pairings: [])
        expect(homePodDevice.isHomePod && !homePodDevice.isAppleTV && homePodDevice.requiresStandaloneRestore, "HomePod catalog family")
        expect(homePodDevice.osName == "HomePod Software", "HomePod catalog OS label")

        // An OTA pairing's build comes from the bundle; an IPSW's from its name.

        let catalog = #"""
        {"device":"iPhone17,3","pairings":[],"devices":[{"productType":"AppleTV14,1","name":"Apple TV 4K (3rd generation)","family":"appleTV","pairings":[
         {"ios":{"name":"tvOS 26.6","url":"https://example.com/AppleTV5,3_26.6_23L773_Restore.ipsw"},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"https://example.com/c"}},
         {"ios":{"name":"tvOS 27.0","url":"https://example.com/9bf3ad6a.aea","build":"24J361","files":["ota/AppleTV14,1_27.0_24J361_OTA.aea","AppleTV5,3_26.6_23L773_Restore.ipsw"]},"recommendedCloudOS":{"name":"cloudOS 26.4","url":"https://example.com/c"}}]}]}
        """#
        let tv4K = try JSONDecoder().decode(VPhoneLaunchpadFirmwareCatalog.self, from: Data(catalog.utf8)).guests[0]
        expect(tv4K.pairings.map(\.build) == ["23L773", "24J361"], "OTA build from the bundle")
        expect(tv4K.pairings[0].ios.files == nil && tv4K.pairings[1].ios.files?.count == 2, "OTA files")
        print("Machine product type tests passed: config, restore trees, OS name, catalog builds")
    }
}
