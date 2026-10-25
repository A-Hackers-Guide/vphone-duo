# Other iPhone models

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [iPadOS guests](ipados.md) · [Compatibility](compatibility.md)

The guest's iOS can come from another iPhone's restore IPSW instead of the
iPhone17,3's (iPhone 16). As with an iPad guest, the virtual hardware does not
change: the boot chain, kernel, SEP and device tree still come from the PCC
cloudOS IPSW (`vresearch101ap` / `vphone600ap`). Only the userland comes from
the chosen model's IPSW, and the device tree the guest boots is rewritten to
present that model.

## Supported devices

| Product | Model | Board | Panel | Points @3x |
| --- | --- | --- | --- | --- |
| `iPhone17,3` | iPhone 16 | D47AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,4` | iPhone 16 Plus | D48AP | 1290x2796 @ 460 ppi | 430x932 |
| `iPhone17,1` | iPhone 16 Pro | D93AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone17,2` | iPhone 16 Pro Max | D94AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone17,5` | iPhone 16e | V59AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone18,3` | iPhone 17 | V57AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,4` | iPhone Air | D23AP | 1260x2736 @ 460 ppi | 420x912 |
| `iPhone18,1` | iPhone 17 Pro | V53AP | 1206x2622 @ 460 ppi | 402x874 |
| `iPhone18,2` | iPhone 17 Pro Max | V54AP | 1320x2868 @ 460 ppi | 440x956 |
| `iPhone18,5` | iPhone 17e | V159AP | 1170x2532 @ 460 ppi | 390x844 |
| `iPhone19,2` | iPhone 18 Pro | V63AP | 1206x2622 @ 460 ppi | 402x874 |

Every model, the iPhone17,3 included, gets its panel and the identity from its
own device tree; the iPhone17,3's panel is the display it has always had.
Each model has an IPSW of its own, so `--device` is not needed. `fw catalog`
lists the iPhone 16/17 models' releases from 26.0 to 27.0.1 (the iPhone 17e
from 26.3.1), and the iPhone 18 Pro's 27.0.1,
each with the cloudOS an iPhone17,3 of that release uses, and `fw catalog
--device iPhone18,1` lists one model's.

The iPhone 17 Pro, 17 Pro Max and 18 Pro have recorded boot validation; see
[Compatibility](compatibility.md). iPhone19,2 uses ARM64E_X1. On hosts without
native X1 support, the standard preset lowers unsupported instructions; this
weakens PC-bound pointer authentication.

## Create one

```sh
vphone-cli vm create iphone17pro \
  --iphone-source 'https://updates.cdn-apple.com/2026SummerFCS/f768ecdf-e037-44e6-bfa6-949b6d127c4f/iPhone18,1_26.6.2_23G90_Restore.ipsw' \
  --cloudos-source 'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
```

In Launchpad, choose **New Machine**, pick the model under **Device** and a
release under **iOS**. `vphone-launchpad-cli vm create <name> --device
iPhone18,1` does the same from a terminal.

## What changes for another iPhone

Everything [iPadOS guests](ipados.md#what-changes-for-an-ipad) lists, with two
differences:

- The board's `/product` values replace the vphone600 placeholders the same
  way, but an iPhone board keeps the phone properties it has: Dynamic Island,
  reachability, OLED, volume-button geometry, CarPlay and Watch pairing come
  from the board instead of being removed. The patch IDs are the
  `devicetree-cfw-ipad_*` ones; they were named before iPhones used them.
- LLB is not patched for the display scale. The paravirtual display's boot
  video word says 3x, which is already an iPhone's scale.
