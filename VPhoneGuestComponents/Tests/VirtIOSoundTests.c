// VirtIOSoundTests.c — host checks for the virtio-snd HAL plugin's pure parts:
// the format the plugin asks the device for, and the output ring's counters.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "VPVirtIOSoundProtocol.h"
#include "VPVirtIOSoundRing.h"

static int failures;

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__,   \
                #condition);                                                   \
            failures++;                                                        \
        }                                                                      \
    } while (0)

// MARK: - Format choice

static VPVirtIOSoundPCMInfo info(uint64_t formats, uint64_t rates, uint8_t channels) {
    VPVirtIOSoundPCMInfo value;
    memset(&value, 0, sizeof(value));
    value.formats = formats;
    value.rates = rates;
    value.channelsMinimum = 1;
    value.channelsMaximum = channels;
    return value;
}

static void testPrefersFloat48k(void) {
    // What Virtualization.framework's VZHostAudioOutputStreamSink offers.
    VPVirtIOSoundPCMInfo device = info(1ULL << 19 | 1ULL << 5, 1ULL << 7 | 1ULL << 6, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.virtioFormat == kVPVirtIOSoundFormatFloat);
    CHECK(format.isFloat);
    CHECK(format.bitsPerChannel == 32);
    CHECK(format.virtioRate == 7);
    CHECK(format.sampleRate == 48000);
    CHECK(format.channels == 2);
    CHECK(format.bytesPerFrame == 8);
}

static void testFallsBackToInteger(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 5, 1ULL << 6, 1);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.virtioFormat == kVPVirtIOSoundFormatS16);
    CHECK(!format.isFloat);
    CHECK(format.sampleRate == 44100);
    CHECK(format.bytesPerFrame == 2);
}

static void testTakesHighestOtherRate(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 17, 1ULL << 3 | 1ULL << 10, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.sampleRate == 96000);
    CHECK(format.virtioRate == 10);
}

static void testRefusesUnusableDevice(void) {
    VPVirtIOSoundStreamFormat format;
    VPVirtIOSoundPCMInfo noFormat = info(1ULL << 3, 1ULL << 7, 2);
    CHECK(!VPVirtIOSoundChooseFormat(&noFormat, &format));
    VPVirtIOSoundPCMInfo noRate = info(1ULL << 19, 0, 2);
    CHECK(!VPVirtIOSoundChooseFormat(&noRate, &format));
    VPVirtIOSoundPCMInfo noChannels = info(1ULL << 19, 1ULL << 7, 0);
    CHECK(!VPVirtIOSoundChooseFormat(&noChannels, &format));
}

static void testSizesAndParameters(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 19, 1ULL << 7, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    uint32_t period = 0;
    uint32_t buffer = 0;
    // 48000 * 8 / 12 = 32000 bytes, rounded up to 16 KiB pages.
    VPVirtIOSoundBufferSizes(&format, 16384, &period, &buffer);
    CHECK(period == 32768);
    CHECK(buffer == 12 * 32768);
    VPVirtIOSoundPCMParameters parameters = VPVirtIOSoundParameters(&format, period, buffer);
    CHECK(parameters.code == 0);
    CHECK(parameters.streamID == 0);
    CHECK(parameters.bufferBytes == buffer);
    CHECK(parameters.periodBytes == period);
    CHECK(parameters.channels == 2);
    CHECK(parameters.format == kVPVirtIOSoundFormatFloat);
    CHECK(parameters.rate == 7);
}

// MARK: - Ring

static void fill(uint8_t *bytes, uint32_t length, uint8_t value) {
    memset(bytes, value, length);
}

static void testRingSubmitsWholePeriods(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t frames[96];
    fill(frames, sizeof(frames), 1);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, sizeof(frames)));

    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    CHECK(offset == 0 && length == 64);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    // 32 bytes pending: not a period yet.
    CHECK(!VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    // When the stream stops, the tail goes too.
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 64 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 96);
    VPVirtIOSoundRingDidComplete(&ring, 64);
    VPVirtIOSoundRingDidComplete(&ring, 32);
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 0);
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingKeepsInFlightBytes(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t frames[256];
    fill(frames, sizeof(frames), 2);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 256));
    // Full: submitting frees nothing, only completion does.
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 64));
    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 64));
    VPVirtIOSoundRingDidComplete(&ring, length);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 64));
    // All or nothing: 65 bytes do not fit in what is left.
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 65));
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingWrapsWritesAndSplitsSubmissions(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t first[224];
    fill(first, sizeof(first), 3);
    CHECK(VPVirtIOSoundRingWrite(&ring, first, sizeof(first)));
    uint32_t offset = 0;
    uint32_t length = 0;
    // Three whole periods, then the 32-byte tail at 192.
    for (int i = 0; i < 3; i++) {
        CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
        VPVirtIOSoundRingDidSubmit(&ring, length);
        VPVirtIOSoundRingDidComplete(&ring, length);
    }
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 192 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    VPVirtIOSoundRingDidComplete(&ring, length);

    // 64 bytes now start at 224 and wrap: 32 at the end, 32 at the front.
    uint8_t second[64];
    for (unsigned i = 0; i < sizeof(second); i++) {
        second[i] = (uint8_t)i;
    }
    CHECK(VPVirtIOSoundRingWrite(&ring, second, sizeof(second)));
    CHECK(memcmp(ring.bytes + 224, second, 32) == 0);
    CHECK(memcmp(ring.bytes, second + 32, 32) == 0);
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    CHECK(offset == 224 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 0 && length == 32);
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingResetAndValidation(void) {
    VPVirtIOSoundRing ring;
    CHECK(!VPVirtIOSoundRingInit(&ring, 100, 64));
    CHECK(!VPVirtIOSoundRingInit(&ring, 128, 0));
    CHECK(VPVirtIOSoundRingInit(&ring, 128, 64));
    uint8_t frames[64] = {0};
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 64));
    VPVirtIOSoundRingReset(&ring);
    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(!VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 0);
    VPVirtIOSoundRingDestroy(&ring);
}

int main(void) {
    testPrefersFloat48k();
    testFallsBackToInteger();
    testTakesHighestOtherRate();
    testRefusesUnusableDevice();
    testSizesAndParameters();
    testRingSubmitsWholePeriods();
    testRingKeepsInFlightBytes();
    testRingWrapsWritesAndSplitsSubmissions();
    testRingResetAndValidation();
    if (failures) {
        fprintf(stderr, "VirtIOSoundTests: %d failure(s)\n", failures);
        return 1;
    }
    printf("VirtIOSoundTests: all passed\n");
    return 0;
}
