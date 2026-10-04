# GPU Acceleration in the Guest

Upstream issue Lakr233/vphone-cli#22 asks two things: why a Metal check run
inside the guest printed `device: (null)`, and why a guest whose apps do get
Metal is still laggy for a while after every boot. This note answers both from
measurements taken on 2026-10-04: macOS 27.0.1 (26A434), Apple M5 Pro,
cloudOS 26.4 (23E5207q) kernel, iPadOS 26.6.2 (23G90) userland, iPad Pro guests
`hz120-ipadpro` and `gpuaccel-ipad`. The measuring method is in
`display_refresh_rate.md`.

## The GPU Is in Use

The guest's Metal device is `Apple Paravirtual device GPU`. Each guest process
that uses Metal has a host `com.apple.gpusw.ParavirtualizedGraphicsGPUTask`
process that replays its commands on the host GPU through the host's own AGX
driver.

The issue's check, extended with a compute pass (a 2048×2048 RGBA16F texture, 64
`sin`/`cos` iterations per pixel) and run as a command-line tool:

| | Guest | Host (M5 Pro) |
| --- | --- | --- |
| GPU time for the pass, warm | 2.3–3.8 ms | 2.0–3.3 ms |
| Empty command buffer, commit and `waitUntilCompleted` | 0.12–0.27 ms | 0.02 ms |
| Compile from source and build the pipeline, warm | 80–220 ms | 265 ms uncached |
| The same, first time in a boot | 4.3–8.3 s | — |

GPU work runs at about native speed. A synchronous round trip costs six to
thirteen times the host's, and the first compile in a boot is slow.

The device reports `MTLGPUFamilyCommon3` and argument buffers tier 1, and no
Apple family or Metal 3. An app that requires those sees a lesser GPU than the
host has.

## `device: (null)` Outside an App

Reproduced on 26.6.2 with the tool run as root from a launchd job:

```
kernel: System Policy: MetalTest(648) deny(1) iokit-open-user-client AppleParavirtDeviceUserClient
kernel: IOUC AppleParavirtDeviceUserClient failed sandbox in process pid 648, MetalTest
MetalTest: Failed to create an IOGPUDevice... IOServiceOpen returned kIOReturn(0xE00002E2)
```

A 26.x sandbox knows nothing of the research board's paravirtual devices. An
app's container profile lets the app open the GPU's user client; the platform
policy every other process falls under does not. So Metal works in apps and in
the system UI, and a daemon or a command-line tool gets no device. The same gate
refused, on the same guest:

| User client | Refused to |
| --- | --- |
| `AppleParavirtDeviceUserClient` (Metal) | the command-line tool |
| `AppleVideoToolboxParavirtualizationUserClient` (video decoder) | `com.apple.WebKit` |
| `AppleVirtIONeuralEngineDeviceUserClient` (Neural Engine) | `spotlightknowledged`, `callservicesd` |
| `IOSurfaceAcceleratorParavirtClient` (scaler) | `vphoned` |

On a 27 base this gate is already off: `kernel-boot-iouc_sandbox_gate` is
boot-essential there, because 27 refuses backboardd its framebuffer. The opt-in
patch `kernel-exp-paravirt_user_clients` makes the same edit on a 26.x or 18.x
base. With it, on `gpuaccel-ipad`, the tool prints
`device: Apple Paravirtual device GPU` and the console holds no
`failed sandbox` line at all.

### Narrow by class name

The patch does not flip the whole gate. The deny block ends by logging
`IOUC %s failed sandbox in process %s`, and its first `%s` is the class name —
already in `x0` as a C string eight bytes before the fail-log `adrp`. The patch
overwrites that `ldr Xt, [sp, #imm]` with a branch to a code cave that reads the
first eight bytes of the class name, and branches to the gate's NotPermitted
allow target only when they equal one of four prefixes — `ApplePar`, `AppleVid`,
`AppleVir`, `IOSurfac` (AppleParavirt\*, AppleVideoToolboxParavirt\*,
AppleVirtIO\*, IOSurfaceAcceleratorParavirtClient). Any other class runs the
displaced `ldr` and falls through to the real deny, so every other sandbox denial
stays. The cave's fixed words are verified by clang/as assembly and a capstone
round-trip; the two position-dependent branches come from `ARM64Encoder`. The
anchor is the fail-string xref, the NotPermitted allow target and the deny-entry
`cbnz`, the same three the broad gate uses; the record is still
`kernel-exp-paravirt_user_clients` (sites `.redirect` and `.cave`).

Verified on a fresh iPad Pro guest (`narrowtest-ipad`, 26.6.2, both opt-in
patches on): it boots, and a plain command-line tool prints

```
RootDomainUserClient IOServiceOpen -> 0xe00002e2 (denied)
Metal device -> ALLOWED
```

— the paravirtual GPU opens from a daemon context while a non-allowlisted client
is still refused. It stays off in `standard`: Metal in daemons/CLI is a niche
need (apps already have it), so turning it on is a per-VM or preset choice; it is
a candidate to default on once it has had wider testing.

What it does not change: HLS video in Safari already played at the stream's
60 frames per second without it, with `mediaplaybackd` at 9% of a core and
`videocodecd` at 4%, so WebKit being refused the decoder is not a visible cost
there.

## Lag After Every Boot

Home Screen page swipes on `hz120-ipadpro`, by time since the VM started:

| Since start | On time | Hitches | Host shader compile | Busiest guest processes |
| --- | --- | --- | --- | --- |
| 7 s | 84% | 14 | 59% of a core | dasd 53%, SpringBoard 35%, backboardd 28%, MTLCompilerService 22% |
| 54 s | 89% | 1 | 1% | SpringBoard 25%, backboardd 17% |
| 85 s | 98% | 3 | 0% | backboardd 28%, SpringBoard 28% |

That is the lag the issue describes: after-boot work in the guest plus shaders
being compiled again, gone in about a minute and a half.

The shaders are compiled again because the host's shader cache is never hit.
Opening four apps that had all been opened in earlier boots cost 1.40 CPU-seconds
of host `MTLCompilerService` the first time after a restart and 0.19 the second
time in the same boot.

### Why the cache misses

Virtualization gives ParavirtualizedGraphics a cache directory per VM,
`$DARWIN_USER_CACHE_DIR/com.apple.paravirtualizedgraphics-<number>`, and each
host GPU task keeps its Metal function cache in a `task-<key>` directory under
it. `-[PGRemoteTask calculateCachePathAndExtension:taskRoot:]` picks the key:

- when the device's feature byte `0x36` is set, it reads 60 bytes of the guest's
  task root page and takes the 20 at offset `0x28`; if they are not all zero,
  the key is those 20 bytes in hex, 40 characters;
- otherwise the key is ten random bytes, 20 characters.

Across every VM and every boot on this Mac — 1823 task directories — the name is
20 characters, the random form. Not one is keyed. So the keyed branch is never
taken here, for any guest, which matches the feature byte being off:
`-[_PGDevice features]` returns the struct inline at device `+0x4e4`, and byte
`0x36` of it (device `+0x51a`) is what gates the read. The guest side has nothing
to offer it either: the AppleParavirt kext's task-root setup makes no use of a
cdhash or any 20-byte identity (its code-signing strings are XNU's, not the
kext's).

So this cannot be fixed by a guest firmware patch, which is the only thing
`fw`/`cfw` produce:

- The cache that misses is the **host's**, kept by `PGRemoteTask` in the VM
  service's address space.
- Whether it is keyed is decided **host-side** by that feature byte, which is off
  on this ParavirtualizedGraphics version and is not something the guest is seen
  to switch.
- Even with the feature on, the key is read from the guest's task-root page, and
  giving the guest driver code to populate it would be new kext code — but it
  would still only matter if the host read it, which it does not.

Reaching the host cache would mean changing the host ParavirtualizedGraphics
framework. That is Apple's code on the sealed system volume, and the shipped
bundle runs only system libraries, so it is out of scope. The post-boot
recompile is therefore a limitation of the host paravirtual GPU, not a guest
patch we can write. (A per-app `MTLBinaryArchive` inside a guest app would
persist that app's own pipelines, but that is an app change, not a VM one.)

## Settings That Do Nothing Here

Both are private properties of `VZMacGraphicsDeviceConfiguration`, tried on
`gpuaccel-ipad` across restarts and not kept in the code.

- `_enableProcessIsolation = false`. The guest still had ten host GPU task
  processes and the same pacing: Settings 98% on time either way, Safari 70%
  against 68%, Today View 87% against 88%.
- `_deviceFeatureLevel`. The default, 0, already gives what the highest level,
  5 (the framework logs it as "2027"), gives: Common3 and argument buffers tier 1. Level 1
  ("2022") takes both away.

## Reproducing the Check

The tool is the issue's snippet built for the guest:

```zsh
xcrun -sdk iphoneos clang -arch arm64e -miphoneos-version-min=17.0 -fobjc-arc -O2 \
    -framework Foundation -framework Metal -framework QuartzCore -o MetalTest MetalTest.m
codesign -s - -f MetalTest
```

Copy it with `files.write` (`encoding: base64`), `files.chmod` it to 755, and run
it from a launchd plist with `RunAtLoad` and `StandardOutPath` loaded through
`services.load`. `/var/tmp` is emptied at every boot.
