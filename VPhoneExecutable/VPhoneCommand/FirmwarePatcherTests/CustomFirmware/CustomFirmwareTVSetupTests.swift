@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("TV setup feature flags")
struct CustomFirmwareTVSetupTests {
    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func preservesMetadataAndEncoding(format: PropertyListSerialization.PropertyListFormat) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original: [String: Any] = [
            "TVSetupV2": ["DevelopmentPhase": "FeatureComplete", "Metadata": "retained"],
            "TVSetupV2HW": ["Enabled": true, "DevelopmentPhase": "FeatureComplete"],
            "OtherFeature": ["Enabled": true],
        ]
        let input = try PropertyListSerialization.data(fromPropertyList: original, format: format, options: 0)
        try input.write(to: url)
        #expect(try CustomFirmwareTVSetup.patch(at: url, dryRun: true))
        #expect(try Data(contentsOf: url) == input)
        #expect(try CustomFirmwareTVSetup.patch(at: url))
        let output = try Data(contentsOf: url)
        var outputFormat = PropertyListSerialization.PropertyListFormat.xml
        let root = try #require(PropertyListSerialization.propertyList(from: output, format: &outputFormat) as? [String: Any])
        #expect(outputFormat == format)
        #expect((root["OtherFeature"] as? NSDictionary) == (original["OtherFeature"] as? NSDictionary))
        for name in CustomFirmwareTVSetup.features {
            let feature = try #require(root[name] as? [String: Any])
            #expect(feature["Enabled"] as? Bool == false)
            #expect(feature["DevelopmentPhase"] as? String == "FeatureComplete")
        }
        #expect((root["TVSetupV2"] as? [String: Any])?["Metadata"] as? String == "retained")
        #expect(try !CustomFirmwareTVSetup.patch(at: url))
        #expect(try Data(contentsOf: url) == output)
    }

    @Test
    func refusesUnexpectedSchemaWithoutPartialWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for invalid: Any in ["invalid", ["Enabled": 0], ["Enabled": "false"]] {
            let root: [String: Any] = ["TVSetupV2": [:], "TVSetupV2HW": invalid]
            let input = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try input.write(to: url)
            #expect(throws: (any Error).self) { try CustomFirmwareTVSetup.patch(at: url) }
            #expect(try Data(contentsOf: url) == input)
        }
        let input = try PropertyListSerialization.data(fromPropertyList: ["TVSetupV2": [:]], format: .binary, options: 0)
        try input.write(to: url)
        #expect(throws: (any Error).self) { try CustomFirmwareTVSetup.patch(at: url) }
        #expect(try Data(contentsOf: url) == input)
    }
}
