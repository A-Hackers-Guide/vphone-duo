#ifndef VPHONE_X1_LOWERING_H
#define VPHONE_X1_LOWERING_H

#include <stdbool.h>
#include <stdint.h>

bool vp_x1_lower_instruction(uint32_t instruction, uint32_t *replacement);

#endif
