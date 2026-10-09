import Darwin
import Foundation

/// What a machine or template folder takes on disk.
///
/// `allocated` counts every block its files hold (`st_blocks`), shared or
/// not. `exclusive` counts the blocks no other measured folder holds: what
/// deleting the folder frees once nothing else keeps them. A machine cloned
/// from a template shares every block it has not written with the template
/// and its other clones, so its exclusive size is a fraction of what is
/// allocated.
///
/// It is measured by comparing physical extents (`VPhoneLaunchpadDiskExtents`),
/// not with APFS's private size (`ATTR_CMNEXT_PRIVATESIZE`): a Time Machine
/// local snapshot shares every block that existed when it was taken, so
/// after each hourly snapshot the private size of every machine is 0 until
/// it writes again. The blocks a snapshot holds are still freed when it
/// expires, and the comparison counts them as the folder's own.
nonisolated struct VPhoneLaunchpadDiskUsage: Hashable, Sendable {
    var allocated: Int64
    /// Nil when it could not be measured (the volume maps no extents, or the
    /// measurement ran out of time).
    var exclusive: Int64?

    /// `17.58 GB`, decimal as the Finder counts.
    static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The inspector's value: `0.61 GB of 17.58 GB`, or the allocated size
    /// alone when the exclusive size is unknown.
    func summary(locale: Locale = .current) -> String {
        guard let exclusive else {
            return Self.format(allocated, locale: locale)
        }
        return String(localized: "\(Self.format(exclusive, locale: locale)) of \(Self.format(allocated, locale: locale))")
    }
}

// MARK: - Measuring

/// Measures machine and template folders against each other, keeping each
/// file's extents between passes.
///
/// A file is mapped again only when its size, modification or change time
/// is different, so a stopped machine's 20 GB image is opened once after it
/// changes, not on every pass. Mapping opens the file: `lsof` then lists
/// Launchpad for it, which `vm stop` and `cfw install` read as the machine
/// running. Folders Launchpad is working on are therefore never opened
/// (`Folder.mayOpen`), and Launchpad leaves its own process out when it asks
/// `lsof` which machines run.
actor VPhoneLaunchpadDiskMeter {
    nonisolated struct Folder: Hashable, Sendable {
        var path: String
        /// False while something works on the folder: its files' last
        /// extents are used, and a file never mapped leaves it unknown.
        var mayOpen = true
    }

    private nonisolated struct FileKey: Hashable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modified: Int
        var modifiedNanoseconds: Int
        var changed: Int
        var changedNanoseconds: Int
    }

    private nonisolated struct Mapped {
        var key: FileKey
        /// Nil for a file the volume does not map (a compressed file): its
        /// allocated size counts as its folder's own.
        var extents: VPhoneLaunchpadDiskExtents?
    }

    private var cache: [String: Mapped] = [:]
    private let budget: Duration

    /// `budget` bounds the mapping of one pass. Files left over are mapped
    /// on a later pass, and their folders are unknown meanwhile.
    init(budget: Duration = .seconds(15)) {
        self.budget = budget
    }

    /// Each folder's usage, by `Folder.path`. Files are not followed through
    /// links.
    func measure(_ folders: [Folder]) -> [String: VPhoneLaunchpadDiskUsage] {
        let deadline = ContinuousClock.now + budget
        var seen: Set<String> = []
        var owners: [[VPhoneLaunchpadDiskExtents]] = []
        var usages: [VPhoneLaunchpadDiskUsage] = []
        var unmappedBytes: [Int64] = []
        for folder in folders {
            var usage = VPhoneLaunchpadDiskUsage(allocated: 0, exclusive: 0)
            var extents: [VPhoneLaunchpadDiskExtents] = []
            var unmapped: Int64 = 0
            for file in Self.files(in: folder.path) {
                var status = stat()
                guard lstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    continue
                }
                seen.insert(file)
                let allocated = Int64(status.st_blocks) * 512
                usage.allocated += allocated
                guard allocated > 0 else {
                    continue
                }
                let key = FileKey(
                    device: Int64(status.st_dev), inode: status.st_ino, size: status.st_size,
                    modified: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
                    changed: status.st_ctimespec.tv_sec, changedNanoseconds: status.st_ctimespec.tv_nsec,
                )
                var mapped = cache[file].flatMap { $0.key == key ? $0 : nil }
                if mapped == nil, folder.mayOpen, ContinuousClock.now < deadline {
                    switch VPhoneLaunchpadDiskExtents.map(file, deadline: deadline) {
                    case let .success(result):
                        mapped = Mapped(key: key, extents: result)
                    case .failure(.unsupported):
                        mapped = Mapped(key: key, extents: nil)
                    case .failure(.tooLarge):
                        break
                    }
                    if let mapped {
                        cache[file] = mapped
                    }
                }
                // A folder that may not be opened keeps what was last
                // mapped, which is close: its blocks rarely move.
                guard let found = mapped ?? (folder.mayOpen ? nil : cache[file]) else {
                    usage.exclusive = nil
                    continue
                }
                if let result = found.extents {
                    extents.append(result)
                } else {
                    unmapped += allocated
                }
            }
            owners.append(extents)
            usages.append(usage)
            unmappedBytes.append(unmapped)
        }
        cache = cache.filter { seen.contains($0.key) }
        let exclusive = VPhoneLaunchpadDiskExtents.exclusiveBytes(of: owners)
        var result: [String: VPhoneLaunchpadDiskUsage] = [:]
        for (index, folder) in folders.enumerated() {
            var usage = usages[index]
            // Rounding to whole blocks can only add to what st_blocks says.
            usage.exclusive = usage.exclusive.map { _ in min(usage.allocated, exclusive[index] + unmappedBytes[index]) }
            result[folder.path] = usage
        }
        return result
    }

    /// Every entry under `path`, not through links. The walk does not
    /// descend into a linked directory, and `lstat` rejects a linked file.
    private nonisolated static func files(in path: String) -> [String] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            return []
        }
        var files: [String] = []
        for case let file as URL in walker {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(file.path)
            }
        }
        return files
    }

    /// The template folders of a library: `.templates/<12 hex>`. Builds
    /// (`.building-…`) are left out; they are written while they exist.
    nonisolated static func templateFolders(in libraryRoot: String) -> [String] {
        let templates = URL(fileURLWithPath: libraryRoot, isDirectory: true).appendingPathComponent(".templates", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: templates.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.wholeMatch(of: /[0-9a-f]{12}/) != nil else {
                return nil
            }
            let folder = templates.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(folder.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                return nil
            }
            return folder.path
        }
    }
}
