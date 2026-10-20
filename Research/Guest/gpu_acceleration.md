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
boot-essential there, because 27 refuses backboardd its framebuffer. The patch
`kernel-cfw-paravirt_user_clients` makes a narrower edit on a 26.x or 18.x base,
and `standard` turns it on (see "On in `standard`" below). With it, on
`gpuaccel-ipad`, the tool prints `device: Apple Paravirtual device GPU` and the
console holds no `failed sandbox` line at all.

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
`cbnz`, the same three the broad gate uses; the declaration is
`kernel-cfw-paravirt_user_clients` (sites `.redirect` and `.cave`).

Verified on a fresh iPad Pro guest (`narrowtest-ipad`, 26.6.2, both opt-in
patches on): it boots, and a plain command-line tool prints

```
RootDomainUserClient IOServiceOpen -> 0xe00002e2 (denied)
Metal device -> ALLOWED
```

— the paravirtual GPU opens from a daemon context while a non-allowlisted client
is still refused. It first shipped off in `standard`, as a per-VM choice; it is
now on, for the reason below.

What it does not change: HLS video in Safari already played at the stream's
60 frames per second without it, with `mediaplaybackd` at 9% of a core and
`videocodecd` at 4%, so WebKit being refused the decoder is not a visible cost
there.

### On in `standard`

`standard` stopped blocking the patch on 2026-10-04. The case put forward for it
was `cameracaptured`, measured on an iPadOS 26.6.2 guest with the old
`standard`. **Corrected the same day:** the crash below is not the gate
refusing the GPU. `cameracaptured` already has a Metal device (its preload
returns early without one), and it dies on a bug in the paravirtual driver's
heap textures, which the patch does not touch ("Heap Textures Have No CPU
Layout" below). What was observed:

- At every boot it prewarms its capture shaders
  (`FigCapturePreloadShadersInternal` → CMCapture `PrewarmThreadSafeSBPs` →
  NRFV3 `-[NRFProcessorV3 prewarm]`) and dies with SIGSEGV at `0xc` inside
  `AppleParavirtGPUMetalIOGPUFamily`. launchd restarts it, and it crash-loops.
- While it does, the first process to touch the AVCapture defaults blocks on a
  synchronous XPC to it (`AVCaptureProprietaryDefaultsSingleton` →
  `csr_ensureClientEstablished`). When a guest app starts recording, that process
  is SpringBoard: Control Center's sensor indicator builds an
  `AVCaptureDeviceDiscoverySession` on the main thread, and the guest UI freezes.
  `audiomxd`'s recording `StartIO` waits 18 s on the same path, and the first
  recording after boot fails.

What stops the crash is `libvcamcaptured` skipping that prewarm, below. The
patch stays on in `standard` for what #22 asked: a daemon or a tool on a 26.x
or 18.x guest gets the GPU and the other paravirtual devices an app already
reaches.

**What this widens.** The edit is at the IOUserClient sandbox gate only. A
process whose own sandbox profile refuses `iokit-open-user-client` for a class
whose name begins with `ApplePar`, `AppleVid`, `AppleVir` or `IOSurfac` is now
let through that gate; every other class is still refused there. The checks a
driver makes itself (entitlements in `newUserClient`, its argument validation)
are untouched; the MACF check before this gate was already opened by
`patch_iouc_failed_macf` (JB-10). The match is on the first eight bytes of the
class name, so it admits every class with one of those prefixes, not only the
four named in the table above: on this research board that means the
paravirtual GPU and device clients (`AppleParavirt*`), the paravirtual
VideoToolbox decoder (`AppleVideo*`), the VirtIO drivers (`AppleVirtIO*`, among
them the Neural Engine) and IOSurface's clients (`IOSurface*`, the root
client as well as the paravirtual accelerator). Who gains: daemons, command-line
tools and system XPC services that run under the platform profile or a profile
of their own — `cameracaptured`, `com.apple.WebKit` processes,
`spotlightknowledged`, `callservicesd`, `vphoned`, and anything a researcher
runs from a shell or a launchd job. Apps gain nothing: their container profile
already opens these devices. On which bases: 26.x and 18.x. On 27 the patch
skips by version, because the boot-essential `kernel-boot-iouc_sandbox_gate`
already opens every user client there, so a 27 guest is unchanged.

**Why that is acceptable for `standard`.** These are research VMs, already
running with the sandbox hooks stubbed and the trust cache admitting anything;
this gate is what still stopped a daemon from opening a device an app opens
freely. The devices are the guest's own paravirtual hardware, their host side
is a per-VM ParavirtualizedGraphics task or the VM process, and every app on the
guest already reaches them, so the attack surface they expose is already
exposed. The narrow patch is still the right shape on 26.x: the broad
gate-off would open `RootDomainUserClient` and every other client too, which
nothing here needs.

A VM that wants the old behaviour unticks the patch
(`vphone-cli fw set-patches <vm> --block kernel-cfw-paravirt_user_clients`) and
re-patches.

The patch was introduced opt-in as `kernel-exp-paravirt_user_clients` and renamed
`kernel-cfw-paravirt_user_clients` when `standard` turned it on, as the naming
rule in `Skills/authoring-patch-sets/SKILL.md` requires. A VM whose
`PatchSelection.plist` still names the old identifier gets `unknownPatch` from
`fw patch` until that entry is removed.

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

**Correction (2026-10-19):** the guest does switch that byte. It is
supportsTask3, set by the binary version the guest kext negotiates, and a
kernel patch can ask for it. See "The keyed host cache: binary version 252
(Task3)" below. The rest of this paragraph predates that.

Reaching the host cache would mean changing the host ParavirtualizedGraphics
framework. That is Apple's code on the sealed system volume, and the shipped
bundle runs only system libraries, so it is out of scope. The post-boot
recompile is therefore a limitation of the host paravirtual GPU, not a guest
patch we can write. (A per-app `MTLBinaryArchive` inside a guest app would
persist that app's own pipelines, but that is an app change, not a VM one.)

### Seeding the cache from the host (2026-10-18)

The section above concluded that only Apple's framework could fix the misses.
The cache is plain files in a user-owned directory, so a host process can write
into it before a task opens it. That works. A seed is safe only when it holds
what **the same guest process** compiled in an earlier boot. A seed that mixes
entries from several processes hangs the guest GPU. The safe form works, but
it buys little: about two points of on-time frames. So nothing ships.

Measured on `Lychee` (iPhone, iOS 27.0.1, cloudOS 26.4 (23E5207q) driver,
macOS 27.0.1 host, bundle 2.10.1).

#### What the host checks on a hit

`-[ParavirtualizedGraphicsGPUTask handshakeWithTaskRoot:…cachePath:cacheExtension:reply:]`
in `com.apple.gpusw.ParavirtualizedGraphicsGPUTask` consumes the sandbox
extension and calls `MTLSetShaderCachePath(cachePath)`. Without a path it sets
`FS_CACHE_SIZE=0`. Everything after that is Metal's ordinary per-process
function cache, `MTLCompilerFSCache` under `MultiLevelBinaryFSCache` in
`Metal.framework`. PG adds no format and no check of its own.

`MTLCompilerFSCache::getElementImpl(MTLUINT256_t, void**, size_t*)` looks up the
key, requires the entry to be longer than 64 bytes, and compares the first 32
bytes with `SHA-256` of the body and the next 32 with the key it asked for. A
mismatch calls `invalidateCache()`, and a match returns the body. That is the
whole check. Nothing on a hit names a process, a device or a driver. A
well-formed entry is used as it is, whatever task wrote it.

PG then builds the pipeline with
`newComputePipelineStateWithDescriptor:options:0 reflection:nil error:`, after
`setResourceIndex:` and `setForceResourceIndex:YES` from the guest's command.
On failure it logs `Failed to create compute pipeline: …` to its host log.

#### File layout

- `com.apple.paravirtualizedgraphics-<ecid in decimal>/task-<random>/<arch>/functions.{list,data}`,
  `<arch>` being `16777235_530` here. A task's directory goes away when its
  process exits. The framework leaves a directory that no task owns where it
  is: ten made by earlier experiments outlived many boots.
- `functions.list`: a 32-byte constant header, then for each entry its fields
  and its key, then 8 zero bytes. The first entry's fields are `u32` tag, `u64`
  0, `u64` size, `u64` offset; the others' are `u64` 0, `u64` size, `u64`
  offset. A key is 32 bytes and comes *after* its entry's fields.
- `functions.data`: the entries, 8-byte aligned, padded to a multiple of 64 KiB.
  An entry is `SHA-256(body)`, its own key, then the body. `size` counts all
  three.
- Bodies are of two kinds. A Mach-O (`feedfacf`) holds an AGX binary with
  `__TEXT,__text` and `__GPU_METADATA`, `__GPU_LD_MD`, `__GPU_STATS_MD`,
  and the rest. A blob starting `ef13c710` carries argument names
  (`mvp_matrix`, `view_matrix`, `Params_t`…), which looks like reflection.
  These are the "pairs" seen earlier. In the 656-entry task, 400 are Mach-O
  and 256 are blobs.

#### Why a mixed seed breaks

The same key holds different bytes in different processes. Every
cross-process difference found (44 shared keys over six tasks of one boot)
falls in one of three places:

- `__GPU_STATS_MD`: the compile time. Harmless.
- One `u32` in `__GPU_LD_MD`, in the record `0x0c, 0x10, ID, 0, 0, len, name`
  (the name being the AGX function's, such as `fca15dhmha4` or `eot`). In one
  task the ID follows the order of compilation: entries 29 to 43 carry 29 to
  43. Each binary therefore embeds a per-process compile counter.
- One or two words in the reflection blobs (for example 121 against 123).

Rewriting every Mach-O ID to `1000000 + n`, with the SHA-256 recomputed, did
**not** stop the failure on its own. The ID is not the whole story, and what
else ties an entry to its process was not pinned down.

The failure itself, now with both logs:

- Host (`log stream` for the GPU task and `MTLCompilerService`): every compile
  in backboardd's task succeeds, and no `Failed to create compute pipeline`
  is logged. `downsample_4_compute` is never sent to the compiler: it is a hit.
- Guest (`logs.syslog` for backboardd, taken while Camera launches): within
  about 2 s, backboardd's CoreAnimation command buffers end with
  `Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)`.
  The GPU restarts, and only then does the next `newComputePipelineState…`
  fail. That failure is the `Compilation failed` abort in
  `CA::OGL::MetalContext::get_compute_pipeline` under
  `BlurStateCompute::downsample_box_4`.

So a hit is not rejected. It is *executed*, and the binary from another process
hangs the GPU. The ddmin pair from earlier, list positions 34 and 35, turns out
to be AGX's own blit kernel `blit_uber_buf_to_tex_uint`, not a CoreAnimation
kernel. The oracle was also flaky. Neither result was worth chasing.

#### Seeding a task with its own entries

The first task the guest creates after start, about 7 s in, is backboardd's.
That is its render server: a backboardd crash takes down that host task.
`prefill` here fills only that task's directory, with the files the same task
had at the end of the previous boot.

| Seed for backboardd's task | Boot, unlock, launch Camera | Result |
| --- | --- | --- |
| Its own files from a previous cold boot | 3 runs | 0 restarts each |
| The `boot1` union of every task | 2 runs | 14 and 393 restarts |
| The `boot1` union with every ID rewritten | 1 run | 105 restarts |

The full test then ran as three pairs: a cold boot, then a boot whose backboardd
task was seeded with that cold boot's backboardd files. Each boot launched all
eleven apps, Camera included. Compile CPU is the per-process delta of host
`MTLCompilerService` CPU time across the workload.

| Run | GPU restarts | New backboardd / cameracaptured crashes | Host compile CPU | Compiles, all (backboardd) |
| --- | --- | --- | --- | --- |
| cold 1 | 0 | 0 | 3.86 s | 640 (374) |
| seeded 1 | 0 | 0 | 1.58 s | 270 (4) |
| cold 2 | 0 | 0 | 3.76 s | 632 (373) |
| seeded 2 | 0 | 0 | 1.58 s | 273 (7) |
| cold 3 | 0 | 0 | 3.89 s | 640 (374) |
| seeded 3 | 0 | 0 | 1.82 s | 313 (27) |

These runs also reported frame pacing. Those numbers are void, for two
reasons. They came from `AppUsage.lastSubmittedTime` of the host task's
`AGXDeviceUserClient`, which was later seen not to move at all during
animations. And the workload's `{"t":"home"}` is not a command
(`unknown command: home`; the home button is `{"t":"key","name":"home"}`),
so the apps opened on top of each other and the stores never held the
go-home animation.

Two more seeded runs went wrong because the harness picked a leftover union
directory instead of backboardd's task. They gave 1010 restarts each, which
confirms the mixed case once more.

#### Where the first-use lag is

The complaint, reproduced: after a boot, opening Settings and going home is
choppy, and it smooths out after a few rounds. Frames here come from the guest:
a launchd job polls QuartzCore's exported `CARenderServerGetFrameCounter(0)`
every 0.5 ms and logs each change. Lychee renders at 60 Hz (gaps cluster at
14–17 ms). "On time" is a gap of 20 ms or less. Each window is the 3 s after
`apps.launch` of Settings (open) or the home key (close), five rounds, starting
about 14 s after the VM is up.

| Window | Cold A on time (bb compiles, Settings compiles) | Cold B | backboardd seeded from cold B |
| --- | --- | --- | --- |
| open1 | 69.8% (29, 23) | 68.3% (31, 20 in open2) | 75.6% (0, 15) |
| close1 | **36.1%** (57) | **43.6%** (61) | **38.1%** (0) |
| open2 | 76.1% (19) | 51.1% (20) | 81.6% (0) |
| close2 | 80.0% (2) | 73.3% (1) | 74.4% (1) |
| open3–5 | 83–86% | 78–87% | 80–86% |
| close3–5 | 79–84% | 69–77% | 70–78% |

Seeding backboardd's host task removed every **host** compile, and the first
go-home was still as choppy (38%). There is a second compile stage, in the
guest, and that is where the remaining first-use cost sits.

#### The guest's own shader cache is thrown away at every boot

Per round, on a cold boot (guest `processes.list` CPU at each window edge, host
`proc_pid_rusage` of the VM service and the GPU tasks): the first go-home differs
from later ones in one way only. The **guest's** `MTLCompilerService` takes
0.41 s of CPU there (0.49 s in open1, 0.15 s in open2, then nothing), while
SpringBoard and backboardd use the same CPU in every round. Host disk reads of
`Disk.img` are negligible. Its log (`logs.syslog` for `MTLCompilerService`)
shows the work is all for backboardd: over three rounds, 71
`MTLSpecializeFunctionToArchive` requests (820 ms) and 90 `MTLBuildFunctions`
(189 ms), on every boot.

Why the guest compiles at all, and why it starts over at each boot:

- CoreAnimation normally renders from precompiled pipelines in
  `MTLBinaryArchive`s. On the paravirtual GPU, backboardd logs `Precompiled
  pipelines disabled on unsupported hardware.`, so every pipeline is built at
  run time, on its render thread.
- backboardd does keep a Metal cache. `StartWindowServer` calls
  `MTLSetShaderCachePath` with its system container's Caches
  (`/private/var/containers/Data/System/<uuid>/Library/Caches`, holding
  `functions.{list,data}` and `32023/libraries.*`). Within one boot it works: a
  backboardd killed and relaunched compiles nothing.
- Across a boot it does not. The cache key is constant: the driver's
  `-[AppleParavirtDevice setupCompiler]` passes `cacheUUID` = SHA-256 of its
  own build date, and Metal mixes in only its build stamp. But
  `libCoreFSCache.dylib` writes `kern.bootsessionuuid` into the head of
  `functions.list` (bytes 4–39, after the magic `45 36 27 18`). At open it
  resets a cache stamped by another boot. Seen directly: the header went from
  `96E73E64-…` to `30366BEF-…` with the boot session, and `functions.list`
  from 19,372 bytes to 1,004. A clean `system.shutdown` changes nothing.
  Every guest Metal cache follows the same rule, SpringBoard's and the apps'
  (`/var/mobile/Library/Caches/<bundle id>/com.apple.metal`) included.
- `libCoreFSCache` reads `FS_CACHE_REUSE_ON_REBOOT`. With it set, a cache from
  another boot is kept. Verified without rebooting: write a foreign UUID into
  the header and relaunch backboardd. Without the variable the cache resets
  (19,260 to 5,932 bytes). With it set through `launchd.setenv`, nothing
  changes (19,148 bytes, foreign header kept) and backboardd compiles 2
  functions in the guest instead of 92.

Effect on the first go-home, five Settings rounds after a backboardd relaunch
with a foreign UUID in its cache (a stand-in for a boot):

| Guest cache | Host cache for backboardd's new task | Runs | close1 on time | Guest compiles for backboardd |
| --- | --- | --- | --- | --- |
| reset (today) | cold | 3 | 50.9 / 50.0 / 51.9% | 92–93 |
| reused | cold (about 120 host compiles) | 2 | 56.4 / 56.9% | 2–3 |
| reused | seeded with its own files | 2 | 65.3 / 71.4% | 0–2 |

Later go-homes run at about 78–83% on time in every mode, and no run had a GPU
restart. Fixing both caches makes the first go-home better than any cold one,
and it is the only combination that does. It is not yet as smooth as a warm
one. Settings' own first open still compiles about 20 functions on the host.

What setting the variable at boot takes:

- iOS launchd ignores `/private/var/db/com.apple.xpc.launchd/config/system.plist`
  `EnvironmentVariables` (tried: not applied, cache reset). `launchd.setenv`
  lasts only until the next boot.
- So the variable comes from SystemHook (`VPhoneGuestComponents/SystemHook`),
  which is inserted into every spawn. Its constructor calls
  `setenv("FS_CACHE_REUSE_ON_REBOOT", "1", 0)` first, before the xpcproxy,
  `DISABLE_TWEAKS` and per-daemon early returns, and before any Metal code in
  the process runs. It does so only while `/usr/lib/vphone-metal-cache-reuse`
  exists. That marker is the patch `system-systemhook-cfw-metal_cache_reuse`
  (Guest System set, on in `standard`, off for Apple TV): `cfw install` and
  `cfw update-environment` write it when the patch is selected and remove it
  when it is not. A SystemHook without the marker behaves as before.
- The host half is the backboardd-only seed above, with the same caveat: it
  relies on backboardd's task being the first one created. It is not part of
  this patch.

#### Real reboots with the patch (2026-10-19)

`Lychee` again, now on a local 2.10.1 build with the patch. Each run is a real
reboot: vphoned `system.shutdown`, then `vm start`, unlock, 10 s, then five
Settings rounds measured as above (guest `CARenderServerGetFrameCounter`
probe, 3 s windows, on time = gap of 20 ms or less). Guest compiles are the
`Compilation SUCCESS (ParentProcessName=backboardd…` lines in `logs.syslog` for
`MTLCompilerService` over the rounds. The header is bytes 4–39 of backboardd's
`functions.list` in its system container. The host cache was cold in every
run. GPU restarts are the `Trying to restart GPU` lines in that boot's
`Lychee.log`.

| Run | Bundle | Header after boot | `functions.list` before shutdown → after boot | backboardd guest compiles | GPU restarts | close1 on time | close2–5 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base1 | 2.10.1 | new | 10,356 → 10,804 | 142 | 0 | 30.4% | 67–90% |
| base2 | 2.10.1 | new | 19,372 → 10,692 | 146 | 0 | 31.7% | 66–86% |
| new1 | patched | kept | 6,156 → 8,844 | 159 | 0 | 31.8% | 62–93% |
| new2 | patched | kept | 19,204 → 19,316 | **0** | 0 | **43.9%** | 67–90% |
| new3 | patched | kept | 19,316 → 19,316 | **0** | 0 | **37.3%** | 63–89% |

- The cache now outlives a reboot: the header stays `8A5597B7-…` through three
  boots and the file keeps its size, where every unpatched boot writes a new
  boot UUID and starts again from about 10 KB.
- new1 compiled as much as a cold boot because the boot before it was the
  first with the variable and did no rounds, so its cache held 6 KB. From then
  on (new2, new3) backboardd compiles nothing in the guest during the rounds,
  and `MTLCompilerService` logs nothing at all.
- The first go-home rises from about 31% to 37–44% on time. That is less than
  the 51% → 56% the fake-boot stand-in predicted for the guest cache alone
  (from a lower starting point here: a real boot has more going on in its first
  minute than a relaunched backboardd). Later rounds are unchanged. The rest
  of the first go-home is the host cache, which still recompiles at every boot.
- Installing it here: Lychee had no restore tree for `cfw install`, and
  `cfw update-environment` refused to run with less than 50 GiB free on the
  volume (17 GiB). The new SystemHook reached the guest through vphoned's live
  environment sync at `vm start`, and the marker was written with vphoned
  `files.write`, i.e. the bytes the installer writes, not the installer itself.
  The installer step is unchanged code in the same shape as the persona-lookup
  marker next to it, and is not exercised by this run.

#### Verdict

- Per-process host seeding is safe in every run made: eleven with Camera or the
  Settings loop, three of them with all eleven apps.
- Neither cache alone fixes the first-use lag. The guest's Metal cache, reset at
  every boot through `kern.bootsessionuuid`, is half of it. The host's per-task
  cache, emptied with every task, is the other half. With both kept, the first
  go-home goes from about 51% to 65–71% on time.
- The guest half is an environment variable that Apple's own library honours,
  and it reaches every process. It ships as
  `system-systemhook-cfw-metal_cache_reuse`. On real reboots it keeps the
  guest cache and removes every guest compile, taking the first go-home from
  about 31% to 37–44%. The host half rests on the first-task assumption
  described above and does not ship.


The tools for these runs were scratch code outside the repo: a cache dumper, an
ID rewriter, the guest frame-counter job (C, built with `xcrun -sdk iphoneos
clang`) and zsh drivers. The method to repeat: watch the guest log for `Trying
to restart GPU` and capture backboardd's syslog while Camera launches. A result
without the restart count is worthless, and so is one that stops before Camera.

#### The keyed host cache: binary version 252 (Task3), 2026-10-19

The host half can be fixed the way Apple designed it: a task cache named after
the guest process, which therefore persists, instead of one named at random.

Where the feature byte comes from. `-[_PGDevice setBinaryVersion:]` fills the
host's `APVFeatures` from the version the guest kext asks for
(`getAPVFeaturesForVersion`, a ladder reached through a jump table for versions
200–252). Field names from the ivar's type encoding in the GPU task binary:

| Offset | Field | First version |
| --- | --- | --- |
| `0x33` | supportsMultipleDisplays | 245 |
| `0x34` | supportsDisplayBrightnessCaps | 250 |
| `0x35` | supportsHDRContentHeadroom | 251 |
| `0x36` | supportsTask3 | 252 |

The host logs the request: `Guest requested binary version: 245, setting
binary version to: 245` for the cloudOS 26.4 kext.

What 250–252 change on the host (macOS 27.0.1), from every read of those bytes:
`0x34` only in `-[_PGDisplayNub testUpdateBrightnessCaps:]`; `0x35` nowhere
found; `0x36` only in `calculateCachePathAndExtension:`. The GPU task process
reads its copy of the struct in one place, the handshake, and only
supportsArgumentBuffers. The version itself (`_binaryVersion`, `+0x4e0`) is
read only for MMIO readback and suspend/resume.

The guest side, in AppleParavirtGPUIOGPUFamily (cloudOS 26.4):

- `setupVersion` writes its version to device register `+0x34`, reads back what
  the host granted, and builds its own feature table from it. That table stops
  at 245, so a granted 252 is invalid to the guest and it steps back down.
  Nothing else in the kext reads the stored version (`+0x51c`).
- Each task's root page is a fresh 16 KiB buffer. The kext writes a 40-byte
  header (`0x00`–`0x27`; the word at `+4` is 2), and bytes `0x28`–`0x3b`, the
  ones Task3 reads as the key, stay zero.

Phase 1, `kernel-exp-paravirt_gpu_task3`: the request becomes 252 and the
guest's features are computed from its original 245. Verified on `Lychee`
(installed with `cfw update-kernel`): the host logs `Guest requested binary
version: 252, setting binary version to: 252`, 0 GPU restarts, Settings opens
and closes normally, and task directories still have 20-character random names,
because the key bytes are zero. On its own it changes nothing visible; it is
the switch the identity write needs.

Phase 2, not done: write a stable per-program identity (20 bytes, such as a hash
of the process's code signature or name) at `0x28` when the kext fills the
header. The kext never touches process identity, and the kernel has no symbols,
so this needs a code-cave patch calling kernel functions found by semantic
anchors.

## Heap Textures Have No CPU Layout

On the iPadOS 26.6.2 iPad Pro guest (cloudOS 26.4 driver, `standard` preset),
`cameracaptured` crashed at every boot and launchd throttled its restarts
(`successive crashes = 6`): `SIGSEGV`, `KERN_INVALID_ADDRESS` at `0xc`, on the
precompilation queue:

```
AppleParavirtGPUMetalIOGPUFamily +35956
NRFV3       -[ToneMappingCurves initWithWithContext:] +1076
NRFV3       -[RawDFInferenceGen initWithMetalContext:] +112
NRFV3       -[RawDFProcessor initWithCommandQueue:] +1048
NRFV3       -[NRFProcessorV3 prewarm] +224
CMCapture   PrewarmThreadSafeSBPs +9392
CMCapture   __FigCapturePreloadShadersInternal_block_invoke_2 +1084
```

While it crash-loops, any process that first touches AVCapture defaults waits
in a synchronous XPC to it. SpringBoard's main thread did, through the Control
Center sensor indicator's `AVCaptureDeviceDiscoverySession`, as soon as an app
started recording, and the guest UI froze until the VM was restarted. audiomxd's
`StartIO` for the recording blocked 18 s the same way, so the first recording
after each boot failed.

It is a bug in the guest's Metal driver, not the sandbox gate above:

- `-[ToneMappingCurves initWithWithContext:]` makes a shared `MTLHeap`
  (`setStorageMode:0`, `setSize:0xc800`), takes textures from it with
  `-newTextureWithDescriptor:`, and fills each with
  `-replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:`.
  `+1076` is the return address of that call.
- `AppleParavirtTexture` keeps a texture's CPU layout in the ivar `_dimension`.
  Every initialiser fills it except
  `-initWithHeap:resource:offset:length:descriptor:`, the one
  `-[AppleParavirtHeap newTextureWithDescriptor:]` uses.
  `-replaceRegion:…` (`0x8c28` in the 23E5207q driver; `+35956` is `0x8c74`)
  starts with `ldr x8, [x0, _dimension]; ldur x19, [x8, #0xc]`. That fault is
  at `0xc`. `-getBytes:…fromRegion:…` reads it the same way.
- The daemon has a Metal device. `FigCapturePreloadShadersInternal` takes
  `[[FigMetalContext metalDevice] newCommandQueue]` first and returns early
  when it is nil, and the faulting frame is a method of a real
  `AppleParavirtTexture`. `kernel-exp-paravirt_user_clients` therefore changes
  nothing here; a guest with it crashes the same way.

Any CPU upload into or readback from a heap-allocated texture faults on this
driver, in any process. The prewarm is where `cameracaptured` meets it at every
launch.

To reveal it in a driver, look for the ivar offset slot named `_dimension` in
`xcrun llvm-objdump --macho --objc-meta-data` (`0x6b7ac` in 23E5207q). List the
`ldrsw xN, [x8, #0x7ac]` loads of it with `ipsw macho disass <driver> --vaddr
0xdc8 --count 41000`. In 23E5207q these are every `AppleParavirtTexture` init
except `initWithHeap:…`, plus `dealloc`, `getBytes:…` and `replaceRegion:…`.

### Skipping the prewarm

`libvcamcaptured` removes the one call to `PrewarmThreadSafeSBPs`
(`VPhoneGuestComponents/VCamCaptured/Prewarm/`). Prewarming only compiles
shaders ahead of first use, and nothing waits on that function: it returns
nothing, stores no global and signals nothing. The rest of the preload still
runs. That includes the processor flags `FigCapturePreloadShadersInternal`
records, `DMPerformMigrationIfNeeded`, and the deferred shader cache copy.
Deferred photo processing waits up to 180 s on that copy's semaphore
(`FigWaitForDeferredShaderCacheCopyCompletion`), so skipping the whole preload
would not be safe.

The hook runs synchronously in the dylib's constructor, so it runs before the
daemon's own launch code, and only when
`/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle` is
installed. The call site is found from the one exported symbol, with no fixed
address:

1. `FigCapturePreloadShaders` is `mov w0, #0; b FigCapturePreloadShadersInternal`.
2. In that function, before its return, exactly one
   `adrp x16; add x16, x16, #imm; pacia x16, xN`. This is the block's invoke,
   `__FigCapturePreloadShadersInternal_block_invoke_2`.
3. In the block, before its return, exactly one `ldr x0, [xN, #0x20]; bl`
   whose target is a function of CMCapture's `__text`. That is
   `PrewarmThreadSafeSBPs(commandQueue)`, with the queue as the block's first
   capture. iOS 27 has a second captured load in the block, but it calls a
   stub outside `__text`.

The `bl` becomes a `nop` (`vcc_patch_word`, which checks the old word first).
Over the real bytes, the scan gives these unslid addresses:

| Build | Internal | Block | Call | `PrewarmThreadSafeSBPs` |
| --- | --- | --- | --- | --- |
| iPadOS 26.6.2 (23G90), and the 26.6 cache | `0x1aeb2f06c` | `0x1aeb2f930` | `0x1aeb2fd68` | `0x1aeb300d4` |
| iOS 27.0 (24A435) | `0x1b0758ff0` | `0x1b07598c4` | `0x1b0759d10` | `0x1b075a070` |

`make -C VPhoneGuestComponents test-vcam-prewarm` runs the same scan over a
synthetic stream with these decoys and checks each refusal.

On a guest, check these:

- `/var/mobile/Media/SimulatedCamera/vcamcaptured.log` (and `vcamcaptured:` in
  the system log) has
  `gpu prewarm: internal 0x… block 0x… call 0x… -> PrewarmThreadSafeSBPs 0x…: skipped`,
  with the 23G90 addresses above. Any `gpu prewarm: kept, …` line names the
  step that refused.
- `logs.crashes` has no `cameracaptured` report newer than the update.
- `services.print` with label `com.apple.cameracaptured` shows
  `successive crashes = 0`.
- Starting a recording in an app neither freezes SpringBoard nor delays the
  first recording.

This does not fix the driver. NRF or RawDF processing during a real capture,
or any other heap texture upload, would still fault.

## Heap Index Buffers

Unity games drew their meshes scrambled: the right vertices joined into the
wrong triangles, so scenes broke into spikes and stretched faces, and a
full-screen quad came out as one triangle. Textures were correct. Seen on
2026-10-14 in Wing Fighter on iPhone17,3 iOS 27.0.1 and in Subway Surfers on
an iPad16,1 iPadOS 26.6.2 guest, both on the cloudOS 26.4 (23E5207q) driver,
bundle 2.9.4, host macOS 27.0.1 on an M4. It is not the userland version: both
bases showed it.

### Measured

A probe run from a launchd job draws a quad that should cover a 64×64 target
and counts the lit pixels. Every path through plain buffers covered 100%:
indexed and non-indexed draws, 16- and 32-bit indices, `indexBufferOffset`
from 0 to 128 and unaligned, `baseVertex`, instancing, `stage_in` layouts with
strides 12 to 44 and attribute offsets, half, short-normalised and
uchar-normalised formats, several streams, per-instance step functions,
`setVertexBytes`, shared buffers rewritten between frames, a 4 MiB
write-combined ring, blit uploads into private buffers, a 64 MiB buffer read
16 and 64 MiB in, and `newBufferWithBytesNoCopy`.

Buffers carved from an `MTLHeap` split by role. A shared heap of 8 MiB, its
first buffer filled with decoys, then six 64 KiB buffers each holding the
quad's vertices at 0 and its indices at 1024:

```
heap buf#1..#6 vb only (plain ib)              cover 100.0%  OK
heap buf#1..#6 ib only (plain vb)              cover   0.0%  BAD
heap ib, indexBufferOffset 70000 (64-bit cmd)  cover 100.0%  OK
heap ib, indexBufferOffset 1000 (16-bit cmd)   cover   0.0%  BAD
heap ib instanceCount:1 variant                cover   0.0%  BAD
heap ib baseVertex variant                     cover   0.0%  BAD
```

Vertex buffers from a heap work at any offset; index buffers from a heap fail,
unless the draw's own `indexBufferOffset` is large. Compute kernels read and
write heap buffers correctly, so the memory is right and the draw is wrong. One
more symptom points the same way: every heap buffer reports `heapOffset` 0.

### Why

`-[PGSerializerRenderCommandEncoder drawIndexedPrimitives:…]` has two
encodings per method: a compact command with 16-bit fields and a full one with
64-bit fields. In the 23E5207q driver:

| Method | Compact / full command | Choice | Truncating store |
| --- | --- | --- | --- |
| `…indexBufferOffset:` | 0x7 / 0x6 | `0x1421c cbnz x27` | `0x14284 strh w8, [x25, #0xa]` |
| `…indexBufferOffset:instanceCount:` | 0x9 / 0x8 | `0x140b0 cbnz x28` | `0x14120 strh w8, [x26, #0xa]` |
| `…instanceCount:baseVertex:baseInstance:` | 0x1d / 0x1c and 0xb / 0xa | `0x143b4 cbnz x20`, `0x143c4 cbz w24` | `0x14450 strh w8, [x26, #0x8]` |

The choice tests only the draw's own arguments: `indexCount`,
`indexBufferOffset` and, where the method has them, the instance and base
values must each fit in 16 bits. The stored value is `[indexBuffer parentResourceOffset]
+ indexBufferOffset`, and `parentResourceOffset` is a sub-allocated buffer's
offset in its heap, which the test never sees. An index buffer 64 KiB or more
into a heap is read from `(heapOffset + indexBufferOffset) mod 65536`: another
mesh's indices, which reference vertices that exist, so nothing faults. Vertex
bindings go through `setBuffers:offsets:…` with 64-bit offsets, and the
indirect `drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:…`
has only a 64-bit form.

Two more methods store `parentResourceOffset` in 16 bits and are not patched:
`drawPatches:…:patchIndexBuffer:…` and `drawIndexedPatches:…` (tessellation),
and `-[PGSerializerBlitCommandEncoder copyFromTexture:…toBuffer:…]` at
`0x230e0`. Mobile games rarely tessellate; the blit was not measured.

### The patch

`system-paravirt_gpu-cfw-heap_index_offset` turns each selecting branch into an
unconditional `b` to the full command, which the driver already sends whenever
a value does not fit, so the host accepts it. Each site is found by the
compact command's `mov w2, #size ; mov w3, #command` pair, unique in `__text`,
and the branch must lead to the full command's own pair; a driver laid out
otherwise is refused unchanged (`CustomFirmwareParavirtGPUIndexOffset`). The
cost is 12 to 28 bytes more per indexed draw.

Verified on the iPad guest with the patched driver in place: every heap row
above covers 100%, the plain-buffer probe is unchanged, and Subway Surfers
draws its menu scene and gameplay correctly.

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
