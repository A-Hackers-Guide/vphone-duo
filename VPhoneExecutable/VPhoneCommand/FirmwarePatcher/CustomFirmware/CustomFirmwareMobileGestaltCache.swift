// CustomFirmwareMobileGestaltCache.swift — drop the guest's cached MobileGestalt answers.
//
// libMobileGestalt answers most device questions from the device tree, and at
// first boot it writes those answers to a cache on the Data volume. It reads
// the cache from then on, so a guest whose Preboot device tree is repaired
// later keeps answering as the old tree did: after the board haptics repair
// removed `/product/haptics`, Settings still showed the Haptics row and tones
// stayed silent until the file was removed and the guest rebooted. Without the
// file, libMobileGestalt computes the answers again from the tree it booted.
//
// `cfw install` and `cfw update-environment` remove it when a board repair
// changed the tree, and only then. See `Research/Guest/virtio_sound.md` §7.

import Foundation
import VPhoneCoreKit

public enum CustomFirmwareMobileGestaltCache {
    /// The cache, relative to the root of the guest's Data volume, which the
    /// guest mounts at `/private/var`.
    public static let path =
        "containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

    /// Remove the cache from a mounted Data volume. Returns whether there was
    /// one: a guest that never booted has none, and that is not an error.
    ///
    /// Only a regular file is removed — that is all libMobileGestalt writes.
    /// The walk is descriptor relative, so a link on the way is refused
    /// rather than followed.
    @discardableResult
    public static func remove(fromDataVolume data: VPhoneConfinedDirectory) throws -> Bool {
        guard try data.isRegularFile(path) else { return false }
        try data.removeItem(path)
        return true
    }
}
