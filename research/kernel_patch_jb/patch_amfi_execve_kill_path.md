# A2 `patch_amfi_execve_kill_path`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_amfi_execve.py`
- Match strategy:
  - String anchor: `"AMFI: hook..execve() killing"` (fallback: `"execve() killing"`).
  - Find function containing the string reference.
  - Scan backward from function end for `MOV W0, #1` (0x52800020) immediately
    followed by `LDP x29, x30, [sp, #imm]` (epilogue start).
- Rewrite: replace `MOV W0, #1` with `MOV W0, #0` — converts kill return to allow.

## 2) Expected Behavior
- All kill paths in the AMFI execve hook converge on a shared `MOV W0, #1` before
  the function epilogue. Changing this single instruction to `MOV W0, #0` converts
  every kill path to a success return:
  - "completely unsigned code" → allowed
  - Restricted Execution Mode violations → allowed
  - "Legacy VPN Plugin" → allowed
  - "dyld signature cannot be verified" → allowed
  - Generic `%s` kill message → allowed

## 3) Target
- Target function: `sub_FFFFFE000863FC6C` (AMFI `hook..execve()` handler)
  - Located in `com.apple.driver.AppleMobileFileIntegrity:__text`
- Target instruction: `MOV W0, #1` at `0xFFFFFE00086400FC` (shared kill return)
  - Followed by LDP x29,x30 → epilogue → RETAB

## 4) IDA MCP Binary Evidence

### Function structure
- Prologue: PACIBSP + SUB SP + STP register saves
- Assertions (NOT patched): Two vnode type checks at early offsets:
  - `BL sub_0x7CCC40C` (checks `*(vnode+113) == 1` i.e. regular file)
  - `BL sub_0x7CCC41C` (checks `*(vnode+113) == 2` i.e. directory)
  - These branch to assertion panic handlers on failure
- Kill paths: 5+ conditional branches to `B loc_FFFFFE00086400F8` (print + kill):
  - `0xFE000863FD1C`: unsigned code path → B directly to `0x86400FC`
  - `0xFE000863FE00`: restricted exec mode = 2 → B `0x86400F8`
  - `0xFE000863FE4C`: restricted exec mode = 4 → B `0x86400F8`
  - `0xFE000863FEBC`: Legacy VPN Plugin → B `0x86400F8`
  - `0xFE000863FF38`: restricted exec mode = 3 → B `0x86400F8`
- Shared kill epilogue at `0xFE00086400F8`:
  ```
  0x86400F8: BL sub_81A1134      ; printf the kill message
  0x86400FC: MOV W0, #1          ; ← PATCH TARGET (kill return value)
  0x8640100: LDP X29, X30, [SP,#0x80]
  ...
  0x864011C: RETAB
  ```

### String hits
- `0xFE00071F71C2`: "AMFI: hook..execve() killing %s (pid %u): Attempt to execute completely unsigned code..."
- `0xFE00071F73B8`: "...Attempt to execute a Legacy VPN Plugin."
- `0xFE00071F740B`: "...dyld signature cannot be verified..."
- `0xFE00071F74DF`: "AMFI: hook..execve() killing %s (pid %u): %s\n"

## 5) Previous Bug (PANIC root cause)
The original implementation searched for `BL + CBZ/CBNZ w0` patterns in the
first 0x120 bytes and found the vnode-type assertion BLs:
1. `BL sub_0x7CCC40C` + `CBZ W0` → checks if vnode is a regular file
2. `BL sub_0x7CCC41C` + `CBNZ W0` → checks if vnode is a directory

Replacing the first BL with `MOV X0, #0` made W0=0, triggering `CBZ W0` →
jumped to `BL sub_FFFFFE000865A5C4` (assertion panic handler) → kernel panic.

These are **precondition assertions**, not AMFI kill checks. The actual kill
logic is deeper in the function and uses `return 1` via the shared epilogue.

## 6) Fix Applied
- Replaced the BL+CBZ/CBNZ pattern matching with backward epilogue scan.
- Single-instruction patch: `MOV W0, #1` → `MOV W0, #0` at the shared kill return.
- All kill paths now return 0 (allow) instead of 1 (kill).
- Assertion checks remain untouched (they pass naturally for valid executables).
