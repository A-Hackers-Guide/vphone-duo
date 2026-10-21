# Disk caching mode

`vphone-vm` attaches `Disk.img` through `VPhoneDiskAttachment.make`, which
spells out caching `.cached` and synchronization `.full`. Before, it used
`VZDiskImageStorageDeviceAttachment(url:readOnly:)`, whose defaults are caching
`automatic` and synchronization `full` (read back on macOS 27.0.1 with a
probe; the header does not state them).

## Why `.cached`

Measured on 2026-10-21 (Mac fleet investigation W7) on two idle Mac mini M4
hosts (16 GB, macOS 27.0.1, SIP as shipped, no other VMs), with Linux guests
rather than vphone guests, since SIP as shipped cannot run a vphone. 2 GiB
guests checked known patterns in 1.3 GiB of RAM, through a virtio-blk disk
with `O_DIRECT` and through the page cache, and in `O_DIRECT` read buffers
left idle, while a host program pushed memory pressure to warning and then
critical. Each round ran 900 seconds.

| Disk | Guest-runs | Lost data |
|---|---|---|
| Sparse image, `automatic` or `uncached`, host compressing | 26 | 26 |
| Sparse image, `automatic` or `uncached`, host idle | 2 | 0 |
| Fully written (not sparse) image, `automatic` or `uncached` | 8 | 0 |
| `cached` (sparse or written, all three synchronization modes) | 39 | 0 |
| NBD | 9 | 0 |
| virtiofs | 6 | 0 |

- The loss is always zeros, never stale data, in runs that are whole
  multiples of 2 MiB of guest RAM. It hits anonymous memory the guest never
  did I/O into, the guest kernel itself (one guest oopsed on a NULL pointer),
  page-cache pages and idle `O_DIRECT` buffers. A zeroed dirty page written
  back leaves a zero block in the image.
- What gates it is the host compressor working on guest memory, not the
  pressure level: one round lost data at level normal, and every round where
  the compressor stayed idle was clean. A memory gate or a 1.0 overcommit
  ratio does not protect a non-cached guest.
- 36 of the 39 `cached` guest-runs saw the host at critical, some for five
  minutes.

So the loss needs a non-cached attachment on a sparse image while the host
compresses guest memory, and `.cached` removed it on these hosts. A vphone
guest itself was not tested; it uses the same attachment.

## Effect on existing machines

Nothing on disk or in `config.plist` changes, and no manifest key is added.
The mode is chosen by `vphone-vm` at each launch, so a machine takes it at its
first launch with a bundle carrying this change; a running machine keeps the
old mode until it restarts. Going back to an older bundle goes back to
`automatic` with nothing to undo. `.cached` lets the host page cache hold more
of the image; the memory and speed effect on a running vphone is not measured.
