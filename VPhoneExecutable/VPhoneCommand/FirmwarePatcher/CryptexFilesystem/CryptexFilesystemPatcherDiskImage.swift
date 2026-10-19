// CryptexFilesystemPatcherDiskImage.swift — Disk image attach, convert and copy helpers.
//
// Split out of CryptexFilesystemPatcher.swift. The diskutil layer: attaching and
// detaching images, converting between RAW and UDRW, resizing, unmounting, and the
// copyfile-based volume copy used to merge a cryptex into the target volume.

import Foundation

extension CryptexFilesystemPatcher {
    func copyImageContents(source: URL, destination: URL) throws {
        // Copy everything from source volume root into destination volume root.
        let sourceRoot = source.appendingPathComponent("", isDirectory: true)
        let sourcePath = sourceRoot.path
        let destinationRoot = destination.appendingPathComponent("", isDirectory: true)

        // We delete the files first as we want to replace symlinks with actual files.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: keys) else {
            throw FirmwareManifest.ManifestError.fileNotFound(
                "\(sourceRoot.path). Check that the image is still mounted, then try again.",
            )
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.path.hasPrefix(sourcePath) else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            var suffix = String(fileURL.path.dropFirst(sourcePath.count))
            if suffix.hasPrefix("/") {
                suffix.removeFirst()
            }

            let destinationPath = destinationRoot.appendingPathComponent(suffix)
            guard let ok = try? destinationPath.checkResourceIsReachable(), ok else {
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(
                    fileURL.path,
                    destinationPath.path,
                    nil,
                    copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA),
                )
                if result < 0 {
                    print("Unable to copy \(destinationPath.path). Check permissions and free space, then try again.")
                }
                continue
            }

            let vals = try destinationPath.resourceValues(forKeys: Set(keys))
            if values.isDirectory != vals.isDirectory ||
                values.isRegularFile != vals.isRegularFile ||
                values.isSymbolicLink != vals.isSymbolicLink
            {
                try FileManager.default.removeItem(at: destinationPath)
                // try FileManager.default.copyItem(at: fileURL, to: destinationPath)
                let result = copyfile(
                    fileURL.path,
                    destinationPath.path,
                    nil,
                    copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_DATA),
                )
                if result < 0 {
                    print("Unable to copy \(destinationPath.path). Check permissions and free space, then try again.")
                }
            }
        }
    }

    func convertToRawImage(input: URL, output: URL) throws {
        let arguments = if #available(macOS 26, *) {
            ["image", "create", "from", "-format", "RAW", input.path, output.path]
        } else {
            ["image", "create", "from", "-format", "RAW", "-source", input.path, output.path]
        }
        _ = try runProcess("/usr/sbin/diskutil", arguments)

        // Resize to max. Asking diskutil how big it may get returns a plist, and
        // reading one value out of it used to be `/bin/sh -c "… | plutil -extract
        // max raw -o - -"`: a shell and a second tool to parse what this process
        // can read directly — and a pipeline whose stdout is also where diskutil's
        // own warnings land, so a noisy run produced a "size" that was a sentence.
        let sizes = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "-plist", output.path,
        ])
        let maxsize = try Self.maxResizeSize(fromDiskutilPlist: sizes)
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "-size", maxsize, output.path,
        ])
    }

    /// The `max` value out of `diskutil image resize --plist`, as the string
    /// `--size` wants back.
    ///
    /// `runProcess` merges stderr into stdout, so the plist may arrive with a
    /// line of diskutil's own in front of it; the parse starts at the XML
    /// declaration rather than assuming the first byte is one.
    static func maxResizeSize(fromDiskutilPlist output: String) throws -> String {
        let body = output.range(of: "<?xml").map { String(output[$0.lowerBound...]) } ?? output
        guard let data = body.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil,
              ) as? [String: Any]
        else {
            throw ProcessError.failed(0, "diskutil did not return a plist:\n\(output)")
        }
        switch root["max"] {
        case let number as NSNumber: return number.stringValue
        case let string as String: return string
        default:
            throw ProcessError.failed(0, "no 'max' size in diskutil's plist:\n\(output)")
        }
    }

    func convertToUDRWImage(input: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        // diskutil calls the former UDRW read-write format RAW.
        let arguments = if #available(macOS 26, *) {
            ["image", "create", "from", "-format", "RAW", input.path, output.path]
        } else {
            ["image", "create", "from", "-format", "RAW", "-source", input.path, output.path]
        }
        _ = try runProcess("/usr/sbin/diskutil", arguments)
    }

    func shrinkImage(dmg: URL) throws {
        _ = try runProcess("/usr/sbin/diskutil", [
            "image",
            "resize",
            "-size", "min",
            dmg.path,
        ])
    }

    /// Add `bytes` to the image's size, for a tool that needs room on a
    /// volume `shrinkImage` left at its minimum.
    func growImage(dmg: URL, by bytes: Int) throws {
        let size = try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int ?? 0
        _ = try runProcess("/usr/sbin/diskutil", [
            "image", "resize", "-size", String(size + bytes), dmg.path,
        ])
    }

    /// Attach an image without mounting anything, and return its APFS volume's
    /// device node.
    func attachImageWithoutMounting(path: URL) throws -> String {
        let output: String
        do {
            output = try runProcess("/usr/sbin/diskutil", ["image", "attach", "-noMount", path.path])
        } catch let ProcessError.failed(status, output) {
            detachReportedImage(in: output)
            throw ProcessError.failed(status, output)
        }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("/dev/disk"), fields[1] == "Apple_APFS_Volume" else {
                continue
            }
            let device = String(fields[0])
            attachedDevices.insert(device)
            return device
        }
        detachReportedImage(in: output)
        throw FirmwareManifest.ManifestError.missingKey("APFS volume in \(path.lastPathComponent)")
    }

    /// Delete the event log the host's fseventsd keeps on a writable mount.
    ///
    /// Apple's system volumes have no `.fseventsd`, and the restore writes
    /// `.fseventsd/.ramdisk-boot-done` into the one it restores. A log the host
    /// left in the image shows up in the mtree, the restored volume then no
    /// longer matches it, and the restore fails at `seal_system_volume`
    /// ("mtree: cannot generate the XML dictionary"). Deleting the directory on
    /// the mounted volume also stops fseventsd writing it again for this mount.
    func removeHostEventLog(mount: String) throws {
        let log = URL(fileURLWithPath: mount).appending(path: ".fseventsd")
        if FileManager.default.fileExists(atPath: log.path) {
            try FileManager.default.removeItem(at: log)
        }
    }

    /// attachImage returns the device and mount point
    func attachImage(path: URL, readonly: Bool = false, forceRW: Bool = false) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = if readonly {
            [
                "image", "attach",
                "-readOnly",
                path.path,
            ]
        } else {
            [
                "image", "attach",
                path.path,
            ]
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            detachReportedImage(in: output)
            throw ProcessError.failed(process.terminationStatus, output)
        }

        let output = String(decoding: data, as: UTF8.self)
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[0].hasPrefix("/dev/disk"), fields[2].hasPrefix("/") else {
                continue
            }
            let device = fields[0]
            let mountPoint = fields[2]

            attachedDevices.insert(device)
            if forceRW {
                do {
                    _ = try runProcess("/sbin/mount", ["-u", "-w", device, mountPoint])
                } catch {
                    try? detachImage(deviceNode: device)
                    throw error
                }
            }
            return (device, mountPoint)
        }
        detachReportedImage(in: String(data: data, encoding: .utf8) ?? "")
        throw FirmwareManifest.ManifestError.missingKey("dev-entry or mount-point")
    }

    private func detachReportedImage(in output: String) {
        guard let range = output.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) else {
            return
        }
        let device = String(output[range])
        attachedDevices.insert(device)
        try? detachImage(deviceNode: device)
    }

    func detachImage(deviceNode: String) throws {
        do {
            _ = try runProcess("/usr/sbin/diskutil", ["eject", deviceNode])
        } catch {
            _ = try runProcess("/usr/sbin/diskutil", ["unmountDisk", "force", deviceNode])
            _ = try runProcess("/usr/sbin/diskutil", ["eject", deviceNode])
        }
        attachedDevices.remove(deviceNode)
    }
}
