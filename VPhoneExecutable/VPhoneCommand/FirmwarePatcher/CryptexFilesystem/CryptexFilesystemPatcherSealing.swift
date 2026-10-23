// CryptexFilesystemPatcherSealing.swift — Trust cache, mtree and SystemVolume seal generation.
//
// Split out of CryptexFilesystemPatcher.swift. Everything that turns the merged image into a
// sealed system volume: the static trust cache, the mtree, the digest database and root hash
// produced by apfs_sealvolume, and the Ap,SystemVolumeCanonicalMetadata container.

import Foundation
import Img4tool

extension CryptexFilesystemPatcher {
    /// `ipsw img4 im4p create --type T --version V` three times over. Img4tool is
    /// already a dependency of this module and builds the same DER: the IM4P
    /// SEQUENCE is the string "IM4P", the four-character type, the description
    /// — which is what ipsw's `--version` set — and the payload OCTET STRING.
    /// Dropping the subprocess takes the last Homebrew program out of the
    /// firmware pipeline.
    private func wrap(_ payload: URL, fourcc: String, description: String, named: String) throws -> URL {
        let im4pPath = try createTmpDir().appending(path: named)
        // Mapped: the mtree .aar this wraps is the whole system volume's
        // metadata and runs to hundreds of megabytes.
        let im4p = try IM4P(
            fourcc: fourcc,
            description: description,
            payload: Data(contentsOf: payload, options: .mappedIfSafe),
        )
        try im4p.data.write(to: im4pPath)
        return im4pPath
    }

    func wrapRootHash(_ rootHashPath: URL) throws -> URL {
        try wrap(rootHashPath, fourcc: "isys", description: "0", named: "metadata.root_hash")
    }

    func wrapTrustcache(_ trustcache: URL) throws -> URL {
        try wrap(trustcache, fourcc: "trst", description: "1", named: "new.filesystem")
    }

    func compressCanonicalMetadata(mtree: URL, digestDb: URL) throws -> URL {
        let tmpDir = try createTmpDir()
        let targetMtree = tmpDir.appending(path: mtree.lastPathComponent)
        try FileManager.default.copyItem(at: mtree, to: targetMtree)
        let targetDigestDb = tmpDir.appending(path: digestDb.lastPathComponent)
        try FileManager.default.copyItem(at: digestDb, to: targetDigestDb)

        let archivePath = tmpDir.appending(path: "payload.aar")
        _ = try runProcess("/usr/bin/aa", [
            "archive",
            "-d", tmpDir.path,
            "-o", archivePath.path,
        ])

        return try wrap(archivePath, fourcc: "msys", description: "0", named: "metadata.mtree")
    }

    private func identifyApfsSealvolume() throws -> URL {
        let iosVersion = try getProductVersion()
        // The optional filesystem merge reads a seal tool staged inside the VM.
        let sealDir = ProcessInfo.processInfo.environment["VPHONE_SEAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? restoreDir.appendingPathComponent(".tools")
        let path = sealDir.appendingPathComponent("apfs_sealvolume_\(iosVersion)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw FirmwareManifest.ManifestError.fileNotFound(path.path)
        }
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw ProcessError.notExecutable(path.path)
        }
        return path
    }

    func createDigestAndHash(filesystem: URL, mtree: URL, remap: Bool) throws -> (URL, URL) {
        // Not mounted: apfs_sealvolume needs only the device, and a mount would
        // change the volume after the mtree described it, so the root hash here
        // would differ from the one the restore computes from that mtree.
        let device = try attachImageWithoutMounting(path: filesystem)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let digestDbPath = tmpDir.appending(path: "digest.db")
        let rootHashPath = tmpDir.appending(path: "root_hash")
        let mtreeRemapPath = tmpDir.appending(path: "mtree_remap.xml")
        let sealLogPath = tmpDir.appending(path: "seal.log")

        // The modification time the restore will derive from the mtree.
        let modificationTime = try parseRootTime(mtree: mtree)
        let remapContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(remap ? """
            <key>MODIFICATION</key>
            <integer>\(modificationTime)</integer>
        """ : "")
        </dict>
        </plist>
        """
        print("Modification time: \(remap ? modificationTime : "none")")
        FileManager.default.createFile(atPath: mtreeRemapPath.path, contents: remapContent.data(using: .utf8))

        let sealvolume = try identifyApfsSealvolume()
        FileManager.default.createFile(atPath: sealLogPath.path, contents: nil)
        do {
            _ = try runProcess(sealvolume.path, [
                "-R", mtreeRemapPath.path,
                "-U", digestDbPath.path, // Save digest records
                "-M", rootHashPath.path, // Save root hash
                device,
            ], output: sealLogPath)
        } catch {
            // apfs_sealvolume says why it rejects a volume only in its log
            // (exit 65 = EX_DATAERR), which goes with the temporary directory.
            let log = (try? String(contentsOf: sealLogPath, encoding: .utf8)) ?? ""
            print("apfs_sealvolume log (last 60 lines):")
            print(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n"))
            throw error
        }
        return (digestDbPath, rootHashPath)
    }

    /// The root directory's modification time in the mtree, in nanoseconds.
    ///
    /// The restore seals the volume with the time its own `mtree -m` derives,
    /// which is the root entry's (`.`), not the newest entry's. Any other value
    /// gives this side a root hash the restore rejects ("Invalid root hash").
    func parseRootTime(mtree: URL) throws -> String {
        guard let mtreeData = FileManager.default.contents(atPath: mtree.path),
              let text = String(data: mtreeData, encoding: .utf8)
        else {
            throw FirmwareManifest.ManifestError.fileNotFound(mtree.path)
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        // The first section, "# .", describes the root; its entry is named ".".
        guard let sectionIndex = lines.firstIndex(of: "# ."),
              let entryIndex = lines[(sectionIndex + 1)...].firstIndex(where: { $0.hasPrefix(". ") })
        else {
            throw FirmwareManifest.ManifestError.fileNotFound("the root entry in \(mtree.path)")
        }
        // An entry continues on the next line after a trailing backslash.
        var entry = ""
        for line in lines[entryIndex...] {
            entry += line
            guard line.hasSuffix("\\") else { break }
        }
        guard let match = entry.range(of: #"time=([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression) else {
            throw FirmwareManifest.ManifestError.fileNotFound("the root modification time in \(mtree.path)")
        }
        return String(entry[match])
            .replacingOccurrences(of: "time=", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    func createMtree(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let tmpDir = try createTmpDir()
        let mtreeFile = tmpDir.appending(path: "mtree.txt")
        FileManager.default.createFile(atPath: mtreeFile.path, contents: nil)
        _ = try runProcess("/usr/sbin/mtree", [
            "-c",
            "-p", mount,
        ], output: mtreeFile)
        return mtreeFile
    }

    func removeSpecificSystemFiles(filesystem: URL) throws -> Bool {
        let (device, mount) = try attachImage(path: filesystem, forceRW: true)
        defer { try? detachImage(deviceNode: device) }

        let removedPaths = [
            "/private/var/MobileAsset/PreinstalledAssets",
            "/private/var/MobileAsset/PreinstalledAssetsV2",
            "/private/var/staged_system_apps",
        ]
        try removeHostEventLog(mount: mount)
        var didEdit = false
        for path in removedPaths {
            if FileManager.default.fileExists(atPath: mount.appending(path)) {
                try FileManager.default.removeItem(atPath: mount.appending(path))
                didEdit = true
            }
        }
        return didEdit
    }

    func createTrustcache(filesystem: URL) throws -> URL {
        let (device, mount) = try attachImage(path: filesystem, readonly: true)
        defer { try? detachImage(deviceNode: device) }

        let oldTrustcache = try componentPath("StaticTrustCache")
        let oldTrustcachePath = restoreDir.appending(path: oldTrustcache)
        let newTrustcachePath = restoreDir.appending(path: "Firmware/new.trustcache")
        let tmpDir = try createTmpDir()

        let tcContainer = tmpDir.appending(path: "new.trustcache")
        _ = try runProcess("/System/Library/SecurityResearch/usr/bin/cryptexctl", [
            "generate-trust-cache", "--type", "static",
            "--base-trust-cache", oldTrustcachePath.path,
            "--output-file", tcContainer.path,
            mount,
        ])

        if FileManager.default.fileExists(atPath: newTrustcachePath.path) {
            try FileManager.default.removeItem(at: newTrustcachePath)
        }
        try FileManager.default.moveItem(at: tcContainer, to: newTrustcachePath)

        return newTrustcachePath
    }
}
