# B6 `patch_proc_security_policy`

## Status: FIXED (was PANIC)

## Root cause of failure
The patcher's heuristic picked the **wrong function** to stub:
- Found `_proc_info` correctly via `sub wN,wM,#1; cmp wN,#0x21` switch pattern
- Took the "most-called BL target" within proc_info as `_proc_security_policy`
- The most-called function (4 calls) was actually **copyio** (`sub_FFFFFE0007C4DD48`), a
  generic copy-to-userspace utility used everywhere in the kernel (100+ xrefs)
- Stubbing copyio with `mov x0,#0; ret` broke all copyin/copyout operations
- Result: "Process 1 exec of /sbin/launchd failed, errno 2" (can't load launchd binary)

## Fix applied
Changed the heuristic from "most-called BL target" to a filtered approach:
1. Only count BL targets AFTER the switch dispatch (security policy is called within
   switch cases, not in the prologue)
2. Filter by function size: skip large functions >0x300 bytes (copyio and other utilities
   are large; `_proc_security_policy` is ~0x130 bytes)
3. Skip tiny functions <0x40 bytes (trivial helpers)

## IDA MCP evidence

### The wrong target (copyio)
- VA: `0xFFFFFE0007C4DD48` (file offset `0xC49D48`)
- References "copyio.c" and "copy_ensure_address_space_spec"
- 100+ xrefs from across the entire kernel
- Large function handling address space operations

### The real `_proc_security_policy`
- VA: `0xFFFFFE0008067148` (file offset `0x1063148`)
- Only 6 xrefs, all from proc_info-related functions:
  - `sub_FFFFFE0008064A30` (_proc_info main handler) x2
  - `sub_FFFFFE0008065540` x1
  - `sub_FFFFFE0008065F6C` x1
  - `sub_FFFFFE0008066624` x1
  - `sub_FFFFFE0008064078` x1
- Function size: ~0x128 bytes
- Behavior: calls current_proc, does MAC policy check via indirect call, returns 0/error

### `_proc_info` function
- VA: `0xFFFFFE0008064A30`, size `0x9F8`
- Switch table at `0xFFFFFE0008064AA0`: `SUB W28, W25, #1; CMP W28, #0x21`
- BL target counts in proc_info:
  - copyio (0x7C4DD48): 4 calls (most-called, WRONG target)
  - proc_security_policy (0x8067148): 2 calls (correct target)

## How the patch works (fixed version)
- Locator strategy:
  1. Try symbol `_proc_security_policy`.
  2. If stripped, locate `_proc_info` by switch-shape signature.
  3. Count BL targets after the switch dispatch.
  4. Filter candidates by size (0x40-0x300 bytes) to exclude utilities.
  5. Pick the best match.
- Patch action: overwrite entry with `mov x0, #0; ret`

## Expected outcome
- Force `proc_security_policy` checks to return success (allow any process to query proc_info).

## Risk
- Over-broadens process introspection (any process can read info about any other process).
