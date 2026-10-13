@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Jetsam DisableAllowed")
struct CustomFirmwareJetsamDisableAllowedTests {
    @Test
    func `selected only for IOS 27`() throws {
        for base in [nil, "18.6", "26.6.2", "27.0", "27.0.1", "28.0"] as [String?] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: base.flatMap { VPhoneVersion($0) }, cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.jetsamDisableAllowed) == (base?.hasPrefix("27.") == true))
        }
    }

    @Test
    func `names only jetsam properties`() {
        #expect(CustomFirmwareJetsamDisableAllowed.isJetsamProperties("com.apple.jetsamproperties.J410.plist"))
        #expect(!CustomFirmwareJetsamDisableAllowed.isJetsamProperties("com.apple.jetsamproperties.J410.plist.bak"))
        #expect(!CustomFirmwareJetsamDisableAllowed.isJetsamProperties("com.apple.analyticsd.plist"))
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func `removes only the false key and keeps encoding`(format: PropertyListSerialization.PropertyListFormat) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // The shape of iOS 27's file: Version4 / Daemon / Override / <label>.
        let original: [String: Any] = [
            "Version4": [
                "Daemon": [
                    "Default": ["JetsamPriority": 3],
                    "Override": [
                        "com.apple.analyticsd": ["DisableAllowed": false, "ActiveSoftMemoryLimit": 8, "JetsamPriority": 140],
                        "com.apple.mobile.softwareupdated": ["DisableAllowed": false],
                        "com.apple.kept": ["DisableAllowed": true, "ExecuteAllowed": false],
                        "com.apple.other": ["JetsamPriority": 100],
                    ],
                ],
                "XPCService": ["Override": ["com.apple.ReportCrashService": ["DisableAllowed": false]]],
            ],
        ]
        let input = try PropertyListSerialization.data(fromPropertyList: original, format: format, options: 0)
        try input.write(to: url)
        #expect(try CustomFirmwareJetsamDisableAllowed.patch(at: url, dryRun: true) == 3)
        #expect(try Data(contentsOf: url) == input)
        #expect(try CustomFirmwareJetsamDisableAllowed.patch(at: url) == 3)

        let output = try Data(contentsOf: url)
        var outputFormat = PropertyListSerialization.PropertyListFormat.xml
        let root = try #require(PropertyListSerialization.propertyList(from: output, format: &outputFormat) as? [String: Any])
        #expect(outputFormat == format)
        let version = try #require(root["Version4"] as? [String: Any])
        let daemon = try #require(version["Daemon"] as? [String: Any])
        let overrides = try #require(daemon["Override"] as? [String: [String: Any]])
        #expect((daemon["Default"] as? NSDictionary) == ["JetsamPriority": 3] as NSDictionary)
        #expect((overrides["com.apple.analyticsd"] as NSDictionary?) == ["ActiveSoftMemoryLimit": 8, "JetsamPriority": 140] as NSDictionary)
        #expect(overrides["com.apple.mobile.softwareupdated"]?.isEmpty == true)
        #expect((overrides["com.apple.kept"] as NSDictionary?) == ["DisableAllowed": true, "ExecuteAllowed": false] as NSDictionary)
        #expect((overrides["com.apple.other"] as NSDictionary?) == ["JetsamPriority": 100] as NSDictionary)
        let service = try #require(version["XPCService"] as? [String: [String: [String: Any]]])
        #expect(service["Override"]?["com.apple.ReportCrashService"]?.isEmpty == true)

        #expect(try CustomFirmwareJetsamDisableAllowed.patch(at: url) == 0)
        #expect(try Data(contentsOf: url) == output)
    }

    @Test
    func `leaves A file without the key unwritten`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // iOS 26's file has no DisableAllowed; one that is not a boolean false is not ours.
        for root: [String: Any] in [
            ["Version4": ["Daemon": ["Override": ["com.apple.analyticsd": ["JetsamPriority": 140]]]]],
            ["Version4": ["Daemon": ["Override": ["com.apple.analyticsd": ["DisableAllowed": 0]]]]],
        ] {
            let input = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try input.write(to: url)
            #expect(try CustomFirmwareJetsamDisableAllowed.patch(at: url) == 0)
            #expect(try Data(contentsOf: url) == input)
        }
    }

    @Test
    func `rejects A plist that is not A dictionary`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try PropertyListSerialization.data(fromPropertyList: ["DisableAllowed"], format: .binary, options: 0)
        try input.write(to: url)
        #expect(throws: (any Error).self) { try CustomFirmwareJetsamDisableAllowed.patch(at: url) }
        #expect(try Data(contentsOf: url) == input)
    }
}
