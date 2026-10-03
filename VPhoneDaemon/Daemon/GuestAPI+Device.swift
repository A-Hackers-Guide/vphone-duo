import Foundation
import IcliKit
import IcliSystem

// MARK: - Device, Display, Audio, Network

extension GuestAPI {
    static func executeDevice(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "device.info":
            var info = try collectDeviceSnapshot()
            info["jailbreak"] = jailbreakInfo()
            info["network"] = networkInfo()
            info["screen"] = screenInfo()
            info["rotation"] = rotationInfo()
            info["brightness"] = brightnessState()
            info["volume"] = volume()
            info["low_power_mode"] = (try? lowPowerMode()) ?? [:]
            info["developer_mode"] = (try? developerModeStatus()) ?? [:]
            info["agent"] = ["binary_hash": binaryHash, "pid": getpid()]
            return info
        case "device.network":
            return networkInfo()
        case "network.resolve":
            let port = (params["port"] as? NSNumber).map { $0.intValue }
            let family: Int32 = switch optionalString(params, "family") {
            case "ipv4": AF_INET
            case "ipv6": AF_INET6
            default: AF_UNSPEC
            }
            return try resolveHost(
                string(params, "host"), family: family, port: port,
                firstOnly: params["first_only"] as? Bool ?? false,
                timeout: number(params, "timeout_ms", default: 5000) / 1000,
            )
        case "network.static_names.get":
            return GuestStaticNames.shared.describe()
        case "network.static_names.set":
            return try GuestStaticNames.shared.set(params["entries"] as? [[String: Any]] ?? [])
        case "device.ioreg":
            return try ioregistry(plane: optionalString(params, "plane") ?? "IOService")
        case "device.environment":
            return try environmentReport()
        case "device.basebin":
            return try compareBaseBin(bundled: optionalString(params, "archive"))
        case "display.brightness":
            if params["value"] != nil {
                try setBrightness(requiredNumber(params, "value"))
            }
            return brightnessState()
        case "display.rotation":
            if let orientation = optionalString(params, "orientation") {
                return try setRotation(orientation)
            }
            return rotationInfo()
        case "display.orientation":
            return interfaceOrientation()
        case "display.rotation_lock":
            guard let locked = params["locked"] as? Bool else {
                throw GuestAPIError.invalidRequest("locked must be true or false")
            }
            return try setRotationLock(locked)
        case "audio.volume":
            let category = optionalString(params, "category") ?? "Audio/Video"
            if params["value"] != nil {
                return try setVolume(requiredNumber(params, "value"), category: category)
            }
            return ["volume": volume(category), "category": category]
        case "audio.state":
            return try audioState()
        case "network.capture":
            let seconds = number(params, "seconds", default: 5)
            return try capturePackets(
                seconds: seconds,
                interface: optionalString(params, "interface") ?? "en0",
                filter: optionalString(params, "filter"),
            )
        case "security.ssl_killswitch":
            return sslKillswitchStatus()
        case "diagnostics.self_test":
            return try runSelfTests()
        case "notify.post":
            let state = try params["state"].map(notificationState)
            return try postDarwinNotification(string(params, "name"), state: state)
        case "notify.state":
            return try darwinNotificationState(string(params, "name"))
        default:
            return nil
        }
    }

    /// The interface orientation in `display.rotation`'s degrees, cheap
    /// enough for the host to ask every second. SpringBoard is asked
    /// directly; `rotationInfo()` captures the screen, and is only the
    /// fallback when SpringBoard does not answer.
    private static func interfaceOrientation() -> [String: Any] {
        if let degrees = interfaceRotationDegrees() {
            return ["degrees": degrees, "source": "springboard"]
        }
        let degrees = (rotationInfo()["degrees"] as? NSNumber)?.intValue ?? 0
        return ["degrees": degrees, "source": "screen"]
    }

    private static func brightnessState() -> [String: Any] {
        ["value": brightness(), "auto": autoBrightness().map { $0 as Any } ?? NSNull()]
    }

    /// A notify(3) state is a full UInt64, beyond what a JSON double holds
    /// exactly, so a decimal string is accepted as well as a number. A JSON
    /// boolean also decodes as NSNumber and is refused.
    private static func notificationState(_ value: Any) throws -> UInt64 {
        let number = (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        let text = (value as? String) ?? number?.stringValue
        guard let text, let state = UInt64(text) else {
            throw GuestAPIError.invalidRequest("state must be an unsigned 64-bit integer")
        }
        return state
    }
}

// MARK: - Name resolution

extension GuestAPI {
    /// One `getaddrinfo` answer, kept as the raw socket address for the
    /// connect test.
    private struct ResolvedAddress {
        let text: String
        let family: Int32
        let storage: Data
    }

    /// The results of a `getaddrinfo` that ran on another thread, which
    /// `resolveHost` stops waiting for after its timeout.
    private final class ResolutionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (status: Int32, addresses: [ResolvedAddress])?

        func set(_ status: Int32, _ addresses: [ResolvedAddress]) {
            lock.withLock { value = (status, addresses) }
        }

        func get() -> (status: Int32, addresses: [ResolvedAddress])? {
            lock.withLock { value }
        }
    }

    /// What the guest's own resolver makes of `host`: every address
    /// `getaddrinfo` returns, in its order, and how long it took. With `port`,
    /// each address is also connected to (two seconds each; only the first with
    /// `first_only`, as a client that does not fall back would), reporting the
    /// local address the guest used, which names the interface it went out of.
    /// For diagnosing names that resolve slowly, or to an address the guest
    /// cannot reach.
    static func resolveHost(_ host: String, family: Int32, port: Int?, firstOnly: Bool, timeout: Double) throws -> [String: Any] {
        let started = Date()
        let result = ResolutionResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = family
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, port.map(String.init), &hints, &list)
            var addresses: [ResolvedAddress] = []
            var entry = list
            while let info = entry {
                defer { entry = info.pointee.ai_next }
                guard let address = info.pointee.ai_addr else { continue }
                addresses.append(ResolvedAddress(
                    text: numericHost(address, length: info.pointee.ai_addrlen),
                    family: info.pointee.ai_family,
                    storage: Data(bytes: address, count: Int(info.pointee.ai_addrlen)),
                ))
            }
            if let list {
                freeaddrinfo(list)
            }
            result.set(status, addresses)
            finished.signal()
        }

        let elapsed = { Int(Date().timeIntervalSince(started) * 1000) }
        guard finished.wait(timeout: .now() + max(timeout, 0.1)) == .success, let resolved = result.get() else {
            return ["host": host, "status": "timeout", "elapsed_ms": elapsed()]
        }
        var reply: [String: Any] = ["host": host, "elapsed_ms": elapsed()]
        guard resolved.status == 0 else {
            reply["status"] = "error"
            reply["error"] = String(cString: gai_strerror(resolved.status))
            return reply
        }
        reply["status"] = "resolved"
        reply["addresses"] = resolved.addresses.enumerated().map { index, address -> [String: Any] in
            var item: [String: Any] = [
                "address": address.text,
                "family": address.family == AF_INET6 ? "ipv6" : "ipv4",
            ]
            if port != nil, !firstOnly || index == 0 {
                item.merge(connectTest(address), uniquingKeysWith: { $1 })
            }
            return item
        }
        return reply
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "?" }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A non-blocking connect with a two-second limit.
    private static func connectTest(_ address: ResolvedAddress) -> [String: Any] {
        let started = Date()
        let descriptor = socket(address.family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return ["connect": "error", "connect_error": String(cString: strerror(errno))] }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        let result = address.storage.withUnsafeBytes { raw in
            connect(descriptor, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        var outcome: [String: Any] = [:]
        if result == 0 || errno == EINPROGRESS {
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            if poll(&poller, 1, 2000) == 1 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                _ = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                outcome["connect"] = error == 0 ? "connected" : "error"
                if error != 0 {
                    outcome["connect_error"] = String(cString: strerror(error))
                }
            } else {
                outcome["connect"] = "timeout"
            }
        } else {
            outcome["connect"] = "error"
            outcome["connect_error"] = String(cString: strerror(errno))
        }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        if named == 0 {
            outcome["local"] = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { numericHost($0, length: length) }
            }
        }
        outcome["connect_ms"] = Int(Date().timeIntervalSince(started) * 1000)
        return outcome
    }
}

