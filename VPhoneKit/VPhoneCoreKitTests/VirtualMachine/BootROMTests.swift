import Foundation
import Testing
@testable import VPhoneCoreKit

/// Which boot ROM a machine starts from, and how it gets there.
///
/// New machines copy OpenAVB and keep it as `OpenAVB.bin`; an Apple ROM keeps
/// `AVPBooter.vresearch1.bin`, the name `fw patch` looks for. Changing ROM only
/// repoints `romImages.avpBooter` and leaves the other ROM in the folder.
struct BootROMTests {
    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A ROM image of `kind`: OpenAVB's carries its console prefix.
    private func rom(_ kind: VPhoneBootROM, in dir: URL, tag: UInt8 = 0) throws -> URL {
        var bytes = Data([0x1F, 0x20, 0x03, 0xD5, tag])
        if kind == .openAVB {
            bytes.append(Data("....OpenBootROM: SEP bootstrap complete\n".utf8))
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".bin")
        try bytes.write(to: url)
        return url
    }

    private func newMachine(rom: URL, in root: URL) throws -> VPhoneBundle {
        let seprom = root.appendingPathComponent("seprom.bin")
        try Data([0x01]).write(to: seprom)
        return try VPhoneBundleOperations.create(
            .init(name: "phone", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: VPhoneLibrary(root: root.appendingPathComponent("library")),
        )
    }

    // MARK: - Recognition

    @Test func `OpenAVB is recognised by its console prefix and anything else is Apple's`() throws {
        #expect(VPhoneBootROM.kind(of: Data("xxOpenBootROM: iLLB container accepted\n".utf8)) == .openAVB)
        #expect(VPhoneBootROM.kind(of: Data("iBoot for vresearch101".utf8)) == .apple)
        #expect(VPhoneBootROM.kind(of: Data()) == .apple)
        #expect(VPhoneBootROM.kind(at: URL(fileURLWithPath: "/nonexistent/rom.bin")) == nil)
    }

    @Test func `the checked-in OpenAVB image is recognised as OpenAVB`() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let image = VPhoneBootROM.openAVBSource(resources: VPhoneResources(base: repository))
        #expect(image.path.hasSuffix("Resources/OpenAVB/OpenAVB.bin"))
        #expect(VPhoneBootROM.kind(at: image) == .openAVB)
    }

    // MARK: - vm new

    @Test func `a new machine keeps each ROM under the name of its kind`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let openAVB = try newMachine(rom: rom(.openAVB, in: root), in: root)
        #expect(openAVB.manifest.romImages?.avpBooter == "OpenAVB.bin")
        #expect(FileManager.default.fileExists(atPath: openAVB.url.appendingPathComponent("OpenAVB.bin").path))
        #expect(!FileManager.default.fileExists(atPath: openAVB.url.appendingPathComponent("AVPBooter.vresearch1.bin").path))
        #expect(VPhoneBootROM.kind(ofMachineAt: openAVB.url) == .openAVB)
        #expect(VPhoneBundleReport(bundle: openAVB).bootROM == "openavb")

        let other = try makeRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        let apple = try newMachine(rom: rom(.apple, in: other), in: other)
        #expect(apple.manifest.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
        #expect(VPhoneBootROM.kind(ofMachineAt: apple.url) == .apple)
        #expect(VPhoneBundleReport(bundle: apple).bootROM == "apple")
    }

    @Test func `a new machine refuses a ROM it cannot read`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try newMachine(rom: root.appendingPathComponent("missing.bin"), in: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library/phone").path))
    }

    // MARK: - Changing ROM

    @Test func `changing ROM repoints the manifest and keeps the other ROM`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apple = try newMachine(rom: rom(.apple, in: root, tag: 7), in: root)
        let patchedApple = try Data(contentsOf: apple.url.appendingPathComponent("AVPBooter.vresearch1.bin"))

        let switched = try VPhoneBundleOperations.installBootROM(from: rom(.openAVB, in: root), in: apple)
        #expect(switched.manifest.romImages?.avpBooter == "OpenAVB.bin")
        #expect(switched.manifest.romImages?.avpSEPBooter == apple.manifest.romImages?.avpSEPBooter)
        #expect(try VPhoneVirtualMachineManifest.load(from: switched.configURL).romImages?.avpBooter == "OpenAVB.bin")
        #expect(VPhoneBootROM.kind(ofMachineAt: switched.url) == .openAVB)
        // The Apple ROM, with whatever fw patch did to it, is still there.
        #expect(try Data(contentsOf: apple.url.appendingPathComponent("AVPBooter.vresearch1.bin")) == patchedApple)

        // Back to it: the folder's own copy, not a new one.
        let kept = switched.url.appendingPathComponent("AVPBooter.vresearch1.bin")
        let back = try VPhoneBundleOperations.installBootROM(from: kept, in: switched)
        #expect(back.manifest.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
        #expect(try Data(contentsOf: kept) == patchedApple)
        #expect(VPhoneBootROM.kind(ofMachineAt: back.url) == .apple)
    }

    @Test func `installing OpenAVB again replaces the copy in the folder`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = try newMachine(rom: rom(.openAVB, in: root, tag: 1), in: root)
        let newer = try rom(.openAVB, in: root, tag: 2)

        try VPhoneBundleOperations.installBootROM(from: newer, in: machine)
        #expect(try Data(contentsOf: machine.url.appendingPathComponent("OpenAVB.bin")) == Data(contentsOf: newer))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: machine.url.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}
