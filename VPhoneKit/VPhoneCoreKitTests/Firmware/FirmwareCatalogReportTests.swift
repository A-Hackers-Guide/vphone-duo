import Foundation
import Testing
@testable import VPhoneCoreKit

struct FirmwareCatalogReportTests {
    @Test func `maps every pairing`() {
        let report = VPhoneFirmwareCatalog.report
        #expect(report.device == VPhoneFirmwareCatalog.device)
        #expect(report.pairings.count == VPhoneFirmwareCatalog.pairings.count)

        for (entry, pairing) in zip(report.pairings, VPhoneFirmwareCatalog.pairings) {
            #expect(entry.ios.name == pairing.iosName)
            #expect(entry.ios.url == pairing.iosURL)
            #expect(entry.recommendedCloudOS.name == pairing.cloudosName)
            #expect(entry.recommendedCloudOS.url == pairing.cloudosURL)
        }
    }

    @Test func `an OTA pairing names its build and the files it needs`() throws {
        let tv4K = try #require(VPhoneFirmwareCatalog.report.devices.first { $0.productType == "AppleTV14,1" })
        let ipsw = try #require(tv4K.pairings.first { $0.ios.name == "tvOS 26.6" })
        let ota = try #require(tv4K.pairings.first { $0.ios.name == "tvOS 27.0" })
        #expect(ipsw.ios.build == nil && ipsw.ios.files == nil)
        #expect(ota.ios.build == "24J361")
        #expect(ota.ios.files == ["ota/AppleTV14,1_27.0_24J361_OTA.aea", "AppleTV5,3_26.6_23L773_Restore.ipsw"])
        // An IPSW's entry encodes as before, so an older Launchpad reads it unchanged.
        let json = try #require(String(data: JSONEncoder().encode(ipsw), encoding: .utf8))
        #expect(!json.contains("build") && !json.contains("files"))
    }

    @Test func `lists every curated guest`() {
        let report = VPhoneFirmwareCatalog.report
        #expect(report.devices.map(\.productType) == VPhoneGuestDevice.known.map(\.productType))
        #expect(report.devices.first?.pairings == report.pairings)
        for device in report.devices.dropFirst() {
            #expect(device.family == VPhoneGuestDevice.named(device.productType)?.family.rawValue)
            #expect(!device.pairings.isEmpty)
            #expect(device.name == VPhoneGuestDevice.named(device.productType)?.productName)
        }
    }

    @Test func `the Apple TV 4K pairs each OTA with the Apple TV HD IPSW it is restored over`() throws {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AppleTV14,1")
        #expect(pairings.map(\.iosName) == ["tvOS 26.6", "tvOS 27.0"])
        let hd = try #require(VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3").first { $0.iosName == "tvOS 26.6" })
        for p in pairings {
            #expect(p.device == "AppleTV14,1")
            #expect(p.cloudosURL == hd.cloudosURL)
        }
        // 26.6 names the HD's IPSW of its own version; 27.0, which the HD
        // never got, names its OTA, and `fw prepare` finds the base from it.
        #expect(pairings[0].iosURL == hd.iosURL)
        let ota27 = try #require(VPhoneFirmwareCatalog.otaRelease(source: pairings[1].iosURL))
        #expect(ota27.version == "27.0" && ota27.build == "24J361" && ota27.baseVersion == "26.6")
        #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: ota27) == hd.iosURL)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: "/cache/ota/\(ota27.fileName)") == ota27)
        #expect(VPhoneFirmwareCatalog.otaRelease(source: hd.iosURL) == nil)
        let ota = try #require(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV14,1", build: "23L773"))
        #expect(ota.version == "26.6")
        #expect(ota.url.hasPrefix("https://updates.cdn-apple.com/") && ota.url.hasSuffix(".aea"))
        #expect(ota.size == 4_764_729_344)
        #expect(Data(base64Encoded: ota.key)?.count == 32)
        #expect(ota.fileName == "AppleTV14,1_26.6_23L773_OTA.aea")
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV14,1", build: "23L760") == nil)
        #expect(VPhoneFirmwareCatalog.otaRelease(for: "AppleTV5,3", build: "23L773") == nil)
        // Every OTA has a base release to be restored over.
        for release in VPhoneFirmwareCatalog.otaReleases {
            let base = try #require(VPhoneGuestDevice.named(release.productType)?.restoreBase)
            #expect(VPhoneFirmwareCatalog.pairings(for: base.productType).contains { $0.iosName.hasSuffix(" \(release.baseVersion)") })
            #expect(VPhoneFirmwareCatalog.restoreBaseURL(for: release) != nil)
            #expect(Data(base64Encoded: release.key)?.count == 32)
        }
    }

    @Test func `Apple TV pairings are tvOS releases on cloudOS 26.4`() throws {
        let pairings = VPhoneFirmwareCatalog.pairings(for: "AppleTV5,3")
        #expect(pairings.map(\.iosName) == ["tvOS 26.6"])
        for p in pairings {
            #expect(p.device == "AppleTV5,3")
            #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
            #expect(p.iosURL.contains("/AppleTV5,3_"))
            #expect(p.iosURL.hasSuffix("_Restore.ipsw"))
            #expect(p.cloudosName == "cloudOS 26.4")
            #expect(p.cloudosURL == VPhoneFirmwareCatalog.cloud264)
        }
        let tv = try #require(VPhoneFirmwareCatalog.report.devices.first { $0.productType == "AppleTV5,3" })
        #expect(tv.family == "appleTV")
        #expect(tv.name == "Apple TV HD")
    }

    @Test func `i pad pairings come from an IPSW that covers the device`() {
        for guest in VPhoneGuestDevice.known where guest.isPad {
            let pairings = VPhoneFirmwareCatalog.pairings(for: guest.productType)
            #expect(pairings.map(\.iosName).first == "iPadOS 26.0" || guest.productType.hasPrefix("iPad17,"))
            #expect(pairings.map(\.iosName).last == "iPadOS 27.0.1")
            for p in pairings {
                #expect(p.device == guest.productType)
                #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
                #expect(p.iosURL.hasSuffix("_Restore.ipsw"))
                #expect(p.cloudosURL.contains("/private-cloud-compute/"))
                // The iPad Pro (M4) IPSWs are named iPad_Pro_M4_…; the rest name their models.
                let name = (p.iosURL as NSString).lastPathComponent
                #expect(name.hasPrefix("iPad_Pro_M4_") || name.split(separator: "_")[0].split(separator: ",").count >= 2)
                #expect(name.contains("_\(p.iosName.dropFirst("iPadOS ".count))_"))
            }
        }
    }

    @Test func `other i phones have pairings of their own`() {
        for guest in VPhoneGuestDevice.known where guest.family == .iPhone && guest.presentsBoard {
            let pairings = VPhoneFirmwareCatalog.pairings(for: guest.productType)
            #expect(pairings.map(\.iosName).first == (guest.productType == "iPhone18,5" ? "iOS 26.3.1" : "iOS 26.0"))
            #expect(pairings.map(\.iosName).last == "iOS 27.0.1")
            for p in pairings {
                #expect(p.device == guest.productType)
                #expect(p.iosURL.hasPrefix("https://updates.cdn-apple.com/"))
                let name = (p.iosURL as NSString).lastPathComponent
                #expect(name.hasPrefix("\(guest.productType)_\(p.iosName.dropFirst("iOS ".count))_"))
                #expect(name.hasSuffix("_Restore.ipsw"))
                #expect(p.cloudosURL == VPhoneFirmwareCatalog.recommendedCloudOS(forVersion: String(p.iosName.dropFirst("iOS ".count))).url)
            }
        }
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone18,1") != VPhoneFirmwareCatalog.pairings)
    }

    @Test func `cellular i pad gets its wi fi model's pairings`() {
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad17,4") == VPhoneFirmwareCatalog.pairings(for: "iPad17,3"))
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad17,3").first?.device == "iPad17,3")
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPad15,8").isEmpty)
        #expect(VPhoneFirmwareCatalog.pairings(for: "iPhone17,3") == VPhoneFirmwareCatalog.pairings)
    }

    @Test func `i pad cloud OS follows the i phone pairing of the same release`() {
        let iPhone = Dictionary(
            VPhoneFirmwareCatalog.pairings.map { ($0.iosName.replacingOccurrences(of: "iOS ", with: ""), $0.cloudosURL) },
            uniquingKeysWith: { first, _ in first },
        )
        for p in VPhoneFirmwareCatalog.pairings(for: "iPad16,1") {
            let version = p.iosName.replacingOccurrences(of: "iPadOS ", with: "")
            #expect(iPhone[version] == p.cloudosURL, "\(version)")
        }
    }

    @Test func `round trips JSON`() throws {
        let report = VPhoneFirmwareCatalog.report
        let back = try JSONDecoder().decode(VPhoneFirmwareCatalogReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
    }
}
