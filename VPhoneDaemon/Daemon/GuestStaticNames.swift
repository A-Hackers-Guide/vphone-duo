import dnssd
import Foundation

/// Names the guest resolves locally, set by the host: A records registered
/// with the guest's own mDNSResponder on `lo0`, held for as long as vphoned
/// runs. They are also saved, and vphoned registers them again as it starts,
/// before the host has connected. That matters: for a moment after a record is
/// registered, a lookup can still lose to the Mac's negative answer (seen on
/// iOS 27 for about half a second), so the host resending the same names on
/// every connect must not register them anew.
///
/// This is how the Mac's `.local` name gets a dependable IPv4 answer. Over
/// multicast the guest also hears the Mac on the virtual iPhone's USB link,
/// where the Mac has no IPv4 address and answers an IPv4 query with "no such
/// record"; whichever link answers first wins, so an IPv4 lookup could fail
/// outright until a real answer had been cached from another link. A record
/// registered here is answered at once, from the guest itself.
///
/// - `lo0`, not LocalOnly: a LocalOnly record answers `dns-sd` but not
///   `getaddrinfo`. On `lo0` every resolver in the guest sees it, and nothing
///   is ever announced on a network.
/// - Shared, not unique: the Mac announces the same name, and a unique record
///   would lose the conflict.
/// - Nothing is written to disk: the system volume is sealed and read-only, so
///   `/etc/hosts` cannot be edited without a remount.
///
/// Threading: every field is touched under `lock`; the connection's replies
/// are drained on `queue`. That is the invariant behind `@unchecked Sendable`.
final class GuestStaticNames: @unchecked Sendable {
    static let shared = GuestStaticNames()

    private struct Entry: Equatable {
        let address: String
        let names: [String]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vphoned.static-names")
    private var connection: DNSServiceRef?
    private var entries: [Entry] = []
    /// On the data volume, which survives reboots; the system volume is sealed.
    private static let savePath = "/var/root/Library/Preferences/com.vphone.vphoned.static-names.plist"

    func describe() -> [String: Any] {
        lock.withLock { ["entries": entries.map { ["address": $0.address, "names": $0.names] }] }
    }

    /// Replace every record with `entries` (`[{address, names}]`, IPv4 only).
    /// An empty list withdraws them all.
    func set(_ list: [[String: Any]]) throws -> [String: Any] {
        var wanted: [Entry] = []
        for item in list {
            guard let address = item["address"] as? String, Self.ipv4Bytes(address) != nil,
                  let names = item["names"] as? [String], !names.isEmpty,
                  names.allSatisfy({ name in
                      !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
                  })
            else {
                throw GuestAPIError.invalidRequest("entries must be [{address, names}] with an IPv4 address and plain host names")
            }
            wanted.append(Entry(address: address, names: names))
        }

        return try lock.withLock {
            guard wanted != entries else {
                return ["entries": list, "changed": false]
            }
            // Closing the connection withdraws every record registered on it.
            if let connection {
                DNSServiceRefDeallocate(connection)
                self.connection = nil
            }
            entries = []
            guard !wanted.isEmpty else {
                Self.save([])
                return ["entries": [], "changed": true]
            }

            var created: DNSServiceRef?
            var error = DNSServiceCreateConnection(&created)
            guard error == kDNSServiceErr_NoError, let created else {
                throw GuestAPIError.operationFailed("DNSServiceCreateConnection failed (\(error))")
            }
            let loopback = if_nametoindex("lo0")
            for entry in wanted {
                var address = Self.ipv4Bytes(entry.address)!
                for name in entry.names {
                    var record: DNSRecordRef?
                    let fullName = name.hasSuffix(".") ? name : name + "."
                    error = DNSServiceRegisterRecord(
                        created, &record, DNSServiceFlags(kDNSServiceFlagsShared), loopback,
                        fullName, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                        UInt16(address.count), &address, 120, { _, _, _, _, _ in }, nil,
                    )
                    guard error == kDNSServiceErr_NoError else {
                        DNSServiceRefDeallocate(created)
                        throw GuestAPIError.operationFailed("could not register \(name) (\(error))")
                    }
                }
            }
            DNSServiceSetDispatchQueue(created, queue)
            connection = created
            entries = wanted
            Self.save(list)
            return ["entries": list, "changed": true]
        }
    }

    /// Register the saved names at startup. mDNSResponder can come up after
    /// vphoned, so a failure is retried for a few minutes.
    func restoreOnStartup(attempt: Int = 0) {
        guard let data = FileManager.default.contents(atPath: Self.savePath),
              let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]],
              !list.isEmpty
        else { return }
        do {
            _ = try set(list)
            NSLog("vphoned: %d static names restored", list.count)
        } catch {
            guard attempt < 60 else {
                NSLog("vphoned: static names not restored: %@", String(describing: error))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self.restoreOnStartup(attempt: attempt + 1)
            }
        }
    }

    private static func save(_ list: [[String: Any]]) {
        if list.isEmpty {
            try? FileManager.default.removeItem(atPath: savePath)
            return
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(atPath: (savePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: savePath, contents: data)
    }

    private static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }
}
