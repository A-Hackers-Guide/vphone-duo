import Foundation
import Testing
import Virtualization
@testable import VPhoneCoreKit

struct DiskAttachmentTests {
    private func withImage(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-disk-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Disk.img")
        // Sparse, as Disk.img is.
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 << 20)
        try handle.close()
        try body(url)
    }

    @Test func `file disks are attached cached with full synchronization`() throws {
        try withImage { url in
            let attachment = try VPhoneDiskAttachment.make(url: url, readOnly: false)
            #expect(attachment.cachingMode == .cached)
            #expect(attachment.synchronizationMode == .full)
            #expect(!attachment.isReadOnly)
        }
    }

    @Test func `read-only file disks are attached cached too`() throws {
        try withImage { url in
            let attachment = try VPhoneDiskAttachment.make(url: url, readOnly: true)
            #expect(attachment.cachingMode == .cached)
            #expect(attachment.isReadOnly)
        }
    }

    /// `vphone-vm` must not build a file disk any other way: every
    /// `VZDiskImageStorageDeviceAttachment(` in the shipped sources has to be
    /// the one inside `VPhoneDiskAttachment`.
    @Test func `no other code attaches a disk image`() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VirtualMachine
            .deletingLastPathComponent() // VPhoneCoreKitTests
            .deletingLastPathComponent() // VPhoneKit
            .deletingLastPathComponent() // repository root
        let roots = ["VPhoneKit", "VPhoneExecutable", "VPhoneLaunchpad", "VPhoneDaemon"]
            .map { repo.appendingPathComponent($0) }
        var offenders: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in walker where file.pathExtension == "swift" {
                if file.path.contains("/.build/") || file.lastPathComponent == "VPhoneDiskAttachment.swift" {
                    continue
                }
                if file.path.contains("Tests/") { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("VZDiskImageStorageDeviceAttachment(") {
                    offenders.append(file.path)
                }
            }
        }
        #expect(offenders.isEmpty, "attach file disks through VPhoneDiskAttachment.make: \(offenders)")
    }
}
