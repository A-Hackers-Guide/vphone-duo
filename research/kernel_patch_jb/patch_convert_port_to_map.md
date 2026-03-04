# B8 `patch_convert_port_to_map`

## Status: FIXED (was PANIC)

## Root cause of failure
The patcher's backward branch search found the **wrong branch** to redirect:
- Walked backward from panic string ADRP looking for a branch targeting the "error region"
- Found PAC validation `B.EQ` at `0xFFFFFE0007B06E80` (checks PAC auth succeeded)
- Its target (`0xB06E88`, the ADRL for kernel_map) happened to fall within the error
  region range `[adrp-0x40, bl_panic+4]` — a false positive
- Patching this B.EQ to `B resume_off` caused ALL port-to-map conversions to skip the
  map lookup entirely, returning NULL for every task's vm_map
- Result: "initproc failed to start -- exit reason namespace 2 subcode 0x6"

## Actual code flow in `_convert_port_to_map_with_flavor`
```
0xB06E7C: CMP  X16, X17      ; PAC validation check
0xB06E80: B.EQ 0xB06E88      ; if PAC valid → continue ← patcher incorrectly patched this
0xB06E84: BRK  #0xC472       ; PAC failure trap
0xB06E88: ADRL X8, kernel_map ; load kernel_map address
0xB06E90: CMP  X16, X8       ; compare map ptr with kernel_map
0xB06E94: B.NE 0xB06EE8      ; if NOT kernel_map → normal path ← correct target
0xB06E98: ... set up panic args ...
0xB06EAC: ADRL X0, "userspace has control access..."
0xB06EB4: BL   _panic        ; noreturn
```

## Fix applied
Completely new approach — instead of backward branch search:
1. Walk backward from string ADRP to find `CMP + B.cond` pattern
2. The `CMP Xn, Xm` followed by `B.NE target` (where target > adrp_off) is the guard
3. Replace `B.NE` with unconditional `B` to same target
4. This makes the kernel_map case take the normal path instead of panicking

The fixed patch changes `B.NE 0xB06EE8` at `0xB06E94` to `B 0xB06EE8`:
- If map == kernel_map: now takes normal path (was: panic)
- If map != kernel_map: unchanged (takes normal path)

## IDA MCP evidence
- Panic string: `0xfffffe0007040701` "userspace has control access to a kernel map %p through task %p @%s:%d"
- String xref: `0xfffffe0007b06eac`
- Function: `sub_FFFFFE0007B06DB8` (size 0x154)
- `sub_FFFFFE00082FA814` at BL target is `_panic` (calls itself with "Assertion failed", never returns)
- Code after BL _panic (0xB06EB8) is dead code containing a TBNZ→BRK trap

## Risk
- Allows userspace to obtain a reference to the kernel vm_map through IPC
- Required for JB: enables kernel memory access from userspace
