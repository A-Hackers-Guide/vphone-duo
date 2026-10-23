#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// MiniDisplay's report 2: report ID, mach timestamp, then each display's +/-
// (16 bit) and interleaved RGB words in device tree coordinate order.
static inline uint16_t VPHomePodRead16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

// Peppy expands the physical MDBitDepth into kMDDisplayMaxBitDepth (16)
// before submitting its UInt16 channels. The DT's 12-bit value is not the
// captured output report's full-scale value.
static inline double VPHomePodReadChannel(const uint8_t *bytes) {
    return VPHomePodRead16(bytes) / 65535.0;
}

static inline uint32_t VPHomePodRead32(const uint8_t *bytes) {
    return (uint32_t)VPHomePodRead16(bytes) | ((uint32_t)VPHomePodRead16(bytes + 2) << 16);
}

static inline uint64_t VPHomePodRead64(const uint8_t *bytes) {
    return (uint64_t)VPHomePodRead32(bytes) | ((uint64_t)VPHomePodRead32(bytes + 4) << 32);
}

static inline size_t VPHomePodFrameSize(size_t ledCount, size_t displayCount) {
    return 9 + displayCount * (4 + ledCount * 6);
}

static inline bool VPHomePodValidFrame(const uint8_t *bytes, size_t length,
                                      size_t ledCount, size_t displayCount) {
    return bytes && length == VPHomePodFrameSize(ledCount, displayCount) && bytes[0] == 2;
}
