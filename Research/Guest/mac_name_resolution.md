# The Mac's `.local` name in the guest

A guest process doing a plain BSD `connect("<mac>.local")` hung. What the
guest's resolver returned, and what vphoned now does about it. User-facing
behaviour is in `Documents/Guides/networking.md`.

Measured 2026-10-03 with vphoned's `network.resolve` on a macOS 27.0.1 host
(LocalHostName `JackyMacBook-Pro`): `pcc-research-01` (iOS 27.0, nat and
tunnel), and the fix again on `ipad-mini-01` (iOS 26.6.2, nat).

## Two links to the Mac

Besides its NIC (`en0`), a guest has the network link a USB-connected iPhone
gives the Mac: `en1` (a self-assigned `169.254` address) and `anpi0` (IPv6
only) in the guest, an `enN` and an `anriN` on the Mac. The Mac announces its
name on all of them: `dns-sd -G v4v6 JackyMacBook-Pro.local` on the Mac lists
`192.168.64.1` on the NAT bridge, a `169.254` address on the USB-link `enN`,
and, for the A record on each `anriN`, "No Such Record".

## What the guest's resolver returned

- Right after boot, `getaddrinfo(AF_INET)` failed in 1 ms with "nodename nor
  servname provided"; `AF_INET6` returned only `fe80::…%anpi0`. The negative
  answer over `anpi0` arrives first and the guest takes it as final.
- Minutes later the same lookup returned `192.168.64.1` and the Mac's `169.254`
  address on `en1`, once those answers had been cached. So whether an IPv4
  lookup works depends on timing.
- With both cached, the `169.254` address is listed first (link-local sorts
  first). The first connection to it left through `en0` (source
  `192.168.64.61`) and timed out: iOS routes `169.254.0.0/16` through the
  primary interface only. Later connections left through `en1` and worked.
  This was seen against the Mac's own TCP stack too, so it is not the tunnel.

`/etc/hosts` is not a way out: `/private/etc` is on the sealed System volume,
mounted read-only ("Read-only file system" on write).

## What vphoned does

1. **A local record for the Mac's name.** `vphone-vm` sends
   `<LocalHostName>.local` → the address the guest reaches the Mac at, and
   vphoned registers it as a shared A record on the guest's `lo0`
   (`GuestStaticNames.swift`). On `lo0` it is visible to `getaddrinfo` (a
   LocalOnly record is visible only to `dns-sd`, checked on the Mac) and never
   announced; shared, because the Mac announces the same name. IPv4 lookups
   then returned the address from the first lookup after boot, in either case
   of the name. For about half a second after a new registration two lookups
   still lost to the negative answer, so vphoned saves the names and registers
   them again as it starts, and an unchanged set from the host is not
   registered again.
2. **Link-local over the USB link.** In nat and tunnel, vphoned adds
   `169.254.0.0/17` and `169.254.128.0/17` as interface routes through the USB
   link (routing socket; `<net/route.h>` is not in the iOS SDK, so the message
   layout is copied from macOS's). They are more specific than the `/16` on
   `en0` and leave it alone. vphoned retries every 2 seconds until the link has
   its address and every 30 after, since the routes go with the link. On two
   cold boots of `pcc-research-01`, connecting to every IPv4 address of the
   Mac's name every 3 seconds for 2 minutes never timed out; the `169.254`
   address appeared at about t+21 s and its first connection left through
   `en1`. Not in bridged, where `en0` may use link-local on the LAN.
3. **The tunnel gateway leads to the Mac.** In tunnel mode the name points at
   the gateway, and connections to the gateway (other than DNS) are carried to
   the Mac's `127.0.0.1`. A refused connection now resets the guest with the
   acknowledgment number its SYN-SENT state requires; before, the guest dropped
   the `seq 0, ack 0` reset and retried its SYN until it timed out. iOS reports
   the refusal after about a second either way, as it does against the Mac's
   own stack.

On `ipad-mini-01` after the change: the record (`192.168.64.1`), routes via
`en1`, and every IPv4 address of `jackymacbook-pro.local` (`169.254.77.36`,
`192.168.64.1`) connected. `--mac-name off` withdrew the record and the routes
and removed both saved files.
