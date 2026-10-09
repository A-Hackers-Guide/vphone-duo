import Darwin
import Foundation

// MARK: - Report

/// What a rebase did, or what a dry run would do, in bytes of the target's
/// logical disk image.
public struct VPhoneDiskRebaseReport: Equatable, Sendable {
    /// The target image's size, unchanged by the rebase.
    public var logicalSize: Int64 = 0
    /// Bytes read from both images: everywhere either one holds data. Where
    /// both are holes they read as zeros and nothing needs comparing.
    public var comparedBytes: Int64 = 0
    /// Bytes where the base holds data identical to the target's at the same
    /// offset. The rebased image keeps the base's blocks there, so they are
    /// stored once for both machines. Counted in whole units of
    /// `VPhoneDiskRebase.blockSize`.
    public var sharedBytes: Int64 = 0
    /// Bytes that differ from the base and were written from the target.
    public var writtenBytes: Int64 = 0
    /// Bytes where the base holds data and the target reads as zeros, a hole
    /// or zero-filled blocks. They become holes in the rebased image.
    public var punchedBytes: Int64 = 0

    public init() {}
}

// MARK: - Rebase

/// Re-shares a stopped machine's disk image with another machine's, offline.
///
/// Two machines restored separately from one IPSW share nothing on disk, yet
/// most of their system volume is byte-identical at the same offset in both
/// images. macOS has no public call to clone a range of one file into
/// another, but a whole file can be cloned: the base image is cloned into a
/// staging file, which already shares every block with the base, and then
/// only the blocks where the target differs are written into it. The result
/// holds exactly the target's bytes and keeps the base's blocks wherever they
/// already matched. It replaces the target's image with one `rename(2)`.
///
/// Only the disk image changes. `SEPStorage`, `nvram.bin`, `config.plist`
/// and every other file are small and belong to the target machine, and stay
/// as they are. The guest reads exactly the bytes it read before, so the
/// identity, the SEP's anti-replay state and the keybag pairing between the
/// disk and `SEPStorage` are what they were: to the guest nothing happened.
///
/// The space comes back only when nothing else holds the old image's blocks:
/// a snapshot of the target, or a clone made from it, keeps them. Afterwards
/// both machines diverge again as either one writes to its disk.
public enum VPhoneDiskRebase {
    /// The hidden staging folder in the target's machine folder: on the
    /// target's volume, so `rename(2)` can put the result in place. A killed
    /// rebase leaves one behind, and it can be deleted; `vm export` skips it.
    public static let stagingPrefix = ".rebase-"

    public enum Phase: Sendable {
        case comparing
        case verifying
    }

    /// Bytes done and the phase's total, reported in order from one thread.
    public typealias Progress = (Phase, Int64, Int64) -> Void

    /// Reads and writes move in pieces of this size, a multiple of
    /// `blockSize`, and every piece starts on a multiple of it.
    static let defaultChunkSize = 8 << 20
    /// Writing stops while the volume has less than this left free, so a
    /// rebase never fills the disk under machines that are running from it.
    static let defaultFreeSpaceReserve: Int64 = 4 << 30

    /// Test seams: chunk size, free-space floor, and calls at the two points
    /// where a concurrent change matters.
    struct Options {
        var chunkSize = VPhoneDiskRebase.defaultChunkSize
        var freeSpaceReserve = VPhoneDiskRebase.defaultFreeSpaceReserve
        /// After the staging file is written, before it is verified.
        var beforeVerify: (URL) throws -> Void = { _ in }
        /// After verification, before the second running check and the swap.
        var beforeSwap: () throws -> Void = {}
    }

    // MARK: Dry run

    /// What `rebase` would share, write and punch, computed by comparing the
    /// two images in place. Nothing is created or changed.
    public static func plan(
        _ target: VPhoneBundle,
        onto base: VPhoneBundle,
        progress: Progress = { _, _, _ in },
    ) throws -> VPhoneDiskRebaseReport {
        try plan(target, onto: base, options: Options(), progress: progress)
    }

    static func plan(
        _ target: VPhoneBundle,
        onto base: VPhoneBundle,
        options: Options,
        progress: Progress,
    ) throws -> VPhoneDiskRebaseReport {
        let (targetImage, baseImage) = try images(of: target, onto: base)
        try VPhoneBundleActivity.requireStopped(target)
        try VPhoneBundleActivity.requireStopped(base)

        let targetFile = try ImageFile(path: targetImage.path, writable: false)
        defer { targetFile.close() }
        let baseFile = try ImageFile(path: baseImage.path, writable: false)
        defer { baseFile.close() }
        let size = targetFile.size
        // Read as the staging file would be after it is cut to the target's
        // size: the base's bytes up to there, zeros past the base's end.
        let walk = try Walk(
            target: targetFile,
            reference: baseFile,
            referenceData: baseFile.dataRanges(upTo: min(size, baseFile.size)),
            size: size,
            chunkSize: options.chunkSize,
        )
        return try walk.compare(apply: nil, progress: progress)
    }

    // MARK: Rebase

    /// Rebases the target's disk image onto the base's. Both machines must be
    /// stopped, and are checked again just before the swap. The target's
    /// bytes are verified, all of them, before its image is replaced.
    @discardableResult
    public static func rebase(
        _ target: VPhoneBundle,
        onto base: VPhoneBundle,
        progress: Progress = { _, _, _ in },
    ) throws -> VPhoneDiskRebaseReport {
        try rebase(target, onto: base, options: Options(), progress: progress)
    }

    @discardableResult
    static func rebase(
        _ target: VPhoneBundle,
        onto base: VPhoneBundle,
        options: Options,
        progress: Progress,
    ) throws -> VPhoneDiskRebaseReport {
        let (targetImage, baseImage) = try images(of: target, onto: base)
        try VPhoneBundleActivity.requireStopped(target)
        try VPhoneBundleActivity.requireStopped(base)
        let original = try FileState(path: targetImage.path)

        let fm = FileManager.default
        let staging = target.url.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stagedImage = staging.appendingPathComponent(target.manifest.diskImage)

        // A clone, never a copy: off APFS, or across volumes, the operation
        // is refused rather than writing the whole image.
        guard clonefile(baseImage.path, stagedImage.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            let code = errno
            if code == ENOTSUP || code == EXDEV {
                throw VPhoneDiskRebaseError.notCloneable(path: baseImage.path)
            }
            throw VPhoneDiskRebaseError.failed(path: baseImage.path, reason: String(cString: strerror(code)))
        }

        let report: VPhoneDiskRebaseReport
        do {
            let targetFile = try ImageFile(path: targetImage.path, writable: false)
            defer { targetFile.close() }
            let stagedFile = try ImageFile(path: stagedImage.path, writable: true)
            defer { stagedFile.close() }
            let size = targetFile.size
            try stagedFile.truncate(to: size)

            let walk = try Walk(
                target: targetFile,
                reference: stagedFile,
                referenceData: stagedFile.dataRanges(upTo: size),
                size: size,
                chunkSize: options.chunkSize,
            )
            report = try walk.compare(
                apply: Apply(file: stagedFile, freeSpaceReserve: options.freeSpaceReserve),
                progress: progress,
            )
            try stagedFile.sync()
            try options.beforeVerify(stagedImage)
            try verify(stagedFile, against: targetFile, chunkSize: options.chunkSize, progress: progress)
            try stagedFile.matchAttributes(of: original)
        }

        // Every descriptor is closed here: the running check below counts
        // any process holding the image, this one too.
        try options.beforeSwap()
        try VPhoneBundleActivity.requireStopped(target)
        try VPhoneBundleActivity.requireStopped(base)
        // A machine that started and stopped again since the comparison
        // passes the check above but has moved the image under it.
        guard try FileState(path: targetImage.path) == original else {
            throw VPhoneDiskRebaseError.changedDuringRebase(machine: target.name)
        }
        guard rename(stagedImage.path, targetImage.path) == 0 else {
            throw VPhoneDiskRebaseError.failed(path: targetImage.path, reason: String(cString: strerror(errno)))
        }
        return report
    }

    // MARK: - Checks

    /// The two disk images, after checking they belong to two machines.
    private static func images(of target: VPhoneBundle, onto base: VPhoneBundle) throws -> (URL, URL) {
        guard target.name != base.name else {
            throw VPhoneDiskRebaseError.sameMachine(name: target.name)
        }
        let targetImage = target.url.appendingPathComponent(target.manifest.diskImage)
        let baseImage = base.url.appendingPathComponent(base.manifest.diskImage)
        for (bundle, image) in [(target, targetImage), (base, baseImage)] {
            guard VPhoneVirtualMachineManifest.fileKind(at: image) == .regularFile else {
                throw VPhoneDiskRebaseError.missingImage(machine: bundle.name, path: image.path)
            }
        }
        // Two names for one folder (a link in the library) would rebase an
        // image onto itself.
        let targetState = try FileState(path: targetImage.path)
        let baseState = try FileState(path: baseImage.path)
        guard targetState.device != baseState.device || targetState.inode != baseState.inode else {
            throw VPhoneDiskRebaseError.sameMachine(name: target.name)
        }
        return (targetImage, baseImage)
    }

    // MARK: - Verify

    /// Compares the staged image with the target's over every byte. Where
    /// both are holes they read as zeros, so only the places where either
    /// holds data are read.
    private static func verify(
        _ staged: ImageFile,
        against target: ImageFile,
        chunkSize: Int,
        progress: Progress,
    ) throws {
        guard staged.currentSize() == target.size else {
            throw VPhoneDiskRebaseError.verificationFailed(offset: min(staged.currentSize(), target.size))
        }
        let size = target.size
        let spans = try alignedUnion(
            target.dataRanges(upTo: size),
            staged.dataRanges(upTo: size),
            block: Int64(blockSize),
            size: size,
        )
        let total = spans.reduce(Int64(0)) { $0 + Int64($1.count) }
        var done: Int64 = 0
        let left = AlignedBuffer(size: chunkSize)
        let right = AlignedBuffer(size: chunkSize)
        progress(.verifying, 0, total)
        for span in spans {
            try forEachChunk(of: span, chunkSize: chunkSize) { offset, length in
                try target.read(into: left, length: length, at: offset)
                try staged.read(into: right, length: length, at: offset)
                if memcmp(left.pointer, right.pointer, length) != 0 {
                    var first = 0
                    while first < length, left.bytes[first] == right.bytes[first] {
                        first += 1
                    }
                    throw VPhoneDiskRebaseError.verificationFailed(offset: offset + Int64(first))
                }
                done += Int64(length)
                progress(.verifying, done, total)
            }
        }
    }

    // MARK: - Walk

    /// The unit of comparison: the VM page, 16 KiB on Apple silicon, and
    /// never less than the 4 KiB APFS block. APFS allocates 4 KiB blocks, but
    /// a write into a cloned file replaces every page it touches: measured on
    /// macOS 27, one 4 KiB `pwrite` (with `F_NOCACHE`) gives the clone four
    /// new blocks, and 16 KiB written across a page boundary eight. Comparing
    /// smaller units would count blocks as shared that the write next to them
    /// takes away. A page is also a whole number of blocks, as `F_PUNCHHOLE`
    /// needs.
    static let blockSize = max(4096, Int(getpagesize()))

    /// Where a staging file is written, and how much free space to keep.
    private struct Apply {
        let file: ImageFile
        let freeSpaceReserve: Int64
    }

    /// One pass over the target and a reference that reads as the staging
    /// file: the staging file itself, or for a dry run the base image cut to
    /// the target's size.
    private struct Walk {
        let target: ImageFile
        let reference: ImageFile
        /// The reference's data ranges, sorted, within the target's size.
        let referenceData: [Range<Int64>]
        let size: Int64
        let chunkSize: Int

        /// Compares every block where either side holds data. With `apply`,
        /// a block that differs is written from the target, or punched when
        /// the target reads as zeros there; without it they are only counted.
        func compare(apply: Apply?, progress: Progress) throws -> VPhoneDiskRebaseReport {
            var report = VPhoneDiskRebaseReport()
            report.logicalSize = size
            let block = VPhoneDiskRebase.blockSize
            let spans = try alignedUnion(target.dataRanges(upTo: size), referenceData, block: Int64(block), size: size)
            let total = spans.reduce(Int64(0)) { $0 + Int64($1.count) }
            let ours = AlignedBuffer(size: chunkSize)
            let theirs = AlignedBuffer(size: chunkSize)
            let zeros = AlignedBuffer(size: block)
            var cursor = 0 // into referenceData; blocks are visited in order
            var done: Int64 = 0
            progress(.comparing, 0, total)

            for span in spans {
                try forEachChunk(of: span, chunkSize: chunkSize) { offset, length in
                    try target.read(into: ours, length: length, at: offset)
                    try reference.read(into: theirs, length: length, at: offset)
                    // Runs of blocks that need the same change, as offsets
                    // within this chunk, done in one call each.
                    var pending: (punch: Bool, start: Int, end: Int)?
                    var spaceChecked = false
                    func flush() throws {
                        guard let run = pending else { return }
                        pending = nil
                        guard let apply else { return }
                        if run.punch {
                            try apply.file.punchHole(at: offset + Int64(run.start), length: run.end - run.start)
                            return
                        }
                        // Once per chunk that writes, for the whole chunk.
                        if !spaceChecked {
                            try apply.file.requireFreeSpace(Int64(length), reserve: apply.freeSpaceReserve)
                            spaceChecked = true
                        }
                        try apply.file.write(from: ours, range: run.start ..< run.end, at: offset)
                    }

                    var start = 0
                    while start < length {
                        let count = min(block, length - start)
                        let at = offset + Int64(start)
                        while cursor < referenceData.count, referenceData[cursor].upperBound <= at {
                            cursor += 1
                        }
                        let referenceHasData = cursor < referenceData.count
                            && referenceData[cursor].lowerBound < at + Int64(count)
                        if memcmp(ours.pointer + start, theirs.pointer + start, count) == 0 {
                            try flush()
                            if referenceHasData {
                                report.sharedBytes += Int64(count)
                            }
                        } else {
                            // Zeros where the reference has other bytes become
                            // a hole, so the result stays as sparse as the
                            // target. A short block at the end of the file is
                            // written instead: a hole is punched in whole
                            // blocks only.
                            let punch = count == block && memcmp(ours.pointer + start, zeros.pointer, count) == 0
                            if punch {
                                report.punchedBytes += Int64(count)
                            } else {
                                report.writtenBytes += Int64(count)
                            }
                            if let run = pending, run.punch == punch, run.end == start {
                                pending = (punch, run.start, start + count)
                            } else {
                                try flush()
                                pending = (punch, start, start + count)
                            }
                        }
                        start += count
                    }
                    try flush()
                    done += Int64(length)
                    report.comparedBytes += Int64(length)
                    progress(.comparing, done, total)
                }
            }
            return report
        }
    }

    /// Calls `body` for each piece of `span`, split at multiples of
    /// `chunkSize` so pieces of different spans never overlap a boundary.
    private static func forEachChunk(
        of span: Range<Int64>,
        chunkSize: Int,
        _ body: (Int64, Int) throws -> Void,
    ) throws {
        precondition(chunkSize > 0 && chunkSize % blockSize == 0)
        let chunk = Int64(chunkSize)
        var offset = span.lowerBound
        while offset < span.upperBound {
            let end = min(span.upperBound, (offset / chunk + 1) * chunk)
            try body(offset, Int(end - offset))
            offset = end
        }
    }

    /// The union of two sorted range lists, widened to whole blocks (the last
    /// one ends at `size`) and merged.
    static func alignedUnion(_ a: [Range<Int64>], _ b: [Range<Int64>], block: Int64, size: Int64) -> [Range<Int64>] {
        let widened = (a + b)
            .map { range -> Range<Int64> in
                let lower = range.lowerBound / block * block
                let upper = min(size, (range.upperBound + block - 1) / block * block)
                return lower ..< upper
            }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for range in widened {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Files

/// Identity and the attributes a rebase keeps, of one disk image. The access
/// time is kept but not compared: reading the image moves it.
private struct FileState: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let accessed: timespec
    let modified: timespec
    let changed: timespec
    let owner: uid_t
    let group: gid_t
    let mode: mode_t

    init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw VPhoneDiskRebaseError.failed(path: path, reason: String(cString: strerror(errno)))
        }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        accessed = info.st_atimespec
        modified = info.st_mtimespec
        changed = info.st_ctimespec
        owner = info.st_uid
        group = info.st_gid
        mode = info.st_mode
    }

    static func == (lhs: FileState, rhs: FileState) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
            && lhs.owner == rhs.owner && lhs.group == rhs.group && lhs.mode == rhs.mode
    }
}

/// A page-aligned buffer, which uncached reads and writes prefer.
private final class AlignedBuffer {
    let pointer: UnsafeMutableRawPointer
    let size: Int

    init(size: Int) {
        self.size = size
        pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: Int(getpagesize()))
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    }

    var bytes: UnsafeMutablePointer<UInt8> {
        pointer.assumingMemoryBound(to: UInt8.self)
    }

    deinit {
        pointer.deallocate()
    }
}

/// An open disk image. Reads and writes bypass the buffer cache: a rebase
/// passes over tens of gigabytes once, and caching them would only push out
/// what the running machines use.
private final class ImageFile {
    let path: String
    let descriptor: Int32
    let size: Int64
    private var isOpen = true

    init(path: String, writable: Bool) throws {
        self.path = path
        descriptor = open(path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw VPhoneDiskRebaseError.failed(path: path, reason: String(cString: strerror(errno)))
        }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw VPhoneDiskRebaseError.failed(path: path, reason: reason)
        }
        size = Int64(info.st_size)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Darwin.close(descriptor)
    }

    func currentSize() -> Int64 {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? Int64(info.st_size) : -1
    }

    private func failure(_ code: Int32 = errno) -> VPhoneDiskRebaseError {
        .failed(path: path, reason: String(cString: strerror(code)))
    }

    /// The data ranges below `limit`, sorted, by `SEEK_DATA` and `SEEK_HOLE`.
    /// A file system that cannot tell holes apart is all data.
    func dataRanges(upTo limit: Int64) throws -> [Range<Int64>] {
        var ranges: [Range<Int64>] = []
        var offset: Int64 = 0
        while offset < limit {
            let data = lseek(descriptor, off_t(offset), SEEK_DATA)
            if data < 0 {
                if errno == ENXIO { break } // no data from here to the end
                if errno == EINVAL { return limit > 0 ? [0 ..< limit] : [] }
                throw failure()
            }
            guard Int64(data) < limit else { break }
            let hole = lseek(descriptor, data, SEEK_HOLE)
            guard hole >= 0 else { throw failure() }
            let end = min(limit, Int64(hole))
            ranges.append(Int64(data) ..< end)
            offset = end
        }
        return ranges
    }

    /// Fills `length` bytes from `offset`; past the end of the file they
    /// read as zeros, as they do in a hole.
    func read(into buffer: AlignedBuffer, length: Int, at offset: Int64) throws {
        var filled = 0
        while filled < length {
            let got = pread(descriptor, buffer.pointer + filled, length - filled, off_t(offset + Int64(filled)))
            if got < 0 {
                if errno == EINTR { continue }
                throw failure()
            }
            if got == 0 {
                (buffer.pointer + filled).initializeMemory(as: UInt8.self, repeating: 0, count: length - filled)
                return
            }
            filled += got
        }
    }

    func write(from buffer: AlignedBuffer, range: Range<Int>, at chunkOffset: Int64) throws {
        var written = 0
        while written < range.count {
            let start = range.lowerBound + written
            let put = pwrite(descriptor, buffer.pointer + start, range.count - written, off_t(chunkOffset + Int64(start)))
            if put < 0 {
                if errno == EINTR { continue }
                throw failure()
            }
            written += put
        }
    }

    func punchHole(at offset: Int64, length: Int) throws {
        var hole = fpunchhole_t()
        hole.fp_offset = off_t(offset)
        hole.fp_length = off_t(length)
        guard fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else { throw failure() }
    }

    func truncate(to size: Int64) throws {
        guard ftruncate(descriptor, off_t(size)) == 0 else { throw failure() }
    }

    /// Flushes to the disk itself, not just to the drive's cache.
    func sync() throws {
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw failure()
        }
    }

    /// Refuses a write that would leave less than `reserve` free.
    func requireFreeSpace(_ bytes: Int64, reserve: Int64) throws {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw failure() }
        let available = Int64(info.f_bavail) * Int64(info.f_bsize)
        guard available - bytes >= reserve else {
            throw VPhoneDiskRebaseError.insufficientSpace(path: path, available: available, reserve: reserve)
        }
    }

    /// The clone has the base's owner, mode and times; the result keeps the
    /// target's, as the guest's disk has not changed.
    func matchAttributes(of original: FileState) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        if info.st_uid != original.owner || info.st_gid != original.group {
            guard fchown(descriptor, original.owner, original.group) == 0 else { throw failure() }
        }
        guard fchmod(descriptor, original.mode & 0o7777) == 0 else { throw failure() }
        let times = [original.accessed, original.modified]
        guard futimens(descriptor, times) == 0 else { throw failure() }
    }
}

// MARK: - Error

public enum VPhoneDiskRebaseError: Error, Equatable {
    case sameMachine(name: String)
    case missingImage(machine: String, path: String)
    case notCloneable(path: String)
    case insufficientSpace(path: String, available: Int64, reserve: Int64)
    /// The staged image differs from the target's at this offset.
    case verificationFailed(offset: Int64)
    case changedDuringRebase(machine: String)
    case failed(path: String, reason: String)
}

extension VPhoneDiskRebaseError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .sameMachine(name):
            "Cannot rebase VM '\(name)' onto itself. Name a different VM as the base."
        case let .missingImage(machine, path):
            "VM '\(machine)' has no disk image at \(path)."
        case let .notCloneable(path):
            "Cannot clone \(path): rebasing needs both VMs on one APFS volume, and a full copy is not made."
        case let .insufficientSpace(path, available, reserve):
            "Not enough free space on the volume of \(path): \(available / 1_000_000) MB free, and "
                + "\(reserve / 1_000_000) MB must stay free. Nothing was changed. Free some space, then try again."
        case let .verificationFailed(offset):
            "The rebased disk image differs from the original at byte \(offset). Nothing was changed."
        case let .changedDuringRebase(machine):
            "VM '\(machine)' changed its disk image during the rebase. Nothing was changed. Stop it, then try again."
        case let .failed(path, reason):
            "Rebase failed at \(path): \(reason). Nothing was changed."
        }
    }

    public var errorDescription: String? {
        description
    }
}
