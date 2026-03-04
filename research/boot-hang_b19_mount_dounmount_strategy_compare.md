# Boot Hang Focus: B19 + (B11/B12) Strategy Comparison

Date: 2026-03-05
Target binary family: `kernelcache.research.vphone600` (iOS 26.1 / 23B85)

## Scope

This note compares two patching styles for boot-hang triage:

1. B19 (`_IOSecureBSDRoot`) patch style mismatch:
   - upstream known-to-work fixed site
   - current dynamic patcher site
2. B11/B12 (`___mac_mount` / `_dounmount`) patch style mismatch:
   - upstream fixed-site patches
   - current dynamic strict-shape patches

The goal is to make A/B testing reproducible with concrete trigger points, pseudocode, and expected runtime effects.

---

## 1) B19 `_IOSecureBSDRoot` mismatch

### 1.1 Trigger points (clean kernel)

- `0x0128B598` (`VA 0xFFFFFE000828F598`) in `sub_FFFFFE000828F42C`
  - before: `b.ne #0x128b5bc`
  - upstream patch: `b #0x128b5bc` (`0x14000009`)
- `0x01362090` (`VA 0xFFFFFE0008366090`) in `sub_FFFFFE0008366008`
  - before: `cbz w0, #0x1362234`
  - current dynamic patch: `b #0x1362234` (`0x14000069`)

Current patched checkpoint confirms:

- `0x01362090` is patched (`b`)
- `0x0128B598` remains unpatched (`b.ne`)

### 1.2 Function logic and pseudocode

#### A) Upstream site function (`sub_FFFFFE000828F42C`)

High-level logic:

1. query `"SecureRootName"` from `IOPlatformExpert`
2. run provider call
3. release objects
4. if return code equals `0xE00002C1`, branch to fallback path (`sub_FFFFFE0007C6AA58`)

Pseudocode:

```c
ret = IOPlatformExpert->call("SecureRootName", ...);
release(...);
if (ret == 0xE00002C1) {
    return fallback_path();
}
return ret;
```

Patch effect at `0x128B598` (`b.ne -> b`):

- always take fallback path, regardless whether `ret == 0xE00002C1`.

#### B) Dynamic site function (`sub_FFFFFE0008366008`)

Key branch:

- `0x136608C`: callback for `"SecureRoot"`
- `0x1366090`: `cbz w0, #0x1362234` (branch into `"SecureRootName"` block)
- `0x1366234` onward: `"SecureRootName"` handling block

Pseudocode:

```c
if (matches("SecureRoot")) {
    ok = callback("SecureRoot");
    if (ok == 0) goto SecureRootNameBlock;  // cbz w0
    // SecureRoot success/failure handling path
}

SecureRootNameBlock:
if (matches("SecureRootName")) {
    // name-based validation + state sync
}
```

Patch effect at `0x1362090` (`cbz -> b`):

- always jump into `SecureRootNameBlock`, regardless `ok`.

### 1.3 A/B variants to test

1. `B19-A` (upstream helper only):
   - patch only `0x128B598`
   - keep `0x1362090` original
2. `B19-B` (dynamic main only):
   - patch only `0x1362090`
   - keep `0x128B598` original
3. `B19-C` (both):
   - patch both sites

### 1.4 Expected observables

- Boot logs around:
  - `apfs_find_named_root_snapshot_xid`
  - `Need authenticator (81)`
  - transition into init / panic frame
- Panic signatures:
  - null-deref style FAR near low address (for current failure class)
  - stack path involving mount/security callback chain

---

## 2) B11/B12 (`___mac_mount` / `_dounmount`) mismatch

### 2.1 Trigger points (clean kernel)

#### Upstream fixed-offset style

- `0x00CA5D54`: `tbnz w28, #5, #0xca5f18` -> `nop`
- `0x00CA5D88`: `ldrb w8, [x8, #1]` -> `mov x8, xzr`
- `0x00CA8134`: `bl #0xc92ad8` -> `nop`

#### Current dynamic style (checkpoint)

- `0x00CA4EAC`: `cbnz w0, #0xca4ec8` -> `nop`  (B11)
- `0x00CA81FC`: `bl #0xc9bdbc` -> `nop`        (B12)

And in checkpoint:

- upstream sites remain original (`0xCA5D54`, `0xCA5D88`, `0xCA8134` unchanged)
- dynamic sites are patched (`0xCA4EAC`, `0xCA81FC` are `nop`)

### 2.2 Function logic and pseudocode

#### A) `___mac_mount`-related branch (dynamic site near `0xCA4EA8`)

Disassembly window:

- `0xCA4EA8`: `bl ...`
- `0xCA4EAC`: `cbnz w0, deny`
- deny target writes non-zero return (`mov w0, #1`)

Pseudocode:

```c
ret = mac_policy_check(...);
if (ret != 0) {   // cbnz w0
    return EPERM_like_error;
}
continue_mount();
```

Dynamic patch (`0xCA4EAC -> nop`) effect:

- ignore `ret != 0` branch and continue mount path.

#### B) Upstream `___mac_mount` two-site style (`0xCA5D54`, `0xCA5D88`)

Disassembly window:

- `0xCA5D54`: `tbnz w28, #5, ...`
- `0xCA5D88`: `ldrb w8, [x8, #1]`

Pseudocode (behavioral interpretation):

```c
if (flag_bit5_set(w28)) goto restricted_path;
w8 = *(u8 *)(x8 + 1);
...
```

Upstream patches:

- remove bit-5 gate branch (`tbnz -> nop`)
- force register state (`ldrb -> mov x8, xzr`)

This is broader state manipulation than dynamic deny-branch patching.

#### C) `_dounmount` path

Upstream site:

- `0xCA8134`: `bl #0xc92ad8` -> `nop`

Dynamic site:

- `0xCA81FC`: `bl #0xc9bdbc` -> `nop`

Pseudocode (generic):

```c
... prepare args ...
ret = mac_or_policy_call_X(...);   // site differs between two strategies
...
ret2 = mac_or_policy_call_Y(...);
```

Difference:

- upstream and dynamic disable different call sites in unmount path;
- not equivalent by construction.

### 2.3 A/B variants to test

1. `MNT-A` (upstream-only style):
   - apply `0xCA5D54`, `0xCA5D88`, `0xCA8134`
   - keep `0xCA4EAC`, `0xCA81FC` original
2. `MNT-B` (dynamic-only style):
   - apply `0xCA4EAC`, `0xCA81FC`
   - keep `0xCA5D54`, `0xCA5D88`, `0xCA8134` original
3. `MNT-C` (both styles):
   - apply all five sites

---

## 3) Combined test matrix (recommended)

For minimal triage noise, run a 3x3 matrix:

- B19 mode: `B19-A`, `B19-B`, `B19-C`
- mount mode: `MNT-A`, `MNT-B`, `MNT-C`

Total 9 combinations, each from the same clean baseline kernel.

Record per run:

1. last APFS logs before failure/success
2. whether `Need authenticator (81)` appears
3. panic presence and panic PC/FAR
4. whether init proceeds past current hang point

---

## 4) Practical note

Do not mix incremental patching across already-patched binaries when comparing these modes.
Always regenerate from clean baseline before each combination, otherwise branch-site interactions can mask true causality.

---

## 5) Additional non-equivalent points (beyond B19/B11/B12)

This section answers "还有没有别的不一样的" with boot-impact-focused mismatches.

### 5.1 B13 `_bsd_init auth` is not the same logical site

#### Trigger points

- upstream fixed site: `0x00F6D95C` in `sub_FFFFFE0007F6D2B8`
- current dynamic site: `0x00FA2A78` in `sub_FFFFFE0007FA2838`

#### Function logic (high level)

- `sub_FFFFFE0007F6D2B8` is a workqueue/thread-call state machine.
- `sub_FFFFFE0007FA2838` is another lock/CAS-heavy control path.

Neither decompilation corresponds to `_bsd_init` body semantics directly.

#### Pseudocode (site-level)

`0xF6D95C` neighborhood:

```c
... 
call unlock_or_wakeup(...);   // BL at 0xF6D95C
...
```

`0xFA2A78` neighborhood:

```c
...
stats_counter++;
x2 = x9;                      // MOV at 0xFA2A78
cas_release(lock, x2, 0);
...
```

#### Risk

- This is a strong false-equivalence signal.
- If this patch is intended as `_bsd_init` auth bypass, current dynamic hit should be treated as suspect.

### 5.2 B14 `_spawn_validate_persona` strategy changed from 2xNOP to forced branch

#### Trigger points

- upstream fixed sites: `0x00FA7024`, `0x00FA702C` (same function `sub_FFFFFE0007FA6F7C`)
- current dynamic site: `0x00FA694C` (function `sub_FFFFFE0007FA6858`)

#### Function logic and loop relevance

In `sub_FFFFFE0007FA6858`, there is an explicit spin loop:

- `0xFA6ACC`: `LDADD ...`
- `0xFA6AD4`: `B.EQ 0xFA6ACC` (self-loop)

Pseudocode:

```c
do {
    old = atomic_fetch_add(counter, 1);
} while (old == target);   // tight spin at 0xFA6ACC/0xFA6AD4
```

And same function calls:

- `sub_FFFFFE0007B034E4` (at `0xFA6A94`)
- `sub_FFFFFE0007B040CC` (at `0xFA6AA8`)

Your panic signature previously mapped into this call chain, so this mismatch is high-priority for 100% CPU / hang triage.

### 5.3 B9 `_vm_fault_enter_prepare` does not hit the same function

#### Trigger points

- upstream fixed site: `0x00BA9E1C` in `sub_FFFFFE0007BA9C48`
- current dynamic site: `0x00BA9BB0` in `sub_FFFFFE0007BA9944`

#### Pseudocode (site-level)

`0xBA9E1C`:

```c
// parameter setup right before BL
ldp x4, x5, [sp, ...];
bl helper(...);
```

`0xBA9BB0`:

```c
if (w25 == 3) w21 = 2; else w21 = w25;   // csel
```

These are structurally unrelated.

### 5.4 B10 `_vm_map_protect` site differs in same large function

#### Trigger points

- upstream fixed site: `0x00BC024C`
- current dynamic site: `0x00BC012C`
- both inside `sub_FFFFFE0007BBFA48`

#### Pseudocode (site-level)

`0xBC012C`:

```c
perm = cond ? perm_a : perm_b;   // csel
```

`0xBC024C`:

```c
// different control block; not the same selection point
...
```

Even in the same function, these are not equivalent branch gates.

### 5.5 B15 `_task_for_pid` and B17 shared-region are also shifted

#### Trigger points

- B15 upstream: `0x00FC383C` (`sub_FFFFFE0007FC34B4`)
- B15 dynamic: `0x00FFF83C` (`sub_FFFFFE0007FFF824`)

- B17 upstream: `0x010729CC`
- B17 dynamic: `0x01072A88`
- both in `sub_FFFFFE000807272C`, but not same instruction role

#### Risk

- These are unlikely to explain early APFS/init mount failure alone, but they are still non-equivalent and should not be assumed interchangeable.

---

## 6) Practical triage order for 100% virtualization CPU

Given current evidence, prioritize:

1. B14 strategy A/B first (upstream `0xFA7024/0xFA702C` vs dynamic `0xFA694C`).
2. B13 strategy A/B next (`0xF6D95C` vs `0xFA2A78`).
3. Then B19 and MNT matrix.

Reason: B14 path contains a known tight spin construct and directly calls the function chain previously observed in panic mapping.

---

## 7) Normal boot baseline signature (for pass/fail triage)

Use the following runtime markers as "normal startup reached restore-ready stage" baseline:

1. USB bring-up checkpoint completes:
   - `CHECKPOINT END: MAIN:[0x040E] enable_usb`
2. Network checkpoint enters and exits without device requirement:
   - `CHECKPOINT BEGIN: MAIN:[0x0411] config_network_interface`
   - `no device required to enable network interface, skipping`
   - `CHECKPOINT END: MAIN:[0x0411] config_network_interface`
3. Restore daemon enters host-wait state:
   - `waiting for host to trigger start of restore [timeout of 120 seconds]`
4. USB/NCM path activates and host loopback socket churn appears:
   - `IOUSBDeviceController::setupDeviceSetConfiguration: configuration 0 -> 1`
   - `AppleUSBDeviceMux::message - kMessageInterfaceWasActivated`
   - repeated `sock ... accepted ... 62078 ...` then `sock ... closed`
5. BSD network interface bring-up for `anpi0` succeeds:
   - `configureDatagramSizeOnBSDInterface() [anpi0] ... returning 0x00000000`
   - `enableBSDInterface() [anpi0], returning 0x00000000`
   - `configureIPv6LLOnBSDInterface() [anpi0], IPv6 enable returning 0x00000000`
   - `disableTrafficShapingOnBSDInterface() [anpi0], disable traffic shaping returning 0x00000000`

Practical rule:

- If A/B variant run reaches marker #3 and then shows #4/#5 progression, treat it as "boot path not stuck in early kernel loop".
- If run stalls before marker #1/#2 completion or never reaches #3, prioritize kernel-side loop/panic investigation.
