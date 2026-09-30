import Foundation

public struct VPhoneBundleReport: Codable, Equatable, Sendable {
    public let name: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeBytes: Int64
    public let network: VPhoneVirtualMachineManifest.NetworkConfig
    public let restoreInfo: VPhoneRestoreInfo?
    /// `false` when the last `cfw install` did not finish; `nil` when unknown.
    public let customFirmwareInstalled: Bool?
    public let udid: String?

    public init(bundle: VPhoneBundle) {
        name = bundle.name
        cpuCount = Int(bundle.manifest.cpuCount)
        memoryMB = Int(bundle.manifest.memorySize / (1024 * 1024))
        diskSizeBytes = bundle.diskSizeBytes
        network = bundle.manifest.networkConfig
        restoreInfo = VPhoneRestoreInfo.load(fromBundle: bundle)
        customFirmwareInstalled = VPhoneRestoreInfo.customFirmwareInstalled(inBundle: bundle)
        udid = VPhoneRestoreOperations.resolveUDID(bundle: bundle)
    }
}
