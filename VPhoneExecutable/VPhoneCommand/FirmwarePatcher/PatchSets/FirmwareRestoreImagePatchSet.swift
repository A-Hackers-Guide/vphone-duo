// FirmwareRestoreImagePatchSet.swift — Manifest for the customised restore image.
//
// The patchless way to a guest: instead of patching the boot chain and kernel to
// accept a modified system, the restore installs one whose digests the boot chain
// already accepts. `fw patch` merges the AppOS and SystemOS cryptexes into the OS
// image, adds what the guest needs to run (GPU driver, activation, vphoned), seals
// the result again, and rehashes every component in the BuildManifest. The boot
// chain, kernel and TXM stay stock, and nothing writes the System volume after the
// restore, because that would break the seal.
//
// Only the `minimal` preset names this set. Every patch in it is boot-essential for
// that preset, and naming it nowhere else keeps `standard` from counting them as
// dropped.

import Foundation
import VPhonePatchKit

public enum FirmwareRestoreImagePatchSet {
    public static let identifier = "com.vphone.patchset.restore.image"

    /// The merge and reseal of the OS image. Every other filesystem patch writes
    /// into the merged image, so they run only with it.
    public static let cryptexMerge = "filesystem-boot-cryptex_merge"
    public static let gpuDriver = "filesystem-boot-gpu_driver"
    public static let mobileActivation = "filesystem-boot-mobileactivationd_should_hactivate"
    public static let vphoned = "filesystem-boot-vphoned"
    public static let launchdCacheLoader = "filesystem-boot-launchd_cache_loader_unsecure_cache_gate"
    public static let digestRehash = "manifest-boot-digest_rehash"

    private static func filesystem(_ identifier: String, _ title: String, _ summary: String) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(
            identifier: identifier,
            title: title,
            summary: summary,
            target: .firmware(.filesystem),
            bootEssential: true,
        )
    }

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Restore Image",
        summary: "A pre-customised, resealed system image restored onto a stock boot chain",
        patches: [
            filesystem(
                cryptexMerge,
                "Cryptex merge",
                "Merges the AppOS and SystemOS cryptexes into the OS image and seals it again, so the stock boot chain mounts a system it has digests for.",
            ),
            filesystem(
                gpuDriver,
                "GPU driver",
                "Installs the paravirtual GPU driver from the cloudOS into the merged image.",
            ),
            filesystem(
                mobileActivation,
                "Activation",
                "Lets mobileactivationd activate the guest without Apple's activation servers.",
            ),
            filesystem(
                vphoned,
                "vphoned",
                "Installs the guest daemon and its launch daemon, which the host talks to.",
            ),
            filesystem(
                launchdCacheLoader,
                "Launch daemon cache",
                "Lets launchd load the launch daemons from the system volume instead of the signed cache, so vphoned starts.",
            ),
            VPhonePatchDeclaration(
                identifier: digestRehash,
                title: "Manifest digests",
                summary: "Rewrites the BuildManifest digests to match the merged image, its trust cache and seal.",
                target: .firmware(.manifest),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.restore.image"],
    )
}
