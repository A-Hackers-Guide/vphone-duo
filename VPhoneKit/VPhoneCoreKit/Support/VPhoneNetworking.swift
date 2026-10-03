import Foundation
import SystemConfiguration
import Virtualization

// MARK: - Errors

public enum VPhoneNetworkingError: Error, Equatable {
    /// hostOnly has no native Virtualization.framework attachment.
    case hostOnlyUnsupported
    /// A bridge interface was requested but no such interface exists on the host.
    case bridgeInterfaceNotFound(requested: String, available: [String])
    /// bridged mode was selected but the host exposes no bridgeable interfaces.
    case noBridgeInterfaces
    /// bridged mode was selected, no interface was named, and this process is
    /// not the one that can enumerate them.
    case bridgeInterfaceMustBeNamed
    /// `--bridge-interface` was given without selecting bridged mode.
    case bridgeInterfaceWithoutBridgedMode
}

extension VPhoneNetworkingError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .hostOnlyUnsupported:
            "Network mode 'hostOnly' is not supported. Use nat, bridged, tunnel, or none."
        case let .bridgeInterfaceNotFound(requested, available):
            "Bridge interface '\(requested)' not found. Available: \(available.isEmpty ? "none" : available.joined(separator: ", "))."
        case .noBridgeInterfaces:
            "Bridged mode needs a host network interface, but none are available. Use nat instead."
        case .bridgeInterfaceMustBeNamed:
            "Bridged mode requires an interface name because vphone-cli cannot list host interfaces. Pass one with --bridge-interface, for example --bridge-interface en0."
        case .bridgeInterfaceWithoutBridgedMode:
            "--bridge-interface is only valid with --network bridged."
        }
    }

    public var errorDescription: String? {
        description
    }
}

// MARK: - Networking helpers

/// Host-side helpers for validating and realizing a VM's `NetworkConfig`.
/// Shared between config-time editing (`VPhoneBundleOperations.updateConfig`) and boot-time
/// device construction so both agree on validation and interface resolution.
public enum VPhoneNetworking {
    public typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig
    public typealias NetworkMode = NetworkConfig.NetworkMode

    /// Identifiers of host interfaces available for bridging (empty without the
    /// `com.apple.vm.networking` entitlement, e.g. in unsigned test binaries).
    public static func availableBridgeInterfaces() -> [String] {
        VZBridgedNetworkInterface.networkInterfaces.map(\.identifier)
    }

    /// Resolve the concrete bridge interface to persist for bridged mode.
    /// - `requested`: an explicit `--bridge-interface`, validated against the host.
    /// - `current`: the interface already stored on the bundle, kept if still present.
    /// - otherwise the first available interface is auto-picked.
    public static func resolveBridgeInterface(requested: String?, current: String?) throws -> String {
        let available = availableBridgeInterfaces()

        // An empty list is ambiguous: either the host really has nothing
        // bridgeable, or this process is not entitled to ask. Since vphone-cli
        // deliberately carries no entitlements, the second case is now the
        // normal one, and rejecting a perfectly good interface name on the
        // strength of a list we know is unreliable would break bridged mode
        // outright. So when we cannot enumerate, we record what we were told
        // and let vphone-vm — which is entitled — decide at boot, where the
        // error can name the real problem.
        guard !available.isEmpty else {
            if let requested {
                return requested
            }
            if let current {
                return current
            }
            throw VPhoneNetworkingError.bridgeInterfaceMustBeNamed
        }

        if let requested {
            guard available.contains(requested) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(requested: requested, available: available)
            }
            return requested
        }
        if let current, available.contains(current) {
            return current
        }
        return available[0] // non-empty, guarded above
    }

    /// Merge partial edits onto an existing config, validating the result.
    /// A nil argument leaves that field unchanged.
    public static func merge(
        into current: NetworkConfig,
        mode: NetworkMode?,
        bridgeInterface: String?,
        resolvesMacName: Bool? = nil,
    ) throws -> NetworkConfig {
        let newMode = mode ?? current.mode
        if newMode == .hostOnly {
            throw VPhoneNetworkingError.hostOnlyUnsupported
        }
        let newBridge: String?
        if newMode == .bridged {
            newBridge = try resolveBridgeInterface(requested: bridgeInterface, current: current.bridgeInterface)
        } else {
            if bridgeInterface != nil {
                throw VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode
            }
            newBridge = current.bridgeInterface
        }
        return NetworkConfig(
            mode: newMode,
            macAddress: current.macAddress,
            bridgeInterface: newBridge,
            // On is the default, so it is stored as an absent key.
            resolvesMacName: resolvesMacName.map { $0 ? nil : false } ?? current.resolvesMacName,
        )
    }

    // MARK: - The Mac's name in the guest

    /// A name vphoned has the guest resolve locally (vphoned's
    /// `GuestStaticNames`).
    public struct StaticName: Equatable, Sendable {
        public let address: VPhoneIPv4Address
        public let names: [String]

        /// As vphoned's `network.static_names.set` takes it.
        public var parameters: [String: Any] {
            ["address": address.description, "names": names]
        }
    }

    /// This Mac's mDNS name, as `scutil --get LocalHostName` prints it.
    public static func macLocalHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// The Mac's address on vmnet's shared network, the one
    /// `VZNATNetworkDeviceAttachment` uses: `Shared_Net_Address` in vmnet's
    /// preferences when it has been moved, `192.168.64.1` otherwise.
    public static func sharedNATHostAddress() -> VPhoneIPv4Address {
        let plist = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist")
        let values = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return (values?["Shared_Net_Address"] as? String).flatMap(VPhoneIPv4Address.init(dotted:))
            ?? VPhoneIPv4Address(192, 168, 64, 1)
    }

    /// The first IPv4 address of a host interface, for `bridged`.
    public static func ipv4Address(ofInterface name: String) -> VPhoneIPv4Address? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry = list
        while let interface = entry {
            defer { entry = interface.pointee.ifa_next }
            guard String(cString: interface.pointee.ifa_name) == name,
                  let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return VPhoneIPv4Address(UInt32(bigEndian: raw))
        }
        return nil
    }

    /// The address the guest reaches this Mac at: the shared network's host
    /// address in `nat`, the gateway in `tunnel` (which carries it to the
    /// Mac's loopback), the Mac's address on the bridged interface in
    /// `bridged`. Nil without a NIC.
    public static func macAddressForGuest(
        _ cfg: NetworkConfig,
        sharedNATHost: VPhoneIPv4Address,
        bridgedAddress: VPhoneIPv4Address?,
    ) -> VPhoneIPv4Address? {
        switch cfg.mode {
        case .nat: sharedNATHost
        case .tunnel: VPhoneUserspaceNetworkConfiguration.default.hostAddress
        case .bridged: bridgedAddress
        case .off, .hostOnly: nil
        }
    }

    /// The names vphoned should have the guest resolve locally: this Mac's
    /// `<LocalHostName>.local` at the address the guest reaches it at. Empty
    /// when turned off or no address is known, which withdraws them.
    ///
    /// Over mDNS alone an IPv4 lookup of the Mac's name can fail: the guest
    /// also hears the Mac on the virtual iPhone's USB link, where the Mac has
    /// no IPv4 address and answers "no such record", and the fastest answer
    /// wins. See Research/Guest/mac_name_resolution.md.
    public static func macStaticNames(
        _ cfg: NetworkConfig,
        macName: String?,
        sharedNATHost: VPhoneIPv4Address,
        bridgedAddress: VPhoneIPv4Address? = nil,
    ) -> [StaticName] {
        guard cfg.resolvesMacName != false, let macName, !macName.isEmpty,
              let address = macAddressForGuest(cfg, sharedNATHost: sharedNATHost, bridgedAddress: bridgedAddress)
        else { return [] }
        return [StaticName(address: address, names: ["\(macName).local"])]
    }

    /// Build the VZ network device for a config, or nil for `.off` (no NIC).
    /// The MAC is left framework-assigned; a forced MAC breaks guest networking.
    /// Throws if the config cannot be realized (missing bridge interface, hostOnly).
    ///
    /// The returned `backend` is non-nil only for `.tunnel`, where the network is
    /// implemented in this process. It is a reference type whose sockets live as
    /// long as the last holder, so the caller must keep it for the whole time the
    /// VM runs, and should `start()` it once the VM does.
    public static func makeNetworkDevice(_ cfg: NetworkConfig) throws
        -> (device: VZVirtioNetworkDeviceConfiguration?, backend: VPhoneUserspaceNetwork?)
    {
        switch cfg.mode {
        case .off:
            return (nil, nil)
        case .hostOnly:
            throw VPhoneNetworkingError.hostOnlyUnsupported
        case .nat:
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            return (net, nil)
        case .tunnel:
            let network = try VPhoneUserspaceNetwork()
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = network.networkAttachment
            return (net, network)
        case .bridged:
            guard let id = cfg.bridgeInterface else {
                throw VPhoneNetworkingError.noBridgeInterfaces
            }
            guard let iface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == id }) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(
                    requested: id,
                    available: availableBridgeInterfaces(),
                )
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            return (net, nil)
        }
    }
}
