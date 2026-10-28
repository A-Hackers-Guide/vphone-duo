// CustomFirmwarePanelTests.swift — a foldable guest takes the board's panel nodes.
//
// With `panels`, `withPhoneProduct` also copies `/product/display<N>` from a board that
// describes more than one panel, as the iPhone Duo's does, into a guest that
// has none. The copies keep every property but the phandle, which is given a
// fresh value past the guest's highest so none collides.

@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Foldable panel nodes from the board tree")
struct CustomFirmwarePanelTests {
    private typealias Node = FlatDeviceTreeNode

    private static func tree(product: Node) -> Data {
        Node("device-tree", [("AAPL,phandle", Node.uint32(1))], children: [
            Node("chosen", [("AAPL,phandle", Node.uint32(2))]),
            product,
        ]).serialized
    }

    private static let guestProduct = Node("product", [
        ("AAPL,phandle", Node.uint32(3)),
        ("product-name", Data("iPhone Duo\0".utf8)),
    ])

    private static func panel(_ index: UInt32, phandle: UInt32, region: String? = nil) -> Node {
        var properties: [(String, Data)] = [
            ("AAPL,phandle", Node.uint32(phandle)),
            ("display-index", Node.uint32(index)),
            ("display-rotation", Node.uint32(index == 0 ? 0 : 270)),
        ]
        if let region {
            properties.append(("special-region-1-type", Data((region + "\0").utf8)))
        }
        return Node("display\(index)", properties)
    }

    private static func boardProduct(panels: [Node]) -> Node {
        var product = Node("product", [("AAPL,phandle", Node.uint32(470)), ("product-name", Data("iPhone Duo\0".utf8))])
        product.children = panels
        return product
    }

    // MARK: - Tests

    @Test func `adds each panel of a foldable with a fresh phandle`() throws {
        let original = Self.tree(product: Self.guestProduct)
        let board = Self.tree(product: Self.boardProduct(panels: [
            Self.panel(0, phandle: 470), Self.panel(1, phandle: 471, region: "Fold"),
        ]))
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board, panels: true)
        #expect(changes.map(\.property) == ["product/display0", "product/display1"])
        #expect(changes.allSatisfy { $0.before == "absent" })
        #expect(patched.count == original.count + delta)

        var presented = Self.guestProduct
        presented.children = [Self.panel(0, phandle: 4), Self.panel(1, phandle: 5, region: "Fold")]
        #expect(patched == Self.tree(product: presented))
    }

    @Test func `without panels the nodes stay out`() throws {
        let original = Self.tree(product: Self.guestProduct)
        let board = Self.tree(product: Self.boardProduct(panels: [
            Self.panel(0, phandle: 470), Self.panel(1, phandle: 471),
        ]))
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board)
        #expect(changes.isEmpty)
        #expect(patched == original)
    }

    @Test func `a board with one panel adds nothing`() throws {
        let original = Self.tree(product: Self.guestProduct)
        let board = Self.tree(product: Self.boardProduct(panels: [Self.panel(0, phandle: 470)]))
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board, panels: true)
        #expect(changes.isEmpty)
        #expect(delta == 0)
        #expect(patched == original)
    }

    @Test func `a panel a driver would bind to is left out`() throws {
        var bound = Self.panel(1, phandle: 471)
        bound.properties.append(("compatible", 0, Data("disp0,t8160\0".utf8)))
        let original = Self.tree(product: Self.guestProduct)
        let board = Self.tree(product: Self.boardProduct(panels: [Self.panel(0, phandle: 470), bound]))
        let (_, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board, panels: true)
        #expect(changes.isEmpty)
    }

    @Test func `a guest that has its panels is unchanged`() throws {
        var presented = Self.guestProduct
        presented.children = [Self.panel(0, phandle: 4), Self.panel(1, phandle: 5)]
        let original = Self.tree(product: presented)
        let board = Self.tree(product: Self.boardProduct(panels: [
            Self.panel(0, phandle: 470), Self.panel(1, phandle: 471),
        ]))
        let (patched, changes, _) = try CustomFirmwarePostRestoreDeviceTree.withPhoneProduct(original, board: board, panels: true)
        #expect(changes.isEmpty)
        #expect(patched == original)
    }
}
