// VPVirtIOSoundRing.c — see VPVirtIOSoundRing.h for the counter contract.

#include "VPVirtIOSoundRing.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

bool VPVirtIOSoundRingInit(VPVirtIOSoundRing *ring, uint32_t capacity, uint32_t period) {
    memset(ring, 0, sizeof(*ring));
    if (period == 0 || capacity == 0 || capacity % period != 0) {
        return false;
    }
    void *bytes = NULL;
    if (posix_memalign(&bytes, (size_t)getpagesize(), capacity) != 0) {
        return false;
    }
    memset(bytes, 0, capacity);
    ring->bytes = bytes;
    ring->capacity = capacity;
    ring->period = period;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->completed, 0);
    return true;
}

void VPVirtIOSoundRingDestroy(VPVirtIOSoundRing *ring) {
    free(ring->bytes);
    memset(ring, 0, sizeof(*ring));
}

void VPVirtIOSoundRingReset(VPVirtIOSoundRing *ring) {
    atomic_store_explicit(&ring->written, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->completed, 0, memory_order_relaxed);
    ring->submitted = 0;
}

/// Copies `length` bytes from `source`, or zeroes them when it is NULL.
static void copyInto(uint8_t *destination, const uint8_t *source, uint32_t length) {
    if (source) {
        memcpy(destination, source, length);
    } else {
        memset(destination, 0, length);
    }
}

static bool append(VPVirtIOSoundRing *ring, const uint8_t *source, uint32_t length) {
    if (length == 0) {
        return true;
    }
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t completed = atomic_load_explicit(&ring->completed, memory_order_acquire);
    if (length > ring->capacity - (written - completed)) {
        return false;
    }
    uint32_t offset = (uint32_t)(written % ring->capacity);
    uint32_t first = ring->capacity - offset;
    if (first >= length) {
        copyInto(ring->bytes + offset, source, length);
    } else {
        copyInto(ring->bytes + offset, source, first);
        copyInto(ring->bytes, source ? source + first : NULL, length - first);
    }
    atomic_store_explicit(&ring->written, written + length, memory_order_release);
    return true;
}

bool VPVirtIOSoundRingWrite(VPVirtIOSoundRing *ring, const void *source, uint32_t length) {
    return append(ring, source, length);
}

bool VPVirtIOSoundRingWriteSilence(VPVirtIOSoundRing *ring, uint32_t length) {
    return append(ring, NULL, length);
}

uint64_t VPVirtIOSoundRingQueued(const VPVirtIOSoundRing *ring) {
    return atomic_load_explicit(&ring->written, memory_order_relaxed)
        - atomic_load_explicit(&ring->completed, memory_order_acquire);
}

bool VPVirtIOSoundRingNextSubmission(
    const VPVirtIOSoundRing *ring,
    bool partial,
    uint32_t *offset,
    uint32_t *length) {
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint64_t pending = written - ring->submitted;
    if (pending == 0 || (!partial && pending < ring->period)) {
        return false;
    }
    uint32_t start = (uint32_t)(ring->submitted % ring->capacity);
    uint64_t size = partial && pending < ring->period ? pending : ring->period;
    if (size > ring->capacity - start) {
        size = ring->capacity - start;
    }
    *offset = start;
    *length = (uint32_t)size;
    return true;
}

void VPVirtIOSoundRingDidSubmit(VPVirtIOSoundRing *ring, uint32_t length) {
    ring->submitted += length;
}

void VPVirtIOSoundRingDidComplete(VPVirtIOSoundRing *ring, uint32_t length) {
    atomic_fetch_add_explicit(&ring->completed, length, memory_order_release);
}

uint64_t VPVirtIOSoundRingInFlight(const VPVirtIOSoundRing *ring) {
    return ring->submitted - atomic_load_explicit(&ring->completed, memory_order_acquire);
}
