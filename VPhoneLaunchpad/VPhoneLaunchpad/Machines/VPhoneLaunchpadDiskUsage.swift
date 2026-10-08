import Darwin
import Foundation

/// What a machine folder takes on disk.
///
/// `allocated` counts every block its files hold (`st_blocks`), shared or
/// not. `exclusive` counts the blocks no other file shares: APFS's private
/// size (`ATTR_CMNEXT_PRIVATESIZE`), what deleting the folder would free. A
/// machine cloned from a template shares every block it has not written with
/// the template and its other clones, so its exclusive size is a fraction of
/// what is allocated. A Time Machine local snapshot also counts as sharing.
nonisolated struct VPhoneLaunchpadDiskUsage: Hashable, Sendable {
    var allocated: Int64
    /// Nil when the volume does not report private sizes (not APFS).
    var exclusive: Int64?

    /// Walks `folder` without following links. Slow for a big folder of many
    /// files; call it off the main actor.
    static func measure(_ folder: URL) -> Self {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        var usage = Self(allocated: 0, exclusive: 0)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) else {
            return Self(allocated: 0, exclusive: nil)
        }
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true
            else {
                continue
            }
            usage.allocated += Int64(values.totalFileAllocatedSize ?? 0)
            if let exclusive = usage.exclusive {
                usage.exclusive = privateSize(of: file.path).map { exclusive + $0 }
            }
        }
        return usage
    }

    /// The bytes of `path` no other file shares, or nil when the file system
    /// does not say. A link is not followed.
    static func privateSize(of path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        // Extended common attributes are asked for in the fork field.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // u_int32_t length, attribute_set_t returned, off_t private size.
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW)
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(path, &request, bytes.baseAddress, bytes.count, options)
        }
        guard status == 0 else {
            return nil
        }
        return buffer.withUnsafeBytes { bytes -> Int64? in
            let returned = bytes.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else {
                return nil
            }
            let offset = 4 + MemoryLayout<attribute_set_t>.size
            return Int64(bytes.loadUnaligned(fromByteOffset: offset, as: off_t.self))
        }
    }

    /// `17.58 GB`, decimal as the Finder counts.
    static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The inspector's value: `0.61 GB of 17.58 GB`, or the allocated size
    /// alone when the volume gives no private size.
    func summary(locale: Locale = .current) -> String {
        guard let exclusive else {
            return Self.format(allocated, locale: locale)
        }
        return String(localized: "\(Self.format(exclusive, locale: locale)) of \(Self.format(allocated, locale: locale))")
    }
}
