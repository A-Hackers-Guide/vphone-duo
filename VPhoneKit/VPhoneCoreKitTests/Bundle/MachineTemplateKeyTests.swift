import Foundation
import Testing
@testable import VPhoneCoreKit

/// The template key: which requests may share one template.
struct MachineTemplateKeyTests {
    static func key(
        device: String = "iPhone17,3",
        bootChain: String = "abc",
        series: String = "2.8",
        disk: UInt64 = 64,
        slimming: VPhoneMachineTemplateSlimming = .none,
    ) -> VPhoneMachineTemplateKey {
        VPhoneMachineTemplateKey(
            device: device,
            iOSVersion: "27.0",
            iOSBuild: "24A435",
            cloudOSVersion: "26.4",
            cloudOSBuild: "23E5207q",
            patchPreset: "standard",
            bootChainPlanDigest: bootChain,
            bundleSeries: series,
            diskSizeGB: disk,
            slimming: slimming,
        )
    }

    // MARK: - Identifier

    @Test func `the identifier is pinned to the canonical description`() {
        // Computed outside Swift: printf '<canonical description>' | shasum -a 256 | cut -c1-12.
        // A change here orphans every template on disk: raise currentFormatVersion instead.
        let key = Self.key()
        #expect(key.canonicalDescription == """
        format=1
        device=iPhone17,3
        ios=27.0/24A435
        cloudos=26.4/23E5207q
        preset=standard
        bootchain=abc
        series=2.8
        disk=64
        trim=none
        setup=0
        services=none
        removed-apps=
        """)
        #expect(key.identifier == "a5f0340ef865")
        #expect(VPhoneMachineTemplateKey.isIdentifier(key.identifier))
    }

    @Test func `equal keys share an identifier whatever order their lists came in`() {
        let a = Self.key(slimming: .init(removedApps: ["com.apple.tv", "com.apple.news"]))
        let b = Self.key(slimming: .init(removedApps: ["com.apple.news", "com.apple.tv", "com.apple.tv"]))
        #expect(a == b)
        #expect(a.identifier == b.identifier)
    }

    @Test func `every field changes the identifier`() {
        let base = Self.key()
        var variants: [VPhoneMachineTemplateKey] = []
        func vary(_ change: (inout VPhoneMachineTemplateKey) -> Void) {
            var copy = base
            change(&copy)
            variants.append(copy)
        }
        vary { $0.formatVersion = 2 }
        vary { $0.device = "iPad16,1" }
        vary { $0.iOSVersion = "27.0.1" }
        vary { $0.iOSBuild = "24A446" }
        vary { $0.cloudOSVersion = "26.5" }
        vary { $0.cloudOSBuild = "23F1" }
        vary { $0.patchPreset = "experimental" }
        vary { $0.bootChainPlanDigest = "abd" }
        vary { $0.bundleSeries = "2.9" }
        vary { $0.diskSizeGB = 128 }
        vary { $0.slimming.trimTier = "standard" }
        vary { $0.slimming.setupBoot = true }
        vary { $0.slimming.serviceProfile = "trimmed" }
        vary { $0.slimming.removedApps = ["com.apple.tv"] }

        let identifiers = Set(variants.map(\.identifier) + [base.identifier])
        #expect(identifiers.count == variants.count + 1)
        for variant in variants {
            #expect(!base.differences(from: variant).isEmpty, "\(variant.canonicalDescription)")
        }
        #expect(base.differences(from: base).isEmpty)
    }

    @Test func `identifier shape`() {
        #expect(VPhoneMachineTemplateKey.isIdentifier("0123456789ab"))
        for bad in ["", "0123456789a", "0123456789abc", "0123456789AB", "0123456789ag", ".templates/x", "../../etc/x"] {
            #expect(!VPhoneMachineTemplateKey.isIdentifier(bad), "\(bad)")
        }
    }

    // MARK: - Plan digest

    @Test func `plan digest ignores order and duplicates and sees parameters`() {
        let digest = VPhoneMachineTemplateKey.planDigest(bootChainPatches: ["b", "a", "a"], parameters: ["k": "v"])
        #expect(digest == "bacbaaea391f4545d0d261fdeffa3b17a4761a5f4ad244db481c50cbc5b61236")
        #expect(digest == VPhoneMachineTemplateKey.planDigest(bootChainPatches: ["a", "b"], parameters: ["k": "v"]))
        #expect(digest != VPhoneMachineTemplateKey.planDigest(bootChainPatches: ["a", "b"], parameters: ["k": "w"]))
        #expect(digest != VPhoneMachineTemplateKey.planDigest(bootChainPatches: ["a"], parameters: ["k": "v"]))
        #expect(digest != VPhoneMachineTemplateKey.planDigest(bootChainPatches: ["a", "b"], parameters: [:]))
    }

    // MARK: - Series

    @Test func `bundle series is the first two numbers`() {
        #expect(VPhoneMachineTemplateKey.series(ofBundleVersion: "2.8.0") == "2.8")
        #expect(VPhoneMachineTemplateKey.series(ofBundleVersion: "2.8.1") == "2.8")
        #expect(VPhoneMachineTemplateKey.series(ofBundleVersion: "2.8.0-local.ab12cd34") == "2.8")
        #expect(VPhoneMachineTemplateKey.series(ofBundleVersion: "2.10") == "2.10")
        for bad in ["", "2", "2.", "x.y", "-local.2.8"] {
            #expect(VPhoneMachineTemplateKey.series(ofBundleVersion: bad) == nil, "\(bad)")
        }
    }

    // MARK: - Request

    @Test func `a request conflicts only in the key fields it names differently`() {
        let key = Self.key()
        #expect(VPhoneMachineTemplateRequest().conflicts(with: key).isEmpty)
        #expect(VPhoneMachineTemplateRequest(device: "iPhone17,3", patchPreset: "standard", diskSizeGB: 64)
            .conflicts(with: key).isEmpty)

        let conflicts = VPhoneMachineTemplateRequest(device: "iPad16,1", patchPreset: "experimental", diskSizeGB: 128)
            .conflicts(with: key)
        #expect(conflicts.count == 3)
        #expect(conflicts[0].hasPrefix("--device iPad16,1"))
        #expect(conflicts[1].hasPrefix("--preset experimental"))
        #expect(conflicts[2].hasPrefix("--disk-size 128"))
    }

    // MARK: - Coding

    @Test func `a record survives Template plist`() throws {
        let record = VPhoneMachineTemplateRecord(
            key: Self.key(slimming: .init(trimTier: "standard")),
            created: Date(timeIntervalSince1970: 1_800_000_000),
            builtWithBundleVersion: "2.8.0",
            bootChainBundleVersion: "2.8.0-local.ab12cd34",
            sourceMachine: "src",
            frozen: true,
            frozenAt: Date(timeIntervalSince1970: 1_800_000_100),
            steps: .init(snapshotDeleted: true, trimTier: "standard"),
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(record)
        #expect(try PropertyListDecoder().decode(VPhoneMachineTemplateRecord.self, from: data) == record)
        #expect(record.identifier == record.key.identifier)
        let text = String(decoding: data, as: UTF8.self)
        for field in ["Identifier", "Key", "Frozen", "Steps", "SnapshotDeleted", "TrimTier", "BootChainPlanDigest"] {
            #expect(text.contains("<key>\(field)</key>"), "\(field)")
        }
    }
}
