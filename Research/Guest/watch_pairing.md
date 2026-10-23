# Pairing a virtual Apple Watch with a virtual iPhone

A watchOS 26.4 (Watch7,18) guest pairs with an iOS 26 guest through the
phone's Watch app, and the initial sync completes. No Bluetooth hardware is
involved: Apple's VM builds carry the plumbing.

Checked on 2026-10-20: a `watchos` watch and a `minimal` iPhone17,3 of iOS 26.4
(23E246), both on cloudOS 26.4 (23E244) and on the NAT network with peers
reachable, paired from the phone's Watch app. A `minimal` phone comes up in
Setup Assistant (it has no template); skip it (`setup.skip`) or go through it
before opening the Watch app.

## How pairing works between VMs

- **Discovery and link: NetworkRelay over IP.** On a VM, nanoregistryd pairs
  through NetworkRelay (`networkrelay_pairing || IsVirtualDevice`), and
  terminusd runs only `NRLinkManagerWired`. The watch advertises Bonjour
  `_nrd._tcp`, the phone browses for it, and the PIN pairing runs over IKEv2.
- **Virtual Bluetooth.** On a VM, bluetoothd drives a built-in virtual LE
  controller (BTVC) whose radio is Bonjour `_btvc._tcp`. It needs the device
  tree node `arm-io/bluetooth` with `transport-encoding = 10`, which vphone600's
  tree has (and the research board conversion adds), and `kern.hv_vmm_present`.
  The feature flag `BluetoothFeatures/EnableBTVCLeConnection` gates its LE
  connections and is off as shipped.
- **Version gate.** `NRPairingCompatibilityVersionInfo`: watchOS 26.4 is
  version 26; iOS 26.4 accepts 25 to 26, iOS 18.1 at most 23. The phone has to
  run iOS 26.

## What the VMs need

| Requirement | Patch | Why |
| --- | --- | --- |
| The machines reach each other | `vm config --nat-peers` (on by default) | vmnet isolates guests on the shared NAT network from each other; `_nrd._tcp` and `_btvc._tcp` are guest-to-guest |
| `/product/watch-companion = 1` on the phone | `devicetree-cfw-watch_companion` | vphone600's is `syscfg/waco`, which the VM's syscfg lacks, so iBoot drops it. MobileGestalt then says the phone pairs with no watch: `+[NRRegistry _supportsWatch]` is NO, the Watch app has no icon, and NanoRegistry's clients load the registry once and never see the watch nanoregistryd discovers ("Searching for Apple Watch" times out) |
| `EnableBTVCLeConnection` on both | `system-bluetoothd-cfw-btvc_le_connection` (`cfw install`), `filesystem-exp-btvc_le_connection` (restore image) | LE connections over the virtual controller |
| Activation on the watch | `filesystem-boot-mobileactivationd_should_hactivate` in `watchos` | After the PIN, the Watch app asks the watch for an activation request; an unactivated VM watch cannot make one ("Activation Failed! (Decoded request from Gizmo is nil)") |

The flag needs a reboot to change at runtime: feature flags are cached in
shared memory (`com.apple.featureflags.shm`), so restarting bluetoothd is not
enough. A runtime override goes in
`/var/preferences/FeatureFlags/Domain/BluetoothFeatures.plist`.

## Pairing

1. Create the watch (`vm create --device Watch7,18`, preset `watchos`) and an
   iOS 26 phone, and start both.
2. On the phone, open the Watch app (`com.apple.Bridge`): Start Pairing → Set
   Up for Myself. The phone lists the watch as "Apple Watch NNNNN"; choose it.
3. The watch shows a six-digit code. Type it in the phone's window: the VM has a
   hardware keyboard, so there is no on-screen keypad.
4. Continue on the phone. "Apple Watch is Syncing" takes about 8 minutes:
   three pairedsyncd activities (`appconduitd` 300 s, `appconduitd.appstate`
   60 s, `tccd` 60 s) get no answer from the watch and end by timeout. The sync
   then reaches 100 %.

## Pitfalls

- A phone built from a template with the `trimmed` service profile (the
  `standard` default) has the pairing daemons off: `terminusd` (NetworkRelay),
  `identityservicesd`, `nanobackupd`, `nanoprefsyncd`, `nanotimekitcompaniond`,
  `security.otpaird`, `watchpresenced`, `magicswitchd.companion`. Build the phone
  with `minimal`, or keep those labels (`allow`) when applying the profile.
- If the phone remembers an unfinished pairing, choose Start Over.
- Killing only the watch's Setup leaves stale pairing managers in terminusd,
  and the phone can connect to one whose code no screen shows. Restart
  terminusd, nanoregistryd and Setup together.
- A tap on a dimmed watch display only wakes it; press the crown (Home) first.
- The watch's Setup crashed in a UIKit layout trap ("Screen class invalid") on
  the language list before the watch display patches; pairing from the phone
  avoids that screen.
