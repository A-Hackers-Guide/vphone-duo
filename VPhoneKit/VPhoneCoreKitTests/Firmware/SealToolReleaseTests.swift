import Foundation
import Testing
@testable import VPhoneCoreKit

struct SealToolReleaseTests {
    private let macOS = ["15.2", "15.6.1", "15.7.1", "26.1", "26.4"].map {
        VPhoneFirmwareIndex.Release(
            os: "macOS",
            version: $0,
            build: "",
            url: URL(string: "https://example.invalid/\($0).ipsw")!,
        )
    }

    private func sealTool(_ version: String) throws -> String {
        try VPhoneFirmwareIndex.sealToolRelease(forOSVersion: version, in: macOS).version
    }

    @Test func `iOS 26 takes the macOS of the same version`() throws {
        #expect(try sealTool("26.1") == "26.1")
        #expect(try sealTool("26.4") == "26.4")
    }

    @Test func `iOS 18 takes the macOS 15 of the same minor`() throws {
        #expect(try sealTool("18.2") == "15.2")
        #expect(try sealTool("18.7.1") == "15.7.1")
    }

    @Test func `without a twin, the newest macOS of the major below it`() throws {
        // 18.2.1 has no macOS 15.2.1, and 15.6 is not in this list.
        #expect(try sealTool("18.2.1") == "15.2")
        #expect(try sealTool("18.6") == "15.2")
        #expect(try sealTool("18.7.2") == "15.7.1")
        #expect(try sealTool("26.5") == "26.4")
    }

    @Test func `nothing of the major at or below it is an error`() {
        #expect(throws: VPhoneFirmwareIndex.Error.self) { try sealTool("18.1") }
        #expect(throws: VPhoneFirmwareIndex.Error.self) { try sealTool("27.0") }
    }
}
