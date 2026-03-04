"""Shared asm/constants/helpers for kernel patchers."""
#!/usr/bin/env python3
"""
kernel_patcher.py — Dynamic kernel patcher for iOS prelinked kernelcaches.

Finds all patch sites by string anchors, ADRP+ADD cross-references,
BL frequency analysis, and Mach-O structure parsing.  Nothing is hardcoded;
works across kernel variants (vresearch101, vphone600, etc.).

Dependencies:  keystone-engine, capstone
"""

import struct, plistlib
from collections import defaultdict
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN as KS_MODE_LE
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from capstone.arm64_const import (
    ARM64_OP_REG,
    ARM64_OP_IMM,
    ARM64_REG_W0,
    ARM64_REG_X0,
    ARM64_REG_X8,
)

# ── Assembly / disassembly helpers ───────────────────────────────
_ks = Ks(KS_ARCH_ARM64, KS_MODE_LE)
_cs = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
_cs.detail = True


def asm(s):
    enc, _ = _ks.asm(s)
    if not enc:
        raise RuntimeError(f"asm failed: {s}")
    return bytes(enc)


NOP = asm("nop")
MOV_X0_0 = asm("mov x0, #0")
MOV_X0_1 = asm("mov x0, #1")
MOV_W0_0 = asm("mov w0, #0")
MOV_W0_1 = asm("mov w0, #1")
RET = asm("ret")
CMP_W0_W0 = asm("cmp w0, w0")
CMP_X0_X0 = asm("cmp x0, x0")


def _asm_u32(s):
    """Assemble a single instruction and return its uint32 encoding."""
    return struct.unpack("<I", asm(s))[0]


def _verify_disas(u32_val, expected_mnemonic):
    """Verify a uint32 encoding disassembles to expected mnemonic via capstone."""
    code = struct.pack("<I", u32_val)
    insns = list(_cs.disasm(code, 0, 1))
    assert insns and insns[0].mnemonic == expected_mnemonic, (
        f"0x{u32_val:08X} disassembles to {insns[0].mnemonic if insns else '???'}, expected {expected_mnemonic}"
    )
    return u32_val


# Named instruction constants (via keystone where possible, capstone-verified otherwise)
_PACIBSP_U32 = _asm_u32("hint #27")  # keystone doesn't know 'pacibsp'
_RET_U32 = _asm_u32("ret")
_RETAA_U32 = _verify_disas(0xD65F0BFF, "retaa")  # keystone can't assemble PAC returns
_RETAB_U32 = _verify_disas(0xD65F0FFF, "retab")  # verified via capstone disassembly
_FUNC_BOUNDARY_U32S = frozenset((_RET_U32, _RETAA_U32, _RETAB_U32, _PACIBSP_U32))


def _rd32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def _rd64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


# ── KernelPatcher ────────────────────────────────────────────────


