#include "../MISFix/MISFixConditionalBranch.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <unistd.h>

int main(void) {
    uint32_t out[5];
    for (unsigned condition = 0; condition < 14; ++condition) {
        assert(vpRelocateConditionalBranch(0x54000080u | condition, 0x100c, 0x1000, 0x1010, out) == 5);
        assert((out[0] & 15) == (condition ^ 1));
        uint64_t target; memcpy(&target, out + 3, 8); assert(target == 0x101c);
        assert(vpRelocateConditionalBranch(0x54ffff80u | condition, 0x100c, 0x1000, 0x1010, out) == 5);
        memcpy(&target, out + 3, 8); assert(target == 0xffc);
    }
    assert(!vpRelocateConditionalBranch(0x54ffffe1, 0x100c, 0x1000, 0x1010, out));
    assert(!vpRelocateConditionalBranch(0x5400008e, 0x100c, 0x1000, 0x1010, out));
    assert(!vpRelocateConditionalBranch(0x54000091, 0x100c, 0x1000, 0x1010, out));
#ifdef __aarch64__
    size_t size = (size_t)getpagesize();
    uint32_t *code = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(code != MAP_FAILED);
    code[0] = 0xf100001f; // cmp x0, #0
    uint64_t destination = (uint64_t)(uintptr_t)(code + 8);
    // Relocate a NE branch whose original target is the taken result block.
    assert(vpRelocateConditionalBranch(0x54000081, destination - 16,
        destination - 28, destination - 12, code + 1) == 5);
    code[6] = 0xd2800160; // mov x0, #11 (not taken)
    code[7] = 0xd65f03c0; // ret
    code[8] = 0xd28002c0; // mov x0, #22 (taken)
    code[9] = 0xd65f03c0;
    assert(mprotect(code, size, PROT_READ | PROT_EXEC) == 0);
    sys_icache_invalidate(code, 40);
    unsigned long (*run)(unsigned long) = (void *)code;
    assert(run(0) == 11); assert(run(1) == 22);
    munmap(code, size);
#endif
    puts("Conditional branch relocation: forward/backward conditions, rejection boundaries and native taken/fallthrough passed");
}
