// VPVirtIOSoundRing.h — output ring between the HAL I/O thread and virtio.
//
// Three byte counters, each with one writer:
//
//     completed <= submitted <= written
//
// The real-time I/O thread appends mixed frames and advances `written`. The
// stream's serial queue hands `[submitted, written)` to the device and
// advances `submitted`, and advances `completed` when the device returns the
// bytes. Only `[written, completed + capacity)` may be overwritten: the
// kernel reads a submitted region from the caller's pages until it
// completes, so the space is not free before then.

#ifndef VPVirtIOSoundRing_h
#define VPVirtIOSoundRing_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint8_t *bytes;
    uint32_t capacity;
    uint32_t period;
    _Atomic uint64_t written;
    _Atomic uint64_t completed;
    uint64_t submitted;
} VPVirtIOSoundRing;

/// Allocate a page-aligned, zeroed ring. False when allocation fails or the
/// capacity is not a whole number of periods.
bool VPVirtIOSoundRingInit(VPVirtIOSoundRing *ring, uint32_t capacity, uint32_t period);
void VPVirtIOSoundRingDestroy(VPVirtIOSoundRing *ring);

/// Rewind every counter to zero. Only while nothing is in flight and the I/O
/// thread is not writing: when the device stream is about to be set up again.
void VPVirtIOSoundRingReset(VPVirtIOSoundRing *ring);

/// Append `length` bytes, all or none. Real-time safe. False, and nothing
/// written, when the free space is short: the device fell behind and these
/// frames are dropped rather than overwriting bytes still in flight.
bool VPVirtIOSoundRingWrite(VPVirtIOSoundRing *ring, const void *source, uint32_t length);

/// The next region to submit, contiguous in memory. Normally a whole period
/// or nothing; with `partial`, whatever is pending (used when the stream
/// stops, so its tail is not left behind). A region never crosses the end
/// of the buffer, so a pending range that wraps takes two calls.
bool VPVirtIOSoundRingNextSubmission(
    const VPVirtIOSoundRing *ring,
    bool partial,
    uint32_t *offset,
    uint32_t *length);

void VPVirtIOSoundRingDidSubmit(VPVirtIOSoundRing *ring, uint32_t length);
void VPVirtIOSoundRingDidComplete(VPVirtIOSoundRing *ring, uint32_t length);

/// Bytes handed to the device and not yet returned.
uint64_t VPVirtIOSoundRingInFlight(const VPVirtIOSoundRing *ring);

#endif /* VPVirtIOSoundRing_h */
