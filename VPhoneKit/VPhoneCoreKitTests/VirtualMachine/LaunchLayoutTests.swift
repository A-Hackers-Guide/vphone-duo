import Foundation
import Testing
@testable import VPhoneCoreKit

struct LaunchLayoutTests {
    @Test func `delegates to resources`() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/proj"))
        let layout = VPhoneLaunchLayout(resources: resources)
        #expect(layout.vphoned.path == resources.vphoned.path)
    }

    @Test func `parses lsof PI ds`() {
        #expect(VPhoneLsof.parsePIDs("123\n456\n123\n\n  \nnotapid\n789\n") == [123, 456, 789])
        #expect(VPhoneLsof.parsePIDs("") == [])
    }

    // MARK: - Guest processes

    /// A KERN_PROCARGS2 buffer as the kernel lays it out.
    private func processArguments(_ executable: String, _ arguments: [String], padding: Int = 3) -> [UInt8] {
        var buffer = withUnsafeBytes(of: Int32(arguments.count).littleEndian, Array.init)
        buffer += Array(executable.utf8) + [UInt8](repeating: 0, count: padding)
        for argument in arguments {
            buffer += Array(argument.utf8) + [0]
        }
        // The environment follows the arguments.
        buffer += Array("HOME=/Users/test".utf8) + [0]
        return buffer
    }

    @Test func `parses process arguments`() {
        let path = "/Library/Bundles/VPhone.bundle/Contents/MacOS/vphone-vm"
        let buffer = processArguments(path, [path, "--config", "/vms/a/config.plist"])
        #expect(VPhoneGuestProcesses.parseProcessArguments(buffer) == [path, "--config", "/vms/a/config.plist"])
        #expect(VPhoneGuestProcesses.parseProcessArguments([]) == nil)
        #expect(VPhoneGuestProcesses.parseProcessArguments(Array(buffer.prefix(12))) == nil)
    }

    @Test func `matches only the vphone-vm of one machine`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let machine = root.appendingPathComponent("machines/a")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = machine.appendingPathComponent("config.plist")
        try Data().write(to: config)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("machines"))
        let target = config.resolvingSymlinksInPath().standardizedFileURL.path
        let vm = "/B/VPhone.bundle/Contents/MacOS/vphone-vm"

        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", config.path], configPath: target))
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--headless", "--config=\(config.path)"], configPath: target))
        // Another spelling of the same file.
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", link.path + "/a/config.plist"], configPath: target))
        #expect(VPhoneGuestProcesses.runsMachine([vm, "--config", machine.path + "/../a/config.plist"], configPath: target))
        // Another machine, another program, or no --config.
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--config", root.path + "/machines/b/config.plist"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine(["/usr/bin/vim", "--config", config.path], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--dfu"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([vm, "--config"], configPath: target))
        #expect(!VPhoneGuestProcesses.runsMachine([], configPath: target))
    }

    @Test func `finds a running vphone-vm by its config`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A stand-in that lives long enough to be found under the right name.
        let program = root.appendingPathComponent("vphone-vm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/yes"), to: program)
        let config = root.appendingPathComponent("config.plist")
        let other = root.appendingPathComponent("other.plist")
        let process = Process()
        process.executableURL = program
        // yes prints its arguments and blocks once the unread pipe fills.
        process.arguments = ["--config", config.path]
        process.standardOutput = Pipe()
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.2)

        #expect(VPhoneGuestProcesses.virtualMachinePIDs(config: config) == [process.processIdentifier])
        #expect(VPhoneGuestProcesses.virtualMachinePIDs(config: other).isEmpty)
    }

    @Test func `stage vphoned copies when source exists`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        let layout = VPhoneLaunchLayout(projectRoot: root)
        #expect(try layout.stageVphoned(into: bundle) == true)
        #expect(FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent(".vphoned.signed").path))
        // Second call is a no-op (already identical).
        #expect(try layout.stageVphoned(into: bundle) == false)
    }

    @Test func `stage vphoned fails when source absent`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No .build/vphoned.signed created → source absent.
        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(throws: VPhoneGuestBinaries.Error.self) {
            try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle)
        }
        #expect(!FileManager.default.fileExists(
            atPath: bundleDir.appendingPathComponent(".vphoned.signed").path,
        ))
    }

    @Test func `stage vphoned overwrites stale destination`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"),
            withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([9, 9, 9, 9]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        // Pre-populate dst with DIFFERENT bytes.
        try Data([1, 1]).write(to: bundleDir.appendingPathComponent(".vphoned.signed"))
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2,
            memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"),
        )
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle) == true)
        let staged = try Data(contentsOf: bundleDir.appendingPathComponent(".vphoned.signed"))
        #expect(staged == Data([9, 9, 9, 9]))
    }
}
