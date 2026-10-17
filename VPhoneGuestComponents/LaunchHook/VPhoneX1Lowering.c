#include "VPhoneX1Lowering.h"
#include <stddef.h>

enum {
    VP_PACIASP = 0xD503233F,
    VP_PACIBSP = 0xD503237F,
    VP_AUTIASP = 0xD50323BF,
    VP_AUTIBSP = 0xD50323FF,
    VP_RETAA = 0xD65F0BFF,
    VP_RETAB = 0xD65F0FFF,
    VP_AUTIA1716 = 0xD503219F,
    VP_AUTIB1716 = 0xD50321DF,
};

static bool vp_fixed_pac(uint32_t instruction, uint32_t *replacement) {
    switch (instruction) {
    case 0xDAC1A3FE: // PACIASPPC
    case 0xDAC183FE: // PACNBIASPPC
        *replacement = VP_PACIASP;
        return true;
    case 0xDAC1A7FE: // PACIBSPPC
    case 0xDAC187FE: // PACNBIBSPPC
        *replacement = VP_PACIBSP;
        return true;
    case 0xDAC1BBFE: // AUTIA171615
        *replacement = VP_AUTIA1716;
        return true;
    case 0xDAC1BFFE: // AUTIB171615
        *replacement = VP_AUTIB1716;
        return true;
    default:
        return false;
    }
}

static bool vp_pc_pac(uint32_t instruction, uint32_t *replacement) {
    switch (instruction & 0xFFE0001F) {
    case 0xF380001F: // AUTIASPPCi
        *replacement = VP_AUTIASP;
        return true;
    case 0xF3A0001F: // AUTIBSPPCi
        *replacement = VP_AUTIBSP;
        return true;
    case 0x5500001F: // RETAASPPCi
        *replacement = VP_RETAA;
        return true;
    case 0x5520001F: // RETABSPPCi
        *replacement = VP_RETAB;
        return true;
    default:
        break;
    }
    switch (instruction & 0xFFFFFC1F) {
    case 0xDAC1901E: // AUTIASPPCr
        *replacement = VP_AUTIASP;
        return true;
    case 0xDAC1941E: // AUTIBSPPCr
        *replacement = VP_AUTIBSP;
        return true;
    default:
        break;
    }
    switch (instruction & 0xFFFFFFE0) {
    case 0xD65F0BE0: // RETAASPPCr
        *replacement = VP_RETAA;
        return true;
    case 0xD65F0FE0: // RETABSPPCr
        *replacement = VP_RETAB;
        return true;
    default:
        return false;
    }
}

static bool vp_checked_add_sub(uint32_t instruction, uint32_t *replacement) {
    uint32_t fixed = instruction & 0xFFE0E000;
    bool subtract;
    if (fixed == 0x9A002000) {
        subtract = false;
    } else if (fixed == 0xDA002000) {
        subtract = true;
    } else {
        return false;
    }

    uint32_t rd = instruction & 31;
    uint32_t rn = (instruction >> 5) & 31;
    uint32_t shift = (instruction >> 10) & 7;
    uint32_t rm = (instruction >> 16) & 31;
    if (rd == 31 || rn == 31) {
        if (shift > 4) return false;
        *replacement = (subtract ? 0xCB206000 : 0x8B206000) |
            (rm << 16) | (shift << 10) | (rn << 5) | rd;
    } else {
        *replacement = (subtract ? 0xCB000000 : 0x8B000000) |
            (rm << 16) | (shift << 10) | (rn << 5) | rd;
    }
    return true;
}

static bool vp_checked_madd_sub(uint32_t instruction, uint32_t *replacement) {
    uint32_t fixed = instruction & 0xFFE08000;
    bool subtract;
    if (fixed == 0x9B600000) {
        subtract = false;
    } else if (fixed == 0x9B608000) {
        subtract = true;
    } else {
        return false;
    }
    uint32_t fields = instruction & 0x001F7FFF;
    *replacement = (subtract ? 0x9B008000 : 0x9B000000) | fields;
    return true;
}

bool vp_x1_lower_instruction(uint32_t instruction, uint32_t *replacement) {
    if (replacement == NULL) return false;
    return vp_fixed_pac(instruction, replacement) ||
        vp_pc_pac(instruction, replacement) ||
        vp_checked_add_sub(instruction, replacement) ||
        vp_checked_madd_sub(instruction, replacement);
}
