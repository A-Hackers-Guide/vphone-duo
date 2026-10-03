# Networking

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

Each VM has one network mode, stored in its `config.plist`. It is read when the
VM starts, so a change applies from the next launch.

| Mode | How the guest reaches the internet | Use it when |
| --- | --- | --- |
| `nat` | Virtualization.framework's built-in NAT | The default. The Mac has no VPN, or the VPN does not need to carry the guest. |
| `bridged` | Directly on a physical interface of the Mac, with its own address on that network | The guest has to be reachable from other machines on the LAN. |
| `tunnel` | Through ordinary connections opened by `vphone-vm` on the Mac | The Mac's traffic goes through a VPN or a proxy app, and the guest's traffic must follow it. |
| `none` | No network device | The guest must stay offline. |

## Choosing a mode

In Launchpad, stop the machine, then choose Settings… from the `⋯` menu or the
right-click menu. The Network section has a Mode picker. New Machine sets the mode under
Advanced Options.

From the command line:

```sh
vphone-cli vm config <name> --network tunnel
# or through Launchpad
vphone-launchpad-cli exec vm config <name> --network tunnel
```

`tunnel` needs a `VPhone.bundle` that lists it in `vphone-cli vm config --help`.
An older bundle rejects the setting.

## Why `tunnel` exists

`nat` and `bridged` send the guest's packets out through a physical interface.
When a VPN owns the Mac's default route (WireGuard, Cloudflare WARP, or a proxy
app in TUN mode such as Surge or Clash), those packets skip the VPN. They leave
unencrypted, or not at all.

In `tunnel` mode the guest's network card is implemented inside `vphone-vm`.
It answers DHCP, ARP and ping for the gateway, and turns each guest TCP
connection and UDP flow into a normal socket on the Mac. Those sockets follow
the Mac's routing table like any other app's, so the VPN carries them. It needs
no root, no new network interface and no change to the Mac's network settings.

In a proxy app the guest shows up as its own client, named after the machine,
and the app's rules apply to it as they would to any other app.

## What the guest sees

| Item | Value |
| --- | --- |
| Guest address | `192.168.127.3/24`, by DHCP |
| Gateway and DNS | `192.168.127.1` |
| MTU | 1500 |
| DNS | Queries to `192.168.127.1` go to the Mac's resolver |
| Other connections to the gateway | The Mac's loopback, `127.0.0.1` (TCP and UDP) |

## Limits

- **IPv4 only.** The guest gets no IPv6 address, and IPv6 traffic is dropped.
- **Outbound only.** Nothing on the Mac or the LAN can connect to a port in the
  guest through this network. USB access (`iproxy`, `ideviceinstaller`) and
  `vphone.sock` do not use the guest network, so they still work.
- **Ping reaches the gateway only.** ICMP to the internet is not forwarded,
  so `ping 1.1.1.1` in the guest fails even while TCP and UDP work.
- **Throughput is limited by `vphone-vm`.** Every packet is handled in this
  process. Downloads and video work, but `nat` is faster when no VPN is involved.

## Checking it works

1. Start the machine and wait for it to finish booting.
2. Read the guest's address:

   ```sh
   vphone-launchpad-cli guest rpc <name> device.network
   ```

   `en0` should show `192.168.127.3`. If it shows only an `fe80::` address,
   DHCP has not finished yet. Wait a few seconds and try again.
3. Open a page in the guest:

   ```sh
   vphone-launchpad-cli guest rpc <name> apps.open_url '{"url":"https://example.com"}'
   ```

4. On the Mac, the connections belong to `vphone-vm` and use the VPN's address:

   ```sh
   lsof -nP -a -i -p "$(pgrep -f 'vphone-vm.*<name>')"
   ```

## This Mac's name in the guest

On by default. The guest resolves this Mac's mDNS name (`scutil --get
LocalHostName`, plus `.local`) at once, to the address it reaches the Mac at:

| Mode | `<Mac>.local` in the guest |
| --- | --- |
| `nat` | The Mac on the shared network, usually `192.168.64.1` |
| `tunnel` | The gateway, `192.168.127.1`. Connections to it reach the Mac's loopback (`127.0.0.1`), the way `10.0.2.2` does in QEMU and VirtualBox |
| `bridged` | The Mac's address on the bridged interface |

Over mDNS alone, an IPv4 lookup of the Mac's name in the guest could fail. The
guest also hears the Mac on the network link a USB-connected iPhone gives the
Mac, where the Mac has no IPv4 address and answers "no such record". Whichever
link answers first decides the lookup, so an app that wants an IPv4 address
got an error until a real answer had been cached from another link.

vphoned registers the name with the guest's own mDNSResponder the way it
holds an `/etc/hosts` line: as a local record that answers an IPv4 lookup at
once, with that one address, without asking the network and without the
answers it has cached. It does so each time `vphone-vm` connects, and again
when vphoned starts, so the name is in place before apps run after a reboot.
The guest's system volume is read-only, so `/etc/hosts` itself is not edited,
and nothing is announced on any network. IPv6 lookups still go to mDNS.

Without it, a lookup also listed the Mac's `169.254` address on the USB link,
first. iOS routes `169.254.0.0/16` through its primary interface, so a plain
socket connecting to that address could leave through `en0`, where nothing
answers, and wait out its timeout.

```sh
vphone-cli vm config <name> --mac-name off   # withdraw it
```

To see what the guest's resolver returns, and whether each address connects:

```sh
vphone-launchpad-cli guest rpc <name> network.resolve '{"host":"<Mac>.local","family":"ipv4","port":8000}'
```
