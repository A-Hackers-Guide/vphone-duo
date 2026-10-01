# iPadOS guests

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Compatibility](compatibility.md)

A vphone VM can run iPadOS instead of iOS. Nothing about the virtual hardware
changes: the boot chain, kernel, SEP and device tree still come from the PCC
cloudOS IPSW (`vresearch101ap` / `vphone600ap`). Only the userland comes from a
different restore IPSW, an iPad's instead of the iPhone17,3's, and the device
tree is rewritten so that userland sees an iPad.

## Supported devices

| Product | Model | Board | Display |
| --- | --- | --- | --- |
| `iPad16,1` (and `iPad16,2`, same IPSW) | iPad mini (A17 Pro) | J410AP | 1488x2266 @ 326 ppi, 2x |

Other iPads are refused by `fw prepare` until their device tree values are
added to `VPhoneGuestDevice` and `DeviceTreeGuestDevicePatches.swift`.

## Create one

Pass the iPad restore IPSW where the iPhone one would go. The cloudOS is the
same one an iPhone guest of that release would use; `fw catalog` lists it.

```sh
vphone-cli vm create ipad-mini \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/cf7db64d-5866-4bf2-bfff-50a32f58bec3/iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

In Launchpad, choose **New Machine**, set **Source** to **Custom IPSWs**, and
put the iPad IPSW in the **iPhone IPSW** field and the cloudOS IPSW in the
other. The Core Bundle in use must include iPad support.

The manual stages are the same as for an iPhone guest (`vm new`,
`fw prepare`, `fw patch`, DFU + `restore`, `cfw install`, `vm launch`).
Only `fw prepare` and `fw patch` differ for an iPad; DFU, `restore` and
`cfw install` run unchanged.

## What changes for an iPad

- **`fw prepare`** recognises the IPSW from its `SupportedProductTypes`, takes
  the erase identity and `DeviceMap` entry for the guest's board (an iPad IPSW
  covers several), and records the product type and the iPad's display in the
  VM's `config.plist` (`guestProductType`, `screenConfig`). The restore tree
  is named `iPhoneOS_iPad16,1_<version>_<build>_Restore`; the `iPhone` prefix
  is the restore-tree convention every reader matches, not the device.
- **Two device trees.** The hybrid manifest normally points `DeviceTree` and
  `RestoreDeviceTree` at the same vphone600 file. For an iPad, `DeviceTree`
  points at a copy, `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p`.
  Restore boots the untouched identity that `restored_external` checks against
  the manifest (`iPhone99,11`); the guest boots the copy.
- **`fw patch`** gives that copy the iPad's identity and presentation (patch
  set `devicetree`, entries `devicetree-cfw-ipad_*`):
  - root `model` `iPad16,1`, `target-type` `J410`, `target-sub-type` `J410AP`,
    `compatible` `J410AP, VPHONE600AP, AppleVirtualPlatformARM`;
  - `/product`: `artwork-device-idiom` `pad`, subtype 2266, scale 2, the
    iPad's product name, chrome, camera and button geometry, the multitasking
    capabilities (`medusa-overlay-app-capability`, `ui-floating-live-app`,
    `ui-overlay-app`, `ui-pinned-app`), and its product type and unique model;
  - phone-only `syscfg` placeholders (Dynamic Island, reachability, ringer
    switch, volume-button geometry, CarPlay, Watch pairing) are removed.

  The virtual hardware keeps its vphone600 description: GPU feature set,
  framebuffer, memory class and boot flags.
- **`cfw install`** leaves the installed device tree alone. The iPhone17,3
  post-restore identity rewrite (`preboot-exp-devicetree_identity`) is skipped
  on an iPad guest.
- **The VM window** follows `screenConfig`, so it opens at the iPad's aspect
  ratio.
