#include "../LaunchHook/VPhoneX1Lowering.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static void expect(uint32_t input, uint32_t expected) {
    uint32_t output = 0;
    assert(vp_x1_lower_instruction(input, &output));
    assert(output == expected);
}

static void reject(uint32_t input) {
    uint32_t output = 0xAAAAAAAA;
    assert(!vp_x1_lower_instruction(input, &output));
    assert(output == 0xAAAAAAAA);
}

int main(void) {
    expect(0xDAC1A7FE, 0xD503237F); // PACIBSPPC -> PACIBSP
    expect(0xDAC187FE, 0xD503237F); // PACNBIBSPPC -> PACIBSP
    expect(0xDAC1A3FE, 0xD503233F); // PACIASPPC -> PACIASP
    expect(0xDAC183FE, 0xD503233F); // PACNBIASPPC -> PACIASP
    expect(0xF3A0009F, 0xD50323FF); // AUTIBSPPCi -> AUTIBSP
    expect(0xF3BFFFFF, 0xD50323FF); // AUTIBSPPCi, maximum distance -> AUTIBSP
    expect(0xDAC1947E, 0xD50323FF); // AUTIBSPPCr -> AUTIBSP
    expect(0xF38000DF, 0xD50323BF); // AUTIASPPCi -> AUTIASP
    expect(0xF39FFFFF, 0xD50323BF); // AUTIASPPCi, maximum distance -> AUTIASP
    expect(0xDAC1909E, 0xD50323BF); // AUTIASPPCr -> AUTIASP
    expect(0x5520011F, 0xD65F0FFF); // RETABSPPCi -> RETAB
    expect(0x5520053F, 0xD65F0FFF); // fsck cold-boot RETABSPPCi -> RETAB
    expect(0x55200B1F, 0xD65F0FFF); // fsck later RETABSPPCi -> RETAB
    expect(0x553FFFFF, 0xD65F0FFF); // RETABSPPCi, maximum distance -> RETAB
    expect(0xD65F0FE5, 0xD65F0FFF); // RETABSPPCr -> RETAB
    expect(0x5500015F, 0xD65F0BFF); // RETAASPPCi -> RETAA
    expect(0x551FFFFF, 0xD65F0BFF); // RETAASPPCi, maximum distance -> RETAA
    expect(0xD65F0BE6, 0xD65F0BFF); // RETAASPPCr -> RETAA
    expect(0xDAC1BBFE, 0xD503219F); // AUTIA171615 -> AUTIA1716
    expect(0xDAC1BFFE, 0xD50321DF); // AUTIB171615 -> AUTIB1716

    expect(0x9A022020, 0x8B020020); // ADDPT x0,x1,x2
    reject(0x9A043FE3);             // SP plus shift 7 has no ordinary equivalent
    expect(0x9A0630BF, 0x8B2670BF); // ADDPT sp,x5,x6,lsl #4
    expect(0xDA092D07, 0xCB090D07); // SUBPT x7,x8,x9,lsl #3
    expect(0xDA0A27FF, 0xCB2A67FF); // SUBPT sp,sp,x10,lsl #1
    expect(0x9B620C20, 0x9B020C20); // MADDPT x0,x1,x2,x3
    expect(0x9B661CA4, 0x9B061CA4); // MADDPT x4,x5,x6,x7
    expect(0x9B6AAD28, 0x9B0AAD28); // MSUBPT x8,x9,x10,x11
    expect(0x9B6EBDAC, 0x9B0EBDAC); // MSUBPT x12,x13,x14,x15

    reject(0xDAC18BFE); // PACIA171615 deliberately unsupported
    reject(0xDAC18FFE); // PACIB171615 deliberately unsupported
    reject(0x00000000); // UDF and every unrelated instruction are forwarded
    reject(0xD503201F); // NOP
    assert(!vp_x1_lower_instruction(0xDAC1A7FE, NULL));
    puts("X1LoweringTests: PASS");
    return 0;
}
