# HomePod mini virtualization

HomePod mini is a separate guest family, `homePod`, using the TVOS executable
platform and monolithic filesystem. It is not an Apple TV: it has its own
IPSW, accessory identity and services, and does not use TV remote navigation,
the Apple TV HD restore base, or the Apple TV 4K OTA userland replacement.

## Firmware evidence

Inspected on 2026-10-22 from the supplied
`AudioAccessory5,1_27.0_24J361_Restore.ipsw`:

- HomePod Software 27.0, build 24J361; `AudioAccessory5,1`, `b520ap`, CPID
  `0x8006`, BDID `0x22`, SDK platform `appletvos`.
- File length 4,297,178,355 bytes. Apple's CDN declares SHA-256
  `6ae3add6733be34e15924b7710cfc5e0dc97425687ab8cac38e8466add9b4ae3`.
- Native OS image `043-04683-522.dmg.aea`; no OS/App cryptexes. The cache is
  `System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e`.
- `/usr/lib/dyld` and `/sbin/launchd` are arm64e, TVOS 27.0. dyld UUID
  `4DB71CBA-9E39-3329-A28A-D34327983DCD`, SHA-256
  `50edaf559476cd21faa30cec1a0e35e602cf6f3737dbb119d2c2b2441e0d871f`.
  REA native inspection evidence:
  `ev_8551f4aa79ea0b1e08633431becb115a4f44cfd102f7c31e58d70cd42a135c8a`.
- The B520 tree reports `model=AudioAccessory5,1`, `compatible` beginning
  `B520AP`, `horseman=1`, concrete empty `siri-hub`, and
  `app-macho-architecture=arm64`. That last capability describes app admission;
  it does not mean the OS cache is plain arm64. Artwork values describe no
  panel: idiom `0`, subtype 0, scale 0.
- Userland includes `HPSetup.app`, AirMusic, AirPodcasts and backboardd.

The firmware catalog points to the [Apple-hosted IPSW](https://updates.cdn-apple.com/2026SFallFCS/a595a3b2-2c42-470a-9417-a705aaafa05c/AudioAccessory5,1_27.0_24J361_Restore.ipsw).
The boot chain, kernel and SEP remain cloudOS 26.4 beta (23E5207q), with
OpenAVB/OpenSEP as for other new machines.

## Implementation

`usesTVOS` shares platform-dependent daemon selection, monolithic layout
admission, hybrid SHA-384 component authentication, cache paths, and guest-patch
validation. Apple TV-specific menus and OTA replacement still use the Apple TV
family. The HomePod mini uses the existing TVOS-retargeted vphoned executable.

`homepod-mini` selects the existing 27 userland/kernel compatibility patches
and vphoned. GPU injection, iPhone audio/camera/sensor/environment hooks,
Apple TV OTA replacement and plain-arm64 TPRO workarounds stay off. HomePod
audio routing and physical accessory transports require separate validation.

The new `devicetree-cfw-homepod_product` declaration copies `horseman`,
`siri-hub` and app architecture from the actual donor tree, only for B520's
installed identity. It uses parsed property flags; a syscfg placeholder is
removed rather than copied as data. Existing board presentation supplies the
model/product strings, removes phone-only capabilities and retains virtual
hardware nodes. The restore tree retains the research identity.

HomePod has no display panel. The 320×320, 72 ppi, 1× virtual canvas is a host
diagnostic surface, not physical HomePod metadata. Templates, iOS setup
automation and slimming are disabled for HomePod creation.

## Creating a machine

With a built bundle and a configured host:

```zsh
cli='/absolute/path/to/VPhone.bundle/Contents/MacOS/vphone-cli'
"$cli" vm create homepod-mini --device AudioAccessory5,1 \
  --iphone-source '/Users/insidegui/Downloads/AudioAccessory5,1_27.0_24J361_Restore.ipsw' \
  --cloudos-source '/absolute/path/to/cloudOS_23E5207q_Restore.ipsw' \
  --cpu 4 --memory 4096 --disk-size 32
```

The historical `--iphone-source` option accepts the HomePod IPSW. The catalog
also supplies its URL. Launchpad selects the HomePod preset and disables
templates/slimming; specified local IPSWs are inspected by manifest even when
renamed. The CLI also infers the device from a local or cached IPSW when
`--device` is omitted. An uncached remote source needs explicit `--device`.
For the manual prepare/restore pipeline, select `homepod-mini` with
`fw set-patches` before preparing. The guest family and preset ship in the
2.11 bundle/Launchpad series; Launchpad's minimum bundle version is 2.11.0.

## Validation

Validated on 2026-10-22 with four CPUs, 4 GiB memory and a 32 GB disk:

- The supplied IPSW's SHA-256 matches Apple's CDN metadata above.
- Native `fw prepare` completed with cloudOS 26.4 (23E5207q), retaining B520's
  tree and skipping GPU recovery. `fw patch` applied 241 records without an
  undeclared-patch warning. The existing research boot-chain identity was
  retained for restore.
- OpenAVB/OpenSEP DFU restore completed, including system volume sealing.
  CFW installation completed through Launchpad's installed helper, with the
  launchd cache gate and TVOS vphoned installed, and no patch failures.
- Three normal boots reached vphoned. On the second and final boots, using
  2.11 local bundles,
  `vm start --headless --wait` reported an answer after four seconds.
  `device.info` reports `model=AudioAccessory5,1`, `own_name=HomePod`,
  software 27.0.0, four CPUs, approximately 4 GiB memory and a NAT IPv4 address.
  Boot session UUIDs differed, confirming separate boots. The second guest
  answered again after more than a minute, without a reported panic.
- `processes.list` showed HPSetup, AirMusic, AirPodcasts, homepodsettingsd,
  homepodsensed, homehubd, homed, audioaccessoryd, audiomxd, airplayd and
  tvairplayd. This observes running services, not their functional correctness.
- The complete VPhone bundle and Launchpad build with Xcode MCP; bundle
  admission and signatures pass. Firmware identity/layout/patch regression
  suites passed (70 tests, four unavailable reference fixtures skipped).
  All 102 archive tests passed. Core ran 658 tests: 657 passed on the full
  run; an unrelated TCP throughput timing test failed under concurrent VM/disk
  work and passed on an isolated retry. Launchpad IPSW, machine identity and
  version/binding regression harnesses passed. New localized strings compile.
  The shared `VPhone` scheme exposes the existing complete-bundle target for
  the documented build command. A CLI validation probe confirms that the local
  HomePod IPSW is recognized without `--device`, before any VM is created.

The research VM is `~/.vphone/machines/homepod-mini`. Evidence is retained under
`.build/homepod-research/` (prepare, patch, restore, CFW, both guest identities,
process lists and boot results); its console is
`~/Library/Logs/vphone-launchpad/homepod-mini.log`.

Audio output and microphone capture, Siri, AirPlay playback, activation and
pairing with the Home app have not been validated. The host's diagnostic
canvas does not establish a usable graphical HomePod interface.
