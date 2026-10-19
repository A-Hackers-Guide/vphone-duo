@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

/// The vresearch101 → vphone600 conversion: against a small research board
/// tree, and against Apple's own pair of trees when an IPSW in `ipsws/`
/// carries both.
@Suite("Device tree research board conversion")
struct DeviceTreeResearchBoardTests {
    // MARK: - Fixture

    static func string(_ text: String) -> Data {
        Data((text + "\0").utf8)
    }

    static func phandle(_ number: UInt32) -> (String, Data) {
        ("AAPL,phandle", FlatDeviceTreeNode.uint32(number))
    }

    static func researchTree(targetType: String = "VRESEARCH101") -> Data {
        FlatDeviceTreeNode("device-tree", [
            ("target-type", string(targetType)),
            ("model", string("ComputeModule14,2")),
            phandle(1),
        ], children: [
            FlatDeviceTreeNode("filesystems", [phandle(2)]),
            FlatDeviceTreeNode("arm-io", [phandle(3)], children: [
                FlatDeviceTreeNode("uart0", [phandle(4)]),
                FlatDeviceTreeNode("gfx", [phandle(5), ("interrupt-parent", FlatDeviceTreeNode.uint32(4))]),
                FlatDeviceTreeNode("cpu-debug-interface", [phandle(6)]),
                FlatDeviceTreeNode("sep", [phandle(7)]),
            ]),
            FlatDeviceTreeNode("defaults", [
                phandle(8),
                ("pmap-max-asids", FlatDeviceTreeNode.uint32(4)),
                ("serial-device", FlatDeviceTreeNode.uint32(4)),
            ]),
            FlatDeviceTreeNode("product", [phandle(9), ("kernel-core-dump-location", string("x"))], children: [
                FlatDeviceTreeNode("usb-device", [phandle(10)]),
            ]),
        ]).serialized
    }

    /// Only the conversion on, so the vphone600 patches that follow it do not
    /// need their properties in this small tree.
    static let conversionOnly = VPhonePatchGate(
        declared: Set((FirmwareResearchBoardPatchSet.manifest.patches + FirmwareDeviceTreePatchSet.manifest.patches).map(\.identifier)),
        enabled: [FirmwareResearchBoardPatchSet.deviceTreeConversion],
    )

    static func convert(_ data: Data, converting: Bool = true) throws -> (DeviceTreePatcher, DeviceTreePatcher.DTNode, [PatchRecord]) {
        let patcher = DeviceTreePatcher(data: data, verbose: false)
        patcher.gate = conversionOnly
        patcher.convertsResearchBoard = converting
        let records = try patcher.findAll()
        return (patcher, try patcher.parsePayload(patcher.patchedData), records)
    }

    static func name(_ node: DeviceTreePatcher.DTNode) -> String {
        String(decoding: (node.properties.first { $0.name == "name" }?.value ?? Data()).prefix { $0 != 0 }, as: UTF8.self)
    }

    static func value(_ node: DeviceTreePatcher.DTNode, _ property: String) -> Data? {
        node.properties.first { $0.name == property }?.value
    }

    // MARK: - Small Tree

    @Test("A research board tree becomes vphone600, with new nodes in vphone600's places")
    func convertsResearchBoard() throws {
        let (patcher, root, records) = try Self.convert(Self.researchTree())
        #expect(records.map(\.patchID) == [FirmwareResearchBoardPatchSet.deviceTreeConversion])
        #expect(Self.value(root, "target-type") == Self.string("VPHONE600"))
        #expect(Self.value(root, "model") == Self.string("iPhone99,11"))

        #expect(root.children.map(Self.name) == ["buttons", "filesystems", "arm-io", "defaults", "product"])
        let armIO = try patcher.resolveNode(root, path: ["device-tree", "arm-io"])
        #expect(armIO.children.map(Self.name) == ["uart0", "gfx", "multi-touch", "cpu-debug-interface", "bluetooth", "sep"])
        let product = try patcher.resolveNode(root, path: ["device-tree", "product"])
        #expect(product.children.map(Self.name) == ["vphone600-gestalt-variants", "maps", "haptics", "usb-device"])

        let defaults = try patcher.resolveNode(root, path: ["device-tree", "defaults"])
        #expect(Self.value(defaults, "pmap-max-asids") == nil)
        #expect(Self.value(product, "kernel-core-dump-location") == nil)
        let placeholder = try #require(product.properties.first { $0.name == "artwork-device-subtype" })
        #expect(placeholder.flags == DeviceTreePatcher.placeholderFlag)
        #expect(placeholder.value == Self.string("syscfg/ards"))
    }

    @Test("Existing phandles and the references to them are kept; new nodes get unused ones")
    func keepsPhandles() throws {
        let (patcher, root, _) = try Self.convert(Self.researchTree())
        let gfx = try patcher.resolveNode(root, path: ["device-tree", "arm-io", "gfx"])
        #expect(Self.value(gfx, "AAPL,phandle") == FlatDeviceTreeNode.uint32(5))
        #expect(Self.value(gfx, "interrupt-parent") == FlatDeviceTreeNode.uint32(4))

        var phandles: [Data] = []
        func collect(_ node: DeviceTreePatcher.DTNode) {
            phandles += node.properties.filter { $0.name == "AAPL,phandle" }.map(\.value)
            node.children.forEach(collect)
        }
        collect(root)
        #expect(phandles.count == 17)
        #expect(Set(phandles).count == phandles.count)
    }

    @Test("A vphone600 tree, or a preset without the set, is left alone")
    func leavesOtherTreesAlone() throws {
        let vphone = Self.researchTree(targetType: "VPHONE600")
        let (_, _, records) = try Self.convert(vphone)
        #expect(records.isEmpty)

        let research = Self.researchTree()
        let (patcher, _, unconverted) = try Self.convert(research, converting: false)
        #expect(unconverted.isEmpty)
        #expect(patcher.patchedData == research)
    }

    // MARK: - Apple's Trees

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let researchEntry = "Firmware/all_flash/DeviceTree.vresearch101ap.im4p"
    static let vphoneEntry = "Firmware/all_flash/DeviceTree.vphone600ap.im4p"

    /// The cloudOS IPSWs in `ipsws/` with both trees: 26.1 to the 26.4 beta.
    static var pairedIPSWs: [URL] {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: repoRoot.appending(path: "ipsws"),
            includingPropertiesForKeys: nil,
        )) ?? []
        return candidates.filter { candidate in
            guard candidate.pathExtension == "ipsw" else { return false }
            let listing = (try? CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-l", candidate.path, researchEntry, vphoneEntry]))?.output ?? ""
            return listing.contains(researchEntry) && listing.contains(vphoneEntry)
        }
    }

    /// Every property as `path name flags value`, with phandles left out and
    /// phandle references given as the path they name: the two trees number
    /// their nodes differently.
    static func describe(_ root: DeviceTreePatcher.DTNode) -> Set<String> {
        var paths: [Data: String] = [:]
        var nodes: [(String, DeviceTreePatcher.DTNode)] = []
        func walk(_ node: DeviceTreePatcher.DTNode, _ path: String) {
            nodes.append((path, node))
            if let phandle = value(node, "AAPL,phandle") { paths[phandle] = path }
            var seen: [String: Int] = [:]
            for child in node.children {
                let childName = name(child)
                let index = seen[childName, default: 0]
                seen[childName] = index + 1
                walk(child, path + "/" + childName + (index > 0 ? "#\(index)" : ""))
            }
        }
        walk(root, "")
        let references: Set<String> = ["interrupt-parent", "device-interrupt-parent", "serial-device"]
        var lines = Set<String>()
        for (path, node) in nodes {
            for property in node.properties where property.name != "AAPL,phandle" && property.name != "time-stamp" {
                let shown = references.contains(property.name)
                    ? "-> " + (paths[property.value] ?? "dangling")
                    : property.value.map { String(format: "%02x", $0) }.joined()
                lines.insert("\(path) \(property.name) \(property.flags) \(shown)")
            }
        }
        return lines
    }

    @Test(
        "Apple's research board tree converts into Apple's vphone600 tree of the same release",
        .enabled(if: !pairedIPSWs.isEmpty, "needs a cloudOS IPSW with both device trees in ipsws/"),
    )
    func matchesApplesTree() throws {
        for ipsw in Self.pairedIPSWs {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try CustomFirmwarePatchFixtures.run("/usr/bin/unzip", ["-o", "-j", ipsw.path, Self.researchEntry, Self.vphoneEntry, "-d", directory.path])
            try #require(result.status == 0)

            let research = try IM4PHandler.load(contentsOf: directory.appending(path: "DeviceTree.vresearch101ap.im4p")).payload
            let vphone = try IM4PHandler.load(contentsOf: directory.appending(path: "DeviceTree.vphone600ap.im4p")).payload
            let (_, converted, _) = try Self.convert(research)
            let (_, expected, _) = try Self.convert(vphone)

            let produced = Self.describe(converted)
            let apple = Self.describe(expected)
            #expect(produced.subtracting(apple).sorted() == [], "\(ipsw.lastPathComponent): not in vphone600")
            #expect(apple.subtracting(produced).sorted() == [], "\(ipsw.lastPathComponent): missing from the conversion")
        }
    }
}
