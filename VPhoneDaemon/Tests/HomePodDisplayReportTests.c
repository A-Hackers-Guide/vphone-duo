#include "../Native/vphoned_homepod_report.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    uint8_t report[245] = {2};
    assert(VPHomePodFrameSize(19, 1) == 127);
    assert(VPHomePodFrameSize(19, 2) == sizeof(report));
    assert(VPHomePodValidFrame(report, sizeof(report), 19, 2));
    assert(!VPHomePodValidFrame(report, sizeof(report) - 1, 19, 2));
    assert(!VPHomePodValidFrame(report, sizeof(report), 18, 2));
    assert(!VPHomePodValidFrame(report, sizeof(report), 19, 1));
    assert(!VPHomePodValidFrame(NULL, sizeof(report), 19, 2));
    report[0] = 1;
    assert(!VPHomePodValidFrame(report, sizeof(report), 19, 2));
    report[0] = 2;
    // Deliberately unaligned timestamp and channel words match the HID wire
    // layout, and catch accidental native struct alignment or endian changes.
    const uint8_t words[] = {0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef};
    for (size_t index = 0; index < sizeof(words); index++) report[index + 1] = words[index];
    report[9] = 0xff; report[10] = 0xff;
    report[11] = 0x00; report[12] = 0x80;
    report[13] = 0xff; report[14] = 0x0f;
    report[15] = 0x00; report[16] = 0x08;
    report[17] = 0x01; report[18] = 0x00;
    assert(VPHomePodRead64(report + 1) == UINT64_C(0xefcdab8967452301));
    assert(VPHomePodRead16(report + 9) == 65535);
    assert(VPHomePodRead16(report + 11) == 32768);
    assert(VPHomePodRead16(report + 13) == 4095);
    assert(VPHomePodRead16(report + 15) == 2048);
    assert(VPHomePodRead16(report + 17) == 1);
    assert(VPHomePodReadChannel(report + 9) == 1.0);
    assert(VPHomePodReadChannel(report + 13) == 4095.0 / 65535.0);
    const uint8_t liveWhite[] = {0x89, 0xbf};
    assert(VPHomePodReadChannel(liveWhite) == 49033.0 / 65535.0);
    assert(VPHomePodReadChannel(liveWhite) < 1.0);
    // Hardware version 3 has a second 118-byte display block; the timestamp
    // belongs to the whole report and is not repeated between displays.
    report[127] = 0x34; report[128] = 0x12;
    report[129] = 0x78; report[130] = 0x56;
    report[243] = 0xbc; report[244] = 0x0a;
    assert(VPHomePodRead16(report + 9 + (4 + 19 * 6)) == 0x1234);
    assert(VPHomePodRead16(report + 11 + (4 + 19 * 6)) == 0x5678);
    assert(VPHomePodRead16(report + 13 + (4 + 19 * 6) + 18 * 6 + 4) == 0x0abc);
    puts("HomePod MiniDisplay report tests passed");
    return 0;
}
