import Foundation

// MARK: - VPhoneLaunchLayout

public struct VPhoneLaunchLayout: Sendable {
    public let resources: VPhoneResources

    public init(resources: VPhoneResources) {
        self.resources = resources
    }

    public init(projectRoot: URL) {
        self.init(resources: VPhoneResources(base: projectRoot))
    }

    public var vphoned: URL {
        resources.vphoned
    }

    /// Copy the built vphoned into the bundle if present and different.
    @discardableResult
    public func stageVphoned(into bundle: VPhoneBundle) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vphoned.path) else {
            throw VPhoneGuestBinaries.Error.missing("vphoned.signed", [vphoned])
        }
        let dst = bundle.url.appendingPathComponent(".vphoned.signed")
        if fm.fileExists(atPath: dst.path),
           let a = try? Data(contentsOf: vphoned, options: .mappedIfSafe),
           let b = try? Data(contentsOf: dst, options: .mappedIfSafe), a == b
        {
            return false
        }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: vphoned, to: dst)
        try VPhoneHostFilePermissions.makeAccessible(at: dst)
        return true
    }
}

// MARK: - VPhoneLsof

public enum VPhoneLsof {
    public static func parsePIDs(_ output: String) -> [Int32] {
        var seen = Set<Int32>()
        var pids: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(trimmed), !seen.contains(pid) else { continue }
            seen.insert(pid)
            pids.append(pid)
        }
        return pids.sorted()
    }
}

// MARK: - VPhoneGuestProcesses

/// Finds the `vphone-vm` that runs one machine.
///
/// The disk image is held open only by Virtualization's own XPC service, not
/// by `vphone-vm`, so the processes `lsof` names for it are the wrong ones to
/// stop: a SIGINT ends the service, and `vphone-vm` then sees its machine stop
/// with an error. `vphone-vm` is told which machine to run by `--config`, and
/// that argument is how it is found here.
public enum VPhoneGuestProcesses {
    /// Every `vphone-vm` of this user whose `--config` is `config`, compared
    /// after resolving symbolic links on both sides.
    public static func virtualMachinePIDs(config: URL) -> [Int32] {
        let target = config.resolvingSymlinksInPath().standardizedFileURL.path
        return allPIDs().filter { pid in
            guard pid != getpid(), let arguments = arguments(of: pid) else { return false }
            return runsMachine(arguments, configPath: target)
        }
    }

    /// Whether an argument vector is a `vphone-vm` started with `--config`
    /// at `configPath` (already resolved and standardized).
    static func runsMachine(_ arguments: [String], configPath: String) -> Bool {
        guard let executable = arguments.first,
              (executable as NSString).lastPathComponent == "vphone-vm"
        else { return false }
        for (index, argument) in arguments.enumerated().dropFirst() {
            let value: String
            if argument == "--config", index + 1 < arguments.count {
                value = arguments[index + 1]
            } else if argument.hasPrefix("--config=") {
                value = String(argument.dropFirst("--config=".count))
            } else {
                continue
            }
            let path = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
            return path == configPath
        }
        return false
    }

    /// The argument vector in a `KERN_PROCARGS2` buffer: a 32-bit `argc`,
    /// the executable path, NUL padding, then `argc` NUL-terminated strings.
    static func parseProcessArguments(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path, then the padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// Nil for a process that is gone or belongs to another user.
    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }
}
