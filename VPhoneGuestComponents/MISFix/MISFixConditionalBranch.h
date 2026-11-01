#ifndef MISFIX_CONDITIONAL_BRANCH_H
#define MISFIX_CONDITIONAL_BRANCH_H
#include <stdint.h>
#include <string.h>

// B.cond -> inverted condition over an absolute branch. Only ordinary
// conditions0...13 and destinations outside the overwritten region qualify.
// NZCV is preserved. Like the existing absolute branch, the taken path uses
// ABI scratch register x16. BC.cond and AL/NV remain unsupported.
static unsigned vpRelocateConditionalBranch(uint32_t insn, uint64_t pc,
    uint64_t overwrittenStart, uint64_t overwrittenEnd, uint32_t *out) {
    if ((insn & 0xFF000010u) != 0x54000000u || (insn & 15u) >= 14u) return 0;
    int64_t immediate = (insn >> 5) & 0x7FFFFu;
    if (immediate & 0x40000) immediate -= 0x80000;
    uint64_t destination = pc + immediate * 4;
    if (destination >= overwrittenStart && destination < overwrittenEnd) return 0;
    out[0] = 0x54000000u | (5u << 5) | ((insn & 15u) ^ 1u);
    out[1] = 0x58000050u; // ldr x16, #8
    out[2] = 0xD61F0200u; // br x16
    memcpy(out + 3, &destination, sizeof(destination));
    return 5;
}
#endif
