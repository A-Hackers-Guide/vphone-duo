// CustomFirmwareBoardHapticsTests.swift — an iPad guest has the board's haptics node, or none.
//
// `withBoardHaptics` (the Preboot repair) and
// `DeviceTreePatcher.presentBoardHaptics` (what `fw patch` runs for an iPad's
// installed tree) make `/product/haptics` what the board tree has: removed for
// an iPad, which has no Taptic Engine. The trees here are built in the flat
// format the restored tree uses, so the parse, the edit and the serialization
// all run.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("iPad haptics node from the board tree")
struct CustomFirmwareBoardHapticsTests {
    // MARK: - A flat device tree

    private struct Node {
        var properties: [(name: String, flags: UInt16, value: Data)]
        var children: [Node] = []
    }

    private static func node(_ name: String, _ properties: [(String, Data)] = [], children: [Node] = []) -> Node {
        Node(
            properties: [("name", 0, Data((name + "\0").utf8))] + properties.map { ($0.0, 0, $0.1) },
            children: children,
        )
    }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func serialize(_ node: Node) -> Data {
        var out = uint32(UInt32(node.properties.count)) + uint32(UInt32(node.children.count))
        for (name, flags, value) in node.properties {
            var field = Data(name.utf8)
            field.append(contentsOf: [UInt8](repeating: 0, count: 32 - field.count))
            out.append(field)
            out.append(contentsOf: withUnsafeBytes(of: UInt16(value.count).littleEndian) { Array($0) })
            out.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })
            out.append(value)
            out.append(contentsOf: [UInt8](repeating: 0, count: (4 - value.count % 4) % 4))
        }
        for child in node.children {
            out.append(serialize(child))
        }
        return out
    }

    /// A tree whose `/product` holds `maps`, then `haptics` when given, then
    /// `util` — the node sits between siblings, as it does on vphone600.
    private static func tree(haptics: Node?) -> Data {
        let product = node(
            "product",
            [("product-name", Data("iPad\0".utf8))],
            children: [node("maps", [("regulatory", uint32(1))])]
                + (haptics.map { [$0] } ?? [])
                + [node("util", [("ramdisk", uint32(0))])],
        )
        return serialize(node("device-tree", [("model", Data("iPad16,1\0".utf8))], children: [product]))
    }

    /// What vphone600 carries.
    private static let guestHaptics = node("haptics", [
        ("closed-loop", uint32(1)),
        ("supports-3rd-party-haptics", uint32(1)),
        ("AAPL,phandle", uint32(100)),
    ])

    /// A board that does have an actuator.
    private static let boardHaptics = node("haptics", [
        ("closed-loop", uint32(1)),
        ("supports-3rd-party-haptics", uint32(0)),
        ("AAPL,phandle", uint32(7)),
    ])

    // MARK: - Tests

    @Test func `removes the node an iPad's tree does not have`() throws {
        let original = Self.tree(haptics: Self.guestHaptics)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
            original,
            board: Self.tree(haptics: nil),
        )
        #expect(changes.map(\.property) == ["product/haptics"])
        #expect(changes.first?.after == "absent")
        #expect(delta < 0)
        #expect(patched.count == original.count + delta)
        // The siblings on either side survive, in order.
        #expect(patched == Self.tree(haptics: nil))
    }

    @Test func `a tree with no node is left alone`() throws {
        let original = Self.tree(haptics: nil)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
            original,
            board: Self.tree(haptics: nil),
        )
        #expect(changes.isEmpty)
        #expect(delta == 0)
        #expect(patched == original)
    }

    @Test func `removing twice changes nothing the second time`() throws {
        let board = Self.tree(haptics: nil)
        let (once, _, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
            Self.tree(haptics: Self.guestHaptics),
            board: board,
        )
        let (twice, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(once, board: board)
        #expect(changes.isEmpty)
        #expect(twice == once)
    }

    @Test func `a board with a node gives its properties and keeps the guest's phandle`() throws {
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
            Self.tree(haptics: Self.guestHaptics),
            board: Self.tree(haptics: Self.boardHaptics),
        )
        #expect(changes.first?.after.hasPrefix("present") == true)
        let expected = Self.node("haptics", [
            ("closed-loop", Self.uint32(1)),
            ("supports-3rd-party-haptics", Self.uint32(0)),
            ("AAPL,phandle", Self.uint32(100)),
        ])
        #expect(patched == Self.tree(haptics: expected))
    }

    @Test func `a tree that already matches the board's node is left alone`() throws {
        var matching = Self.boardHaptics
        matching.properties[3].value = Self.uint32(100)
        let original = Self.tree(haptics: matching)
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
            original,
            board: Self.tree(haptics: Self.boardHaptics),
        )
        #expect(changes.isEmpty)
        #expect(patched == original)
    }

    @Test func `a truncated tree is refused`() {
        let original = Self.tree(haptics: Self.guestHaptics)
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withBoardHaptics(
                original.prefix(original.count - 4),
                board: Self.tree(haptics: nil),
            )
        }
    }
}
