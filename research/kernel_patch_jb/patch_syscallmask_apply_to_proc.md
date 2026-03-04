# C22 `patch_syscallmask_apply_to_proc`

## Source code
- File: `scripts/patchers/kernel_jb_patch_syscallmask.py`
- Method: `KernelJBPatchSyscallmaskMixin.patch_syscallmask_apply_to_proc`
- Current logic (after fix) is strict fail-closed:
  1. locate candidate by symbol or `syscallmask.c` neighborhood
  2. require legacy 4-arg prologue signature expected by this shellcode (`cbz x2`, `mov x19/x20/x21/x22`)
  3. resolve helpers and reject panic target reuse (`_panic`) and `zalloc == filter` collisions
  4. only patch BL site that matches resolved allocator target
- If these checks fail, method returns `False` and emits no patch.

## Expected outcome
- Prevent wrong-function shellcode injection; only patch when target confidence is high.

## Target
- Legacy `_syscallmask_apply_to_proc`-shape function only (when signature matches).

## Trace call stack (IDA)
- Previously mis-hit path (now blocked):
  - `sub_FFFFFE00093BB92C`
  - `sub_FFFFFE00093995B4` (profile mask underflow path, not apply function)
  - `sub_FFFFFE000939961C`
- Current firmware syscallmask cluster (re-traced):
  - `sub_FFFFFE00093BBBF4` (apply builtin profile path, contains `"com.apple.sandbox.executable"` flow)
  - `sub_FFFFFE00093BFC58` (build/allocate 4 mask slots for sandbox/profile context)
  - `sub_FFFFFE0009399944` (per-slot allocation/validation helper)
  - `sub_FFFFFE00093C2128` (bind/attach flow with type bucket handling)
  - `sub_FFFFFE00093C25B4` (type-bucket lookup/create helper)
  - cleanup chain: `sub_FFFFFE00093BFFF4` -> `sub_FFFFFE0009399894`

## IDA MCP evidence
- Anchor string: `0xfffffe00075fcec6` (`"syscallmask.c"`)
- Sample xrefs/function starts:
  - `0xfffffe0009399600` -> `0xfffffe00093995b4`
  - `0xfffffe00093adb6c` -> `0xfffffe00093ac964`
- Additional related string: `sandbox.syscallmasks` present in IDB.

## Validation
- On current `fw_prepare`-refreshed research kernel, legacy signature check does not pass.
- `patch_syscallmask_apply_to_proc` now returns `False` with 0 emitted patches (fail-closed).
- Targeted regression check: PASS (no wrong-site patch emitted).
- Branch `patch-fix-C22` currently comments C22 out from `kernel_jb.py` execution list
  (explicit skip while re-targeting is incomplete).

## Risk
- Patch is currently gated; jailbreak behavior that depends on C22 remains pending re-targeting.
