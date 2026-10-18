import Foundation
import Testing
@testable import VPhoneCoreKit

/// Which SEP ROM a machine starts its SEP from, and how it gets there.
///
/// New machines copy OpenSEP and keep it as `OpenSEP.bin`; Apple's keeps
/// `AVPSEPBooter.vresearch1.bin`. Changing SEP ROM only repoints
/// `romImages.avpSEPBooter`, leaves the boot ROM alone and keeps the other SEP
/// ROM in the folder.
struct SEPROMTests {
    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A SEP ROM image of `kind`: Apple's carries its version string.
    private func seprom(_ kind: VPhoneSEPROM, in dir: URL, tag: UInt8 = 0) throws -> URL {
        var bytes = Data([0x1F, 0x20, 0x03, 0xD5, tag])
        if kind == .apple {
            bytes.append(Data("....AVPSEPBooter-9.120.2\0".utf8))
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".bin")
        try bytes.write(to: url)
        return url
    }

    private func newMachine(seprom: URL, in root: URL) throws -> VPhoneBundle {
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0x01]).write(to: rom)
        return try VPhoneBundleOperations.create(
            .init(name: "phone", cpuCount: 2, memoryMB: 2048, diskSizeGB: 1, romSource: rom, sepromSource: seprom),
            in: VPhoneLibrary(root: root.appendingPathComponent("library")),
        )
    }

    // MARK: - Recognition

    @Test func `Apple's SEP ROM is recognised by its version string and anything else is OpenSEP`() throws {
        #expect(VPhoneSEPROM.kind(of: Data("xxAVPSEPBooter-9.120.2\0".utf8)) == .apple)
        #expect(VPhoneSEPROM.kind(of: Data("Apple DDI Secure Boot Root CA - G1".utf8)) == .openSEP)
        #expect(VPhoneSEPROM.kind(of: Data()) == .openSEP)
        #expect(VPhoneSEPROM.kind(at: URL(fileURLWithPath: "/nonexistent/seprom.bin")) == nil)
    }

    @Test func `the checked-in OpenSEP image is recognised as OpenSEP and fits the SEP ROM window`() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let image = VPhoneSEPROM.openSEPSource(resources: VPhoneResources(base: repository))
        #expect(image.path.hasSuffix("Resources/OpenSEP/OpenSEP.bin"))
        #expect(VPhoneSEPROM.kind(at: image) == .openSEP)
        let size = try Data(contentsOf: image).count
        #expect(size > 0 && size <= 0x29000)
    }

    @Test func `the framework's SEP ROM is recognised as Apple's`() throws {
        try #require(FileManager.default.fileExists(atPath: VPhoneSEPROM.appleSource.path))
        #expect(VPhoneSEPROM.kind(at: VPhoneSEPROM.appleSource) == .apple)
    }

    // MARK: - vm new

    @Test func `a new machine keeps each SEP ROM under the name of its kind`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let openSEP = try newMachine(seprom: seprom(.openSEP, in: root), in: root)
        #expect(openSEP.manifest.romImages?.avpSEPBooter == "OpenSEP.bin")
        #expect(FileManager.default.fileExists(atPath: openSEP.url.appendingPathComponent("OpenSEP.bin").path))
        #expect(!FileManager.default.fileExists(atPath: openSEP.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin").path))
        #expect(VPhoneSEPROM.kind(ofMachineAt: openSEP.url) == .openSEP)
        #expect(VPhoneBundleReport(bundle: openSEP).sepROM == "opensep")

        let other = try makeRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        let apple = try newMachine(seprom: seprom(.apple, in: other), in: other)
        #expect(apple.manifest.romImages?.avpSEPBooter == "AVPSEPBooter.vresearch1.bin")
        #expect(VPhoneSEPROM.kind(ofMachineAt: apple.url) == .apple)
        #expect(VPhoneBundleReport(bundle: apple).sepROM == "apple")
    }

    @Test func `a new machine refuses a SEP ROM it cannot read`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try newMachine(seprom: root.appendingPathComponent("missing.bin"), in: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library/phone").path))
    }

    // MARK: - Changing SEP ROM

    @Test func `changing SEP ROM repoints the manifest and keeps the boot ROM and the other SEP ROM`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apple = try newMachine(seprom: seprom(.apple, in: root, tag: 7), in: root)
        let bootROM = apple.manifest.romImages?.avpBooter
        let appleImage = try Data(contentsOf: apple.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin"))

        let switched = try VPhoneBundleOperations.installSEPROM(from: seprom(.openSEP, in: root), in: apple)
        #expect(switched.manifest.romImages?.avpSEPBooter == "OpenSEP.bin")
        #expect(switched.manifest.romImages?.avpBooter == bootROM)
        #expect(try VPhoneVirtualMachineManifest.load(from: switched.configURL).romImages?.avpSEPBooter == "OpenSEP.bin")
        #expect(VPhoneSEPROM.kind(ofMachineAt: switched.url) == .openSEP)
        #expect(try Data(contentsOf: apple.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin")) == appleImage)

        let kept = switched.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin")
        let back = try VPhoneBundleOperations.installSEPROM(from: kept, in: switched)
        #expect(back.manifest.romImages?.avpSEPBooter == "AVPSEPBooter.vresearch1.bin")
        #expect(back.manifest.romImages?.avpBooter == bootROM)
        #expect(try Data(contentsOf: kept) == appleImage)
        #expect(VPhoneSEPROM.kind(ofMachineAt: back.url) == .apple)
    }

    @Test func `changing boot ROM leaves the SEP ROM alone`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = try newMachine(seprom: seprom(.openSEP, in: root), in: root)
        let openAVB = root.appendingPathComponent("openavb.bin")
        try Data("OpenBootROM: SEP bootstrap complete\n".utf8).write(to: openAVB)

        let switched = try VPhoneBundleOperations.installBootROM(from: openAVB, in: machine)
        #expect(switched.manifest.romImages?.avpBooter == "OpenAVB.bin")
        #expect(switched.manifest.romImages?.avpSEPBooter == "OpenSEP.bin")
        #expect(VPhoneSEPROM.kind(ofMachineAt: switched.url) == .openSEP)
    }

    @Test func `installing OpenSEP again replaces the copy in the folder`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = try newMachine(seprom: seprom(.openSEP, in: root, tag: 1), in: root)
        let newer = try seprom(.openSEP, in: root, tag: 2)

        try VPhoneBundleOperations.installSEPROM(from: newer, in: machine)
        #expect(try Data(contentsOf: machine.url.appendingPathComponent("OpenSEP.bin")) == Data(contentsOf: newer))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: machine.url.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}
