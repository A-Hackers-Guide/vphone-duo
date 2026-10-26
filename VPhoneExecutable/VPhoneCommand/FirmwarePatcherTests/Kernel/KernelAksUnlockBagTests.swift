// KernelAksUnlockBagTests.swift — The aks_unlock_bag scalar-count patch
// against the selector-12 count check as the vphone600 26.4 kernel ships it.
//
// Every word below is keystone 0.9.2 (Homebrew `kstool`, outside this
// repository), assembled with the block at address 0 except `bti j`, which
// keystone does not know and is the kernel's own word. The fixed words match
// both 26.4 variants byte for byte (research 0xfffffe0007f35184, release
// 0xfffffe0007eb7c44 after its own `bti j`).

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("kernel-cfw-aks_unlock_bag")
struct KernelAksUnlockBagTests {
    // MARK: - Synthetic kernel

    /// The count check with its targets inside the block: count-3 path at
    /// +0x34, join at +0x38, BadArgument at +0x3C.
    static let stockBlock: [UInt32] = [
        0xD503_249F, // bti j
        0xB940_2A68, // ldr w8, [x19, #0x28]
        0x7100_0D1F, // cmp w8, #3
        0x5400_0140, // b.eq #0x34
        0x7100_111F, // cmp w8, #4
        0x5400_0141, // b.ne #0x3c
        0xB940_5268, // ldr w8, [x19, #0x50]
        0x3500_0108, // cbnz w8, #0x3c
        0xF940_1268, // ldr x8, [x19, #0x20]
        0xF940_0D09, // ldr x9, [x8, #0x18]
        0xF100_013F, // cmp x9, #0
        0x1A9F_07F9, // cset w25, ne
        0x1400_0002, // b #0x38
        0xD503_201F, // nop (count 3)
        0xD503_201F, // nop (join)
        0xD503_201F, // nop (BadArgument)
    ]

    static let siteOffset = 0x10
    static let caveOffset = 0x40

    /// The block, then a zeroed cave directly after it, inside a minimal arm64
    /// kernel image with one `__TEXT_EXEC` segment.
    static func kernel(withBlock block: [UInt32]) -> (data: Data, blockOff: Int) {
        let textStart = 0x100
        var text = [UInt8](repeating: 0xD4, count: 0x20)
        let blockOff = textStart + text.count
        for word in block {
            withUnsafeBytes(of: word.littleEndian) { text.append(contentsOf: $0) }
        }
        text += [UInt8](repeating: 0, count: 0x20)
        while text.count % 0x100 != 0 {
            text.append(0xD4)
        }

        var image = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { image.append(contentsOf: $0) }
        }
        func append64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { image.append(contentsOf: $0) }
        }

        append32(0xFEED_FACF) // magic
        append32(0x0100_000C) // cputype: arm64
        append32(2) // cpusubtype: arm64e
        append32(2) // filetype
        append32(1) // ncmds
        append32(72) // sizeofcmds
        append32(0) // flags
        append32(0) // reserved
        // LC_SEGMENT_64 __TEXT_EXEC
        append32(0x19)
        append32(72)
        var segname = Data("__TEXT_EXEC".utf8).prefix(16)
        segname.append(contentsOf: [UInt8](repeating: 0, count: 16 - segname.count))
        image.append(segname)
        append64(0xFFFF_FE00_0700_4000) // vmaddr
        append64(UInt64(text.count)) // vmsize
        append64(UInt64(textStart)) // fileoff
        append64(UInt64(text.count)) // filesize
        append32(5) // maxprot r-x
        append32(5) // initprot r-x
        append32(0) // nsects
        append32(0) // flags

        image.append(contentsOf: [UInt8](repeating: 0, count: textStart - image.count))
        image.append(contentsOf: text)
        return (image, blockOff)
    }

    static func words(_ data: Data) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { data.loadLE(UInt32.self, at: $0) }
    }

    // MARK: - The patch

    @Test func `routes count 4 and 5 to the count-4 path`() throws {
        let (data, blockOff) = Self.kernel(withBlock: Self.stockBlock)
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()

        #expect(patcher.patchAksUnlockBagCount5())
        #expect(patcher.patches.count == 2)

        let redirect = try #require(patcher.patches.first { $0.patchID == "kernel-cfw-aks_unlock_bag.redirect" })
        #expect(redirect.fileOffset == blockOff + Self.siteOffset)
        #expect(Self.words(redirect.patchedBytes) == [0x1400_000C]) // b #0x40

        let cave = try #require(patcher.patches.first { $0.patchID == "kernel-cfw-aks_unlock_bag.cave" })
        #expect(cave.fileOffset == blockOff + Self.caveOffset)
        #expect(Self.words(cave.patchedBytes) == [
            0x7100_111F, // cmp w8, #4
            0x5400_0080, // b.eq #0x54
            0x7100_151F, // cmp w8, #5
            0x5400_0040, // b.eq #0x54
            0x17FF_FFFB, // b #0x3c (BadArgument)
            0x17FF_FFF1, // b #0x18 (count-4 path)
        ])
    }

    @Test func `does not match a second time over patched bytes`() {
        let (data, _) = Self.kernel(withBlock: Self.stockBlock)
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()
        #expect(patcher.patchAksUnlockBagCount5())

        let second = KernelCustomFirmwarePatcher(data: patcher.patchedData, verbose: false)
        second.parseMachO()
        #expect(!second.patchAksUnlockBagCount5())
        #expect(second.patches.isEmpty)
    }

    @Test func `refuses a check whose struct-count branch goes elsewhere`() {
        var block = Self.stockBlock
        block[7] = 0x3500_0068 // cbnz w8, #0x28
        let (data, _) = Self.kernel(withBlock: block)
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()

        #expect(!patcher.patchAksUnlockBagCount5())
        #expect(patcher.patches.isEmpty)
    }

    // MARK: - The real kernel

    /// Gated on `VPHONE_VP600_KERNEL`, a machine-local kernelcache.*.vphone600
    /// (IM4P or raw) from the cloudOS 26.4 restore.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["VPHONE_VP600_KERNEL"] != nil,
        "VPHONE_VP600_KERNEL is not set; point it at a kernelcache.*.vphone600 to run",
    ))
    func `patches a real vphone600 kernel`() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_VP600_KERNEL"])
        let (payload, _) = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path))

        let patcher = KernelCustomFirmwarePatcher(data: payload, verbose: true)
        patcher.parseMachO()
        #expect(patcher.patchAksUnlockBagCount5())

        let redirect = try #require(patcher.patches.first { $0.patchID == "kernel-cfw-aks_unlock_bag.redirect" })
        let cave = try #require(patcher.patches.first { $0.patchID == "kernel-cfw-aks_unlock_bag.cave" })
        #expect(redirect.beforeDisasm == "cmp w8, #4")
        #expect(ARM64Encoder.encodeB(from: redirect.fileOffset, to: cave.fileOffset) == redirect.patchedBytes)
        #expect(Array(Self.words(cave.patchedBytes)[0 ..< 4]) == [0x7100_111F, 0x5400_0080, 0x7100_151F, 0x5400_0040])
    }
}
