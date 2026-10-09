import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

/// Re-sharing a stopped machine's disk image with another machine's.
///
/// The temporary directory is on the boot volume, which is APFS, so every
/// clone and punched hole here is real, and `F_LOG2PHYS_EXT` shows which
/// blocks two images share. The images are 64 MiB with a few megabytes of
/// data and holes of several megabytes between extents: APFS fills the holes
/// of a small sparse file when it flushes it (a 32 MiB file with 256 KiB of
/// data came back all data), and a hole of about a megabyte between two
/// extents too. They are compared in 64 KiB chunks so that extents cross
/// chunk boundaries.
struct DiskRebaseTests {
    /// The unit of comparison and sharing, 16 KiB on Apple silicon.
    private static let unit = VPhoneDiskRebase.blockSize
    private static let chunk = 64 << 10
    private static let size = 64 << 20

    // MARK: - Fixtures

    /// One run of bytes in an image.
    private struct Extent {
        let offset: Int
        let bytes: [UInt8]

        init(_ offset: Int, _ bytes: [UInt8]) {
            self.offset = offset
            self.bytes = bytes
        }

        init(_ offset: Int, seed: UInt32, count: Int) {
            self.init(offset, DiskRebaseTests.pattern(seed: seed, count: count))
        }
    }

    /// Bytes that differ for each seed and contain no zeros.
    private static func pattern(seed: UInt32, count: Int) -> [UInt8] {
        var state = seed &* 2_654_435_761 | 1
        return (0 ..< count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state) | 1
        }
    }

    private struct Machines {
        let root: URL
        let target: VPhoneBundle
        let base: VPhoneBundle

        var targetImage: URL {
            target.url.appendingPathComponent("Disk.img")
        }

        var baseImage: URL {
            base.url.appendingPathComponent("Disk.img")
        }
    }

    private func makeMachines() throws -> Machines {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let library = VPhoneLibrary(root: root)
        func make(_ name: String) throws -> VPhoneBundle {
            let bundle = try VPhoneBundleOperations.create(
                .init(name: name, cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: rom),
                in: library,
            )
            try Data([4, 5, 6]).write(to: bundle.url.appendingPathComponent("nvram.bin"))
            return bundle
        }
        return try Machines(root: root, target: make("target"), base: make("base"))
    }

    /// Replaces the image with a sparse file of `size` bytes holding `extents`,
    /// flushed so its blocks have physical addresses.
    private func writeImage(_ url: URL, size: Int = DiskRebaseTests.size, _ extents: [Extent]) throws {
        unlink(url.path)
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o777)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(size)) == 0)
        for extent in extents {
            let put = extent.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(extent.offset)) }
            try #require(put == extent.bytes.count)
        }
        try #require(fcntl(fd, F_FULLFSYNC) == 0)
    }

    private func options(chunk: Int = DiskRebaseTests.chunk) -> VPhoneDiskRebase.Options {
        var options = VPhoneDiskRebase.Options()
        options.chunkSize = chunk
        options.freeSpaceReserve = 0
        return options
    }

    /// Rebases after a dry run, and checks what every rebase must keep: the
    /// target's bytes, mode and modification time, the base untouched, a dry run that
    /// predicted the result, and no staging folder.
    @discardableResult
    private func rebase(_ machines: Machines, chunk: Int = DiskRebaseTests.chunk) throws -> VPhoneDiskRebaseReport {
        // Clones: free, and they keep the old bytes for comparison.
        let targetBefore = machines.root.appendingPathComponent("target-before")
        let baseBefore = machines.root.appendingPathComponent("base-before")
        try #require(clonefile(machines.targetImage.path, targetBefore.path, 0) == 0)
        try #require(clonefile(machines.baseImage.path, baseBefore.path, 0) == 0)
        defer {
            unlink(targetBefore.path)
            unlink(baseBefore.path)
        }
        let mode = try mode(of: machines.targetImage)
        let modified = try modified(of: machines.targetImage)

        let planned = try VPhoneDiskRebase.plan(machines.target, onto: machines.base, options: options(chunk: chunk), progress: { _, _, _ in })
        var phases: [VPhoneDiskRebase.Phase] = []
        let report = try VPhoneDiskRebase.rebase(machines.target, onto: machines.base, options: options(chunk: chunk)) { phase, done, total in
            #expect(done <= total)
            if phases.last != phase {
                phases.append(phase)
            }
        }
        #expect(report == planned)
        #expect(phases == [.comparing, .verifying])
        #expect(try sameBytes(machines.targetImage, targetBefore))
        #expect(try sameBytes(machines.baseImage, baseBefore))
        #expect(try self.mode(of: machines.targetImage) == mode)
        #expect(try self.modified(of: machines.targetImage) == modified)
        #expect(try report.logicalSize == Int64(size(of: machines.targetImage)))
        try expectNoStaging(machines)
        return report
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    /// The modification time, in nanoseconds.
    private func modified(of url: URL) throws -> Int {
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        return info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
    }

    private func size(of url: URL) throws -> Int {
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        return Int(info.st_size)
    }

    /// Whether two files have the same size and bytes, read a megabyte at a
    /// time; holes read as zeros.
    private func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
        guard try size(of: a) == size(of: b) else { return false }
        let left = try FileHandle(forReadingFrom: a)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b)
        defer { try? right.close() }
        while true {
            let ours = try left.read(upToCount: 1 << 20) ?? Data()
            let theirs = try right.read(upToCount: 1 << 20) ?? Data()
            guard ours == theirs else { return false }
            if ours.isEmpty { return true }
        }
    }

    private func expectNoStaging(_ machines: Machines) throws {
        let staged = try FileManager.default.contentsOfDirectory(atPath: machines.target.url.path)
            .filter { $0.hasPrefix(VPhoneDiskRebase.stagingPrefix) }
        #expect(staged.isEmpty)
    }

    /// The device offset of the block at `offset`, or nil in a hole.
    private func physical(_ url: URL, at offset: Int) throws -> Int64? {
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_DATA) == off_t(offset) else { return nil }
        var map = log2phys()
        map.l2p_contigbytes = off_t(Self.unit)
        map.l2p_devoffset = off_t(offset)
        try #require(fcntl(fd, F_LOG2PHYS_EXT, &map) == 0)
        return Int64(map.l2p_devoffset)
    }

    /// The bytes in the file's data ranges.
    private func dataBytes(of url: URL) throws -> Int {
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        var total = 0
        var offset: off_t = 0
        while offset < end {
            let data = lseek(fd, offset, SEEK_DATA)
            guard data >= 0 else { break }
            let hole = lseek(fd, data, SEEK_HOLE)
            total += Int(hole - data)
            offset = hole
        }
        return total
    }

    private func isHole(_ url: URL, at offset: Int) throws -> Bool {
        try physical(url, at: offset) == nil
    }

    /// Whether the target's unit at `offset` is the base's, every block of it.
    private func shares(_ machines: Machines, at offset: Int) throws -> Bool {
        for block in stride(from: offset, to: offset + Self.unit, by: 4096) {
            let ours = try physical(machines.targetImage, at: block)
            guard let ours, try ours == physical(machines.baseImage, at: block) else { return false }
        }
        return true
    }

    // MARK: - Sharing

    @Test func `identical images end up sharing every data block`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        // Extents that start and end inside chunks, one across a boundary.
        let unit = Self.unit
        let extents = [
            Extent(0, seed: 1, count: 256 << 10),
            Extent((16 << 20) + 3 * unit, seed: 2, count: 50 * unit),
            Extent((40 << 20) - 3 * unit, seed: 3, count: 20 * unit),
        ]
        try writeImage(machines.baseImage, extents)
        try writeImage(machines.targetImage, extents)
        #expect(try !shares(machines, at: 0))

        let report = try rebase(machines)
        // Every byte the base stores, which is more than the extents: APFS
        // fills the smaller holes between them with zeros.
        let data = try dataBytes(of: machines.baseImage)
        #expect(data >= extents.reduce(0) { $0 + $1.bytes.count })
        #expect(report.sharedBytes == Int64(data))
        #expect(report.writtenBytes == 0)
        #expect(report.punchedBytes == 0)
        #expect(report.comparedBytes == Int64(data))
        for extent in extents {
            for offset in stride(from: extent.offset, to: extent.offset + extent.bytes.count, by: unit) {
                #expect(try shares(machines, at: offset), "unit at \(offset)")
            }
        }
        #expect(try isHole(machines.targetImage, at: 32 << 20))
    }

    @Test(arguments: [16 << 10, 64 << 10, 8 << 20])
    func `only the differing units are written`(chunk: Int) throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let unit = Self.unit
        let data = 2 << 20
        let base = Self.pattern(seed: 7, count: data)
        try writeImage(machines.baseImage, [Extent(0, base)])

        // One byte in each of three units, and a run of 8 units that
        // straddles the boundary at 1 MiB, starting 5 units before it.
        var target = base
        let changed = [3, 50, 127] + Array(((1 << 20) / unit - 5) ..< ((1 << 20) / unit + 3))
        for index in changed {
            target[index * unit + 777] ^= 0xFF
        }
        try writeImage(machines.targetImage, [Extent(0, target)])

        let report = try rebase(machines, chunk: chunk)
        #expect(report.writtenBytes == Int64(changed.count * unit))
        #expect(report.sharedBytes == Int64(data - changed.count * unit))
        #expect(report.punchedBytes == 0)
        for index in 0 ..< data / unit {
            #expect(try shares(machines, at: index * unit) == !changed.contains(index), "unit \(index)")
        }
    }

    // MARK: - Holes

    @Test func `zeros in the target where the base has data become holes`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let unit = Self.unit
        let base = Self.pattern(seed: 11, count: 512 << 10)
        try writeImage(machines.baseImage, [Extent(0, base)])
        // A hole over 128–256 KiB, and one unit written as zeros at 320 KiB.
        let zeros = 320 << 10
        try writeImage(machines.targetImage, [
            Extent(0, Array(base[0 ..< 128 << 10])),
            Extent(256 << 10, Array(base[(256 << 10) ..< zeros])),
            Extent(zeros, [UInt8](repeating: 0, count: unit)),
            Extent(zeros + unit, Array(base[(zeros + unit)...])),
        ])

        let report = try rebase(machines)
        #expect(report.punchedBytes == Int64((128 << 10) + unit))
        #expect(report.writtenBytes == 0)
        #expect(report.sharedBytes == Int64(base.count) - report.punchedBytes)
        #expect(try isHole(machines.targetImage, at: 128 << 10))
        #expect(try isHole(machines.targetImage, at: (256 << 10) - unit))
        #expect(try isHole(machines.targetImage, at: zeros))
        #expect(try shares(machines, at: 256 << 10))
        #expect(try shares(machines, at: zeros + unit))
    }

    @Test func `data in the target where the base has holes is written`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let head = Extent(0, seed: 21, count: 64 << 10)
        let body = Extent(64 << 10, seed: 22, count: (1 << 20) + 3 * Self.unit)
        try writeImage(machines.baseImage, [head])
        try writeImage(machines.targetImage, [head, body])

        let report = try rebase(machines)
        #expect(report.sharedBytes == Int64(head.bytes.count))
        #expect(report.writtenBytes == Int64(body.bytes.count))
        #expect(report.punchedBytes == 0)
        #expect(try shares(machines, at: 0))
        #expect(try !shares(machines, at: body.offset))
        #expect(try isHole(machines.targetImage, at: 32 << 20))
    }

    // MARK: - Sizes

    @Test(arguments: [(64 << 20, 96 << 20), (96 << 20, 64 << 20)])
    func `the result takes the target's size`(targetSize: Int, baseSize: Int) throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let common = Extent(0, seed: 31, count: 1 << 20)
        // Each has data near its own end: the base's past the target's end
        // when it shrinks, the target's past the base's end when it grows.
        let baseTail = Extent(baseSize - (512 << 10), seed: 32, count: 512 << 10)
        let targetTail = Extent(targetSize - (256 << 10), seed: 33, count: 256 << 10)
        try writeImage(machines.baseImage, size: baseSize, [common, baseTail])
        try writeImage(machines.targetImage, size: targetSize, [common, targetTail])

        let report = try rebase(machines)
        #expect(try size(of: machines.targetImage) == targetSize)
        #expect(report.sharedBytes == Int64(common.bytes.count))
        #expect(report.writtenBytes == Int64(targetTail.bytes.count))
        // Growing, the base's tail lies inside the target, where it is a hole.
        #expect(report.punchedBytes == (targetSize > baseSize ? Int64(baseTail.bytes.count) : 0))
        #expect(try shares(machines, at: (1 << 20) - Self.unit))
    }

    @Test func `a partial unit at the end is compared and written, never punched`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let unit = Self.unit
        let size = Self.size + 100
        let common = Extent(0, seed: 41, count: 64 << 10)
        try writeImage(machines.baseImage, size: size, [common, Extent(Self.size, seed: 42, count: 100)])
        // The target's last 100 bytes are zeros where the base has data, and
        // the unit before them has data where the base has a hole.
        try writeImage(machines.targetImage, size: size, [common, Extent(Self.size - unit, seed: 43, count: unit)])

        let report = try rebase(machines)
        #expect(report.writtenBytes == Int64(unit + 100))
        #expect(report.punchedBytes == 0)
        #expect(report.sharedBytes == Int64(common.bytes.count))
    }

    @Test func `a base that ends inside a unit reads as zeros past its end`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let baseSize = Self.size + 1000
        let tail = Extent(Self.size - (64 << 10), seed: 51, count: (64 << 10) + 1000)
        try writeImage(machines.baseImage, size: baseSize, [tail])
        // The same bytes, then zeros to the end of the unit and beyond.
        try writeImage(machines.targetImage, size: Self.size + (1 << 20), [tail])

        let report = try rebase(machines)
        #expect(report.writtenBytes == 0)
        #expect(report.punchedBytes == 0)
        #expect(report.sharedBytes == Int64((64 << 10) + Self.unit))
    }

    // MARK: - Refusals

    @Test func `a machine cannot be rebased onto itself`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        #expect(throws: VPhoneDiskRebaseError.sameMachine(name: "target")) {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.target)
        }
        #expect(throws: VPhoneDiskRebaseError.sameMachine(name: "target")) {
            try VPhoneDiskRebase.plan(machines.target, onto: machines.target)
        }
        // Another name for the same folder is the same machine.
        let link = machines.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: machines.target.url)
        let alias = try VPhoneLibrary(root: machines.root).bundle(named: "alias")
        #expect(throws: VPhoneDiskRebaseError.sameMachine(name: "alias")) {
            try VPhoneDiskRebase.rebase(alias, onto: machines.target)
        }
        try expectNoStaging(machines)
    }

    @Test(arguments: ["target", "base"])
    func `a held state file on either machine refuses`(held: String) throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        try writeImage(machines.baseImage, [Extent(0, seed: 61, count: 64 << 10)])
        try writeImage(machines.targetImage, [Extent(0, seed: 62, count: 64 << 10)])
        var before = stat()
        try #require(stat(machines.targetImage.path, &before) == 0)

        let bundle = held == "target" ? machines.target : machines.base
        let fd = open(bundle.url.appendingPathComponent("SEPStorage").path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let running = VPhoneBundleActivityError.running(name: held, pids: [getpid()])
        #expect(throws: running) {
            try VPhoneDiskRebase.plan(machines.target, onto: machines.base)
        }
        #expect(throws: running) {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.base)
        }
        var after = stat()
        try #require(stat(machines.targetImage.path, &after) == 0)
        #expect(after.st_ino == before.st_ino)
        try expectNoStaging(machines)
    }

    /// A rebase that fails after the staging file exists changes nothing and
    /// leaves nothing behind.
    @Test func `failures leave the target as it was`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let common = Extent(0, seed: 71, count: 256 << 10)
        try writeImage(machines.baseImage, [common])
        try writeImage(machines.targetImage, [common, Extent(512 << 10, seed: 72, count: 64 << 10)])
        let original = machines.root.appendingPathComponent("original")
        try #require(clonefile(machines.targetImage.path, original.path, 0) == 0)
        var inode = stat()
        try #require(stat(machines.targetImage.path, &inode) == 0)

        func expectUnchanged() throws {
            #expect(try sameBytes(machines.targetImage, original))
            var now = stat()
            try #require(stat(machines.targetImage.path, &now) == 0)
            #expect(now.st_ino == inode.st_ino)
            try expectNoStaging(machines)
        }

        // A staged byte that does not match is caught by verification.
        var corrupt = options()
        corrupt.beforeVerify = { staged in
            let fd = open(staged.path, O_RDWR)
            defer { close(fd) }
            var byte: UInt8 = 0xEE
            _ = pwrite(fd, &byte, 1, off_t(5000))
        }
        #expect(throws: VPhoneDiskRebaseError.verificationFailed(offset: 5000)) {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.base, options: corrupt, progress: { _, _, _ in })
        }
        try expectUnchanged()

        // The target starts while the staging file is checked.
        var held: Int32 = -1
        var started = options()
        started.beforeSwap = { held = open(machines.targetImage.path, O_RDONLY) }
        #expect(throws: VPhoneBundleActivityError.running(name: "target", pids: [getpid()])) {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.base, options: started, progress: { _, _, _ in })
        }
        close(held)
        try expectUnchanged()

        // Writing would leave less than the reserve free.
        var full = options()
        full.freeSpaceReserve = Int64.max / 2
        do {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.base, options: full, progress: { _, _, _ in })
            Issue.record("rebase ignored the free-space reserve")
        } catch let VPhoneDiskRebaseError.insufficientSpace(path, _, reserve) {
            #expect(path.hasSuffix("/Disk.img"))
            #expect(reserve == Int64.max / 2)
        }
        try expectUnchanged()

        // The target ran and stopped again: its image moved.
        var ran = options()
        ran.beforeSwap = {
            let fd = open(machines.targetImage.path, O_RDWR)
            defer { close(fd) }
            var byte: UInt8 = 0x42
            _ = pwrite(fd, &byte, 1, off_t(600 << 10))
        }
        #expect(throws: VPhoneDiskRebaseError.changedDuringRebase(machine: "target")) {
            try VPhoneDiskRebase.rebase(machines.target, onto: machines.base, options: ran, progress: { _, _, _ in })
        }
        var now = stat()
        try #require(stat(machines.targetImage.path, &now) == 0)
        #expect(now.st_ino == inode.st_ino)
        try expectNoStaging(machines)
    }

    @Test func `the target keeps its own mode and times`() throws {
        let machines = try makeMachines()
        defer { try? FileManager.default.removeItem(at: machines.root) }
        let extent = Extent(0, seed: 81, count: 64 << 10)
        try writeImage(machines.baseImage, [extent])
        try writeImage(machines.targetImage, [extent])
        #expect(chmod(machines.targetImage.path, 0o640) == 0)
        #expect(chmod(machines.baseImage.path, 0o777) == 0)
        let old = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, machines.targetImage.path, old, 0) == 0)
        try rebase(machines)
        #expect(try mode(of: machines.targetImage) == 0o640)
        #expect(try mode(of: machines.baseImage) == 0o777)
        #expect(try modified(of: machines.targetImage) == 1_000_000_000 * 1_000_000_000)
    }

    // MARK: - Ranges and export

    @Test func `the union of data ranges is widened to units and merged`() {
        // 0..<10 and 4000..<4100 widen to 0..<8192. 12289..<12290 widens to
        // the block at 12288, which touches the next one and merges with it;
        // the last ends at the size rather than at its block's end.
        let union = VPhoneDiskRebase.alignedUnion(
            [0 ..< 10, 20000 ..< 20001],
            [4000 ..< 4100, 12289 ..< 12290, 16384 ..< 16390],
            block: 4096,
            size: 20002,
        )
        #expect(union == [0 ..< 8192, 12288 ..< 20002])
    }

    @Test func `staging folders are excluded from export`() {
        let patterns = VPhoneBundleOperations.exportExcludePatterns
        #expect(patterns.contains { fnmatch($0, VPhoneDiskRebase.stagingPrefix + UUID().uuidString, 0) == 0 })
    }
}
