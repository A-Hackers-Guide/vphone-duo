// VPVirtIOSoundPlugin.m — CoreAudio HAL plugin for the VM's virtio-snd device.
//
// audiomxd loads this bundle from /System/Library/Audio/Plug-Ins/HAL when the
// kernel has published `AppleVirtIOSound` (Info.plist's loading condition).
// One HAL device is created per `AppleVirtIOSound` service, with one output
// stream per virtio-snd output stream. Input streams are left out: nothing
// in the guest needs the host microphone yet, and leaving them out keeps
// the host from opening it.
//
// The device clock (VPVirtIOSoundClock.h) is free running, anchored to
// mach_absolute_time when I/O starts, as the macOS plugin's is. The mixed
// output goes into a ring (see VPVirtIOSoundRing.h) and a timer hands it to
// the kernel a period at a time with the async write selector; the virtio
// device paces playback on the host.
//
// Optional settings in the `com.apple.coreaudio` preference domain, read
// once when audiomxd loads the plugin:
//   VPhoneVirtIOSoundTransportType  four-character transport ("usb ", "bltn")
//   VPhoneVirtIOSoundDeviceUID      HAL device UID (default "PuffinOutput" on
//                                   an iPad or iPhone guest,
//                                   "VPhoneVirtIOSound:0" elsewhere)
//   VPhoneVirtIOSoundNominalRate    44100 to start at the alternate rate
//   VPhoneVirtIOSoundLeadPeriods    periods of silence queued ahead of the
//                                   mix at each start, 0 to 8

#import "VPVirtIOSoundAudioServerDriver.h"

#include <IOKit/IOKitLib.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "VPVirtIOSoundClock.h"
#include "VPVirtIOSoundProtocol.h"
#include "VPVirtIOSoundRing.h"

// Newer CoreAudio spelling of element 0; both arms of the mute check accept
// the raw 0 regardless.
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain 0
#endif

// MARK: - Constants

/// The macOS plugin's timestamp period: 260 ms of frames.
static const double kTimestampPeriodSeconds = 0.26;
static const UInt32 kSafetyOffsetFrames = 100;
/// How often queued periods are handed to the device: 1/24 s, as the macOS
/// plugin flushes, a little under half a period.
static const uint64_t kFlushIntervalNanoseconds = NSEC_PER_SEC / 24;
static const uint32_t kAsyncReferenceCount = 3;

static CFStringRef const kSettingsDomain = CFSTR("com.apple.coreaudio");

/// The internal-speaker data source the macOS plugin selects for its output
/// ('ispk'; no SDK constant carries it).
static const UInt32 kVPDataSourceInternalSpeaker = 0x6973706b;

/// `kAudioDevicePropertyMute` ('mute'), which the trimmed iPhoneOS CoreAudio
/// headers leave out (AudioHardwareBase.h stops at the server-side set).
static const UInt32 kVPDevicePropertyMute = 0x6d757465;

/// `kAudioDevicePropertyNominalSampleRate` ('nsrt'), absent from the same
/// trimmed headers.
static const UInt32 kVPDevicePropertyNominalSampleRate = 0x6e737274;

/// The rate a ringtone-preview aggregate runs the vdef at. The virtio wire
/// itself only offers 48000, so the device advertises this rate beside it
/// and the mix converts into the wire rate.
static const double kVPAlternateRate = 44100;

static os_log_t VPLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.vphone.audio", "virtiosound");
    });
    return log;
}

// MARK: - Selector inventory

/// The guest's property vocabulary for this plugin, one line per distinct
/// (operation, selector, scope, element). A syslog capture during a session
/// activation then shows every selector VirtualAudio and the HAL server ask
/// the plugin's objects, which selectors they never ask, and in what order —
/// the inventory a missing-property hunt needs. Repeats are suppressed: the
/// first ask of a tuple logs, later ones only counted by the guest's own
/// noise.
///
/// Everything also lands in `/var/mobile/vpquery.log`: the 2.3.x guest
/// vphoned's syslog tail stopped delivering `com.vphone.audio` lines (the
/// 2.2.5-era tail carried them), and the inventory died with the channel.
/// The file is the reliable transport; each line carries a UTC wall-clock
/// stamp so its entries align with the first-party syslog captures that
/// still work, and a size cap keeps a runaway query loop from filling the
/// disk. audiomxd can write there (the session-4 reflection probe proved
/// the path with `/var/mobile/vpprobe.log`).
static void VPLogToFile(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void VPLogToFile(const char *format, ...) {
    static const char *kPath = "/var/mobile/vpquery.log";
    static const off_t kCap = 4 * 1024 * 1024;
    struct stat st;
    if (stat(kPath, &st) == 0 && st.st_size > kCap) {
        return;
    }
    FILE *file = fopen(kPath, "a");
    if (!file) {
        return;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm utc;
    gmtime_r(&now.tv_sec, &utc);
    va_list args;
    va_start(args, format);
    fprintf(file, "%02d:%02d:%02d.%03d ", utc.tm_hour, utc.tm_min, utc.tm_sec, now.tv_usec / 1000);
    vfprintf(file, format, args);
    fputc('\n', file);
    va_end(args);
    fclose(file);
}

/// Whether an image whose path contains `fragment` is mapped into audiomxd.
static BOOL VPImageLoaded(const char *fragment) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, fragment)) {
            return YES;
        }
    }
    return NO;
}

static NSString *VPFourCC(UInt32 code) {
    char text[5] = {
        (char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0,
    };
    return [NSString stringWithFormat:@"%s", text];
}

static void VPLogSelectorQuery(const char *operation, const AudioObjectPropertyAddress *address) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    NSString *key = [NSString stringWithFormat:@"%s:%u:%u:%u",
        operation, address->mSelector, address->mScope, address->mElement];
    @synchronized(seen) {
        if ([seen containsObject:key]) {
            return;
        }
        [seen addObject:key];
    }
    os_log(VPLog(), "query %{public}s: '%{public}@' / '%{public}@' / %u",
        operation, VPFourCC(address->mSelector), VPFourCC(address->mScope), address->mElement);
    VPLogToFile("query %s: '%s' / '%s' / %u",
        operation, VPFourCC(address->mSelector).UTF8String,
        VPFourCC(address->mScope).UTF8String, address->mElement);
}

// MARK: - Settings

static UInt32 VPTransportType(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundTransportType"), kSettingsDomain);
    UInt32 transport = kAudioDeviceTransportTypeUSB;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        char code[8] = {0};
        if (CFStringGetCString(value, code, sizeof(code), kCFStringEncodingASCII) && strlen(code) == 4) {
            transport = (UInt32)code[0] << 24 | (UInt32)code[1] << 16 | (UInt32)code[2] << 8 | (UInt32)code[3];
        }
    }
    if (value) {
        CFRelease(value);
    }
    return transport;
}

/// The guest's `hw.machine` ("iPad16,1"), read once; empty if unreadable.
static const char *VPMachine(void) {
    static char machine[64];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = sizeof(machine) - 1;
        if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0) {
            machine[0] = 0;
        }
    });
    return machine;
}

/// The ProductID VirtualAudio should route this guest with, or 0 for a guest
/// the speaker route has not been set up and verified on.
///
/// VirtualAudio derives its ProductID from a MobileGestalt class answer, and
/// vphone600 lands on a simulator class — 196 presenting an iPad, 195 an
/// iPhone — whose routing constructor skips the sub-port configurations the
/// real routes need: it throws (`RoutingSettings_J98.cpp:805`,
/// `RoutingSettings_N71.cpp:1167`), never initializes, and every session
/// gets "VirtualAudio PlugIn is not initialized yet" — no sound anywhere.
/// 8010 is the one accepted ID found whose category map also covers ringtone
/// previews, on both: an iPhone guest initializes with 8018, its own audio
/// node's acoustic ID, and plays Safari, but a tone's route change dies there
/// as it does with 198 on an iPad. Both defaults below key on this one
/// answer, so a guest gets either the whole route or none of it.
static int VPGuestProductID(void) {
    const char *machine = VPMachine();
    return strncmp(machine, "iPad", 4) == 0 || strncmp(machine, "iPhone", 6) == 0 ? 8010 : 0;
}

static NSString *VPDeviceUID(unsigned index) {
    NSString *uid = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundDeviceUID"), kSettingsDomain));
    if ([uid isKindOfClass:NSString.class] && uid.length > 0) {
        return index == 0 ? uid : [NSString stringWithFormat:@"%@:%u", uid, index];
    }
    // VirtualAudio builds a physical device, and a speaker port, only for the
    // UIDs its device factory knows. "PuffinOutput" is the built-in output of
    // Apple-silicon host audio, and the one such UID that publishes a routable
    // speaker; under any name of our own the device is claimed by nothing.
    // Only where the route is set up: a speaker route on a VirtualAudio that
    // was not deadlocked audiomxd and crash-looped it across launches.
    if (index == 0 && VPGuestProductID() != 0) {
        return @"PuffinOutput";
    }
    return [NSString stringWithFormat:@"VPhoneVirtIOSound:%u", index];
}

/// Gives VirtualAudio `VPGuestProductID()` through its own defaults key,
/// `ProductIDOverride` in `com.apple.audio.virtualaudio`, which it reads
/// before deriving one. This runs in audiomxd before VirtualAudio reads its
/// defaults, so the key is set here, in the process, on every launch that
/// finds none: audiomxd's sandbox keeps the write from reaching disk, and it
/// does not need to. A value someone stored (`settings.set`) is their choice
/// and stays.
///
/// Nothing guarantees that ordering, so the one line logged says what was
/// done and whether VirtualAudio was already mapped into audiomxd: one that
/// was not cannot have read its defaults yet; one that was may have.
static void VPEnsureVirtualAudioProduct(void) {
    BOOL virtualAudioLoaded = VPImageLoaded("/VirtualAudio.plugin/");
    NSString *outcome;
    int product = VPGuestProductID();
    if (product == 0) {
        outcome = @"no ProductID for this guest, left unset";
    } else {
        CFStringRef domain = CFSTR("com.apple.audio.virtualaudio");
        CFStringRef key = CFSTR("ProductIDOverride");
        id existing = CFBridgingRelease(CFPreferencesCopyAppValue(key, domain));
        if (existing) {
            outcome = [NSString stringWithFormat:@"stored %@, left as is", existing];
        } else {
            CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
            CFPreferencesSetAppValue(key, value, domain);
            CFRelease(value);
            outcome = [NSString stringWithFormat:@"unset, set to %d for this launch", product];
        }
    }
    const char *loaded = virtualAudioLoaded ? "already loaded" : "not loaded yet";
    os_log(VPLog(), "ProductIDOverride on '%{public}s': %{public}@; VirtualAudio %{public}s",
        VPMachine(), outcome, loaded);
    VPLogToFile("ProductIDOverride on '%s': %s; VirtualAudio %s", VPMachine(), outcome.UTF8String, loaded);
}

/// How many periods of silence go to the device before the mix at each start.
static const int kDefaultLeadPeriods = 2;
static const int kMaximumLeadPeriods = 8;

static uint32_t VPLeadPeriods(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundLeadPeriods"), kSettingsDomain);
    int periods = kDefaultLeadPeriods;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberIntType, &periods);
    }
    if (value) {
        CFRelease(value);
    }
    return (uint32_t)MAX(0, MIN(periods, kMaximumLeadPeriods));
}

/// The nominal rate the device boots with, for testing how VirtualAudio picks
/// aggregate members: a ringtone-preview vdef runs at 44100 and may require a
/// candidate's *current* nominal rate to match, not just advertised support.
/// 0 (or any unsupported value) leaves the wire rate as the nominal rate.
static double VPNominalRateOverride(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundNominalRate"), kSettingsDomain);
    double rate = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        double number = 0;
        if (CFNumberGetValue(value, kCFNumberDoubleType, &number) && number > 0) {
            rate = number;
        }
    }
    if (value) {
        CFRelease(value);
    }
    return rate;
}

// MARK: - Resampler

/// Linear-rate conversion of the HAL mix into the virtio wire rate. The
/// virtio stream always runs SET_PARAMS at 48000, but a ringtone-preview
/// aggregate runs the device at 44100; `writeMixBlock` then hands over
/// 44100-frame blocks that must become 48000 frames in the ring. Plain
/// linear interpolation is enough — a preview tone has no content near
/// Nyquist worth protecting.
typedef struct {
    /// The last input frame, the interpolation partner of the next block's
    /// first frame.
    float lastFrame[2];
    /// Where the next output frame falls between the previous and the
    /// current input frame, in input frames.
    double phase;
} VPResampler;

static void VPResamplerReset(VPResampler *resampler) {
    resampler->lastFrame[0] = 0;
    resampler->lastFrame[1] = 0;
    resampler->phase = 0;
}

/// Converts one interleaved stereo float block into `scratch`, returning the
/// output frame count. Outputs land `rateIn / rateOut` input frames apart,
/// so each input frame emits one or two.
static uint32_t VPResamplerProcess(VPResampler *resampler, const float *input, uint32_t inputFrames,
    double rateIn, double rateOut, float *scratch, uint32_t scratchFrames) {
    const double step = rateIn / rateOut;
    uint32_t outputFrames = 0;
    for (uint32_t i = 0; i < inputFrames; i++) {
        const float *current = input + i * 2;
        while (resampler->phase < 1.0 && outputFrames < scratchFrames) {
            float *output = scratch + outputFrames * 2;
            output[0] = resampler->lastFrame[0] + (current[0] - resampler->lastFrame[0]) * (float)resampler->phase;
            output[1] = resampler->lastFrame[1] + (current[1] - resampler->lastFrame[1]) * (float)resampler->phase;
            outputFrames++;
            resampler->phase += step;
        }
        resampler->phase -= 1.0;
        resampler->lastFrame[0] = current[0];
        resampler->lastFrame[1] = current[1];
    }
    return outputFrames;
}

/// Input frames per resampler pass; 512 in at 44100→48000 produces at most
/// 559 out, so a 1024-frame scratch bounds the allocation.
static const uint32_t kResampleChunkFrames = 512;
static const uint32_t kResampleScratchFrames = 1024;

/// What `writeMixBlock` captures instead of the stream object: the I/O
/// thread must not touch Objective-C, so it gets plain pointers that live as
/// long as the device.
typedef struct {
    VPVirtIOSoundRing *ring;
    _Atomic uint32_t *halRate;
    VPResampler *resampler;
    float *scratch;
    uint32_t bytesPerFrame;
    uint32_t wireRate;
    /// The lead, in bytes, that the first write after a start queues ahead
    /// of its frames. The stream's queue sets it at the start; the I/O thread
    /// takes it.
    _Atomic uint32_t leadRequest;
    /// Since the last start: frames the HAL handed over, bytes that went into
    /// the ring, bytes the ring refused because the device had not returned
    /// the space, and bytes of silence queued as the lead.
    _Atomic uint64_t framesIn;
    _Atomic uint64_t bytesOut;
    _Atomic uint64_t dropped;
    _Atomic uint64_t leadOut;
} VPMixState;

static void VPMixRingWrite(VPMixState *mix, const void *bytes, uint32_t length) {
    if (VPVirtIOSoundRingWrite(mix->ring, bytes, length)) {
        atomic_fetch_add_explicit(&mix->bytesOut, length, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&mix->dropped, length, memory_order_relaxed);
    }
}

/// Tops what is queued ahead of the host up to `lead` bytes, right before
/// the first frames of a run. From here on the mix arrives in real time, so
/// whatever is queued now is the cushion every later period is handed over
/// with — however long the HAL took to start its I/O after `startStream`.
/// What a draining run still has queued counts, except the oldest period in
/// flight: the host may have all but played it, and counting it whole left
/// restarts a period short.
static void VPMixQueueLead(VPMixState *mix, uint32_t lead) {
    uint64_t queued = VPVirtIOSoundRingQueued(mix->ring);
    uint64_t ahead = queued > mix->ring->period ? queued - mix->ring->period : 0;
    if (ahead >= lead) {
        return;
    }
    uint32_t silence = (uint32_t)(lead - ahead);
    if (VPVirtIOSoundRingWriteSilence(mix->ring, silence)) {
        atomic_fetch_add_explicit(&mix->leadOut, silence, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&mix->dropped, silence, memory_order_relaxed);
    }
}

static int VPMixWrite(VPMixState *mix, void *buffer, UInt32 frameCount) {
    uint32_t lead = atomic_exchange_explicit(&mix->leadRequest, 0, memory_order_acquire);
    if (lead > 0) {
        VPMixQueueLead(mix, lead);
    }
    atomic_fetch_add_explicit(&mix->framesIn, frameCount, memory_order_relaxed);
    uint32_t halRate = atomic_load(mix->halRate);
    if (halRate == mix->wireRate) {
        VPMixRingWrite(mix, buffer, frameCount * mix->bytesPerFrame);
        return kAudioHardwareNoError;
    }
    uint32_t done = 0;
    while (done < frameCount) {
        uint32_t chunk = frameCount - done;
        if (chunk > kResampleChunkFrames) {
            chunk = kResampleChunkFrames;
        }
        uint32_t converted = VPResamplerProcess(mix->resampler,
            (const float *)((uint8_t *)buffer + done * mix->bytesPerFrame), chunk,
            halRate, mix->wireRate, mix->scratch, kResampleScratchFrames);
        VPMixRingWrite(mix, mix->scratch, converted * mix->bytesPerFrame);
        done += chunk;
    }
    return kAudioHardwareNoError;
}

// MARK: - Stream

typedef NS_ENUM(NSInteger, VPStreamState) {
    /// The virtio stream is released; SET_PARAMS comes first.
    VPStreamStateIdle,
    /// Started on the device, and CoreAudio is writing.
    VPStreamStateRunning,
    /// CoreAudio stopped; the device stops once what it holds comes back.
    VPStreamStateDraining,
};

@interface VPVirtIOSoundStream : ASDStream
- (instancetype)initWithConnection:(io_connect_t)connection
                                   streamID:(uint32_t)streamID
                                     format:(VPVirtIOSoundStreamFormat)format
                                     plugin:(ASDPlugin *)plugin;
/// Frames, at the wire rate, between a write and the host playing it: the
/// lead queued ahead plus the period a write waits to fill.
@property (nonatomic, readonly) UInt32 queuedLatencyFrames;
- (void)transferCompletedWithLength:(uint32_t)length result:(IOReturn)result;
@end

/// The refcon of one async write.
typedef struct {
    void *stream;
    uint32_t length;
} VPTransfer;

static void VPWriteCompleted(void *refcon, IOReturn result, void **arguments, UInt32 argumentCount) {
    (void)arguments;
    (void)argumentCount;
    VPTransfer *transfer = refcon;
    VPVirtIOSoundStream *stream = (__bridge VPVirtIOSoundStream *)transfer->stream;
    uint32_t length = transfer->length;
    free(transfer);
    [stream transferCompletedWithLength:length result:result];
}

@implementation VPVirtIOSoundStream {
    io_connect_t _connection;
    uint32_t _streamID;
    VPVirtIOSoundStreamFormat _format;
    uint32_t _periodBytes;
    uint32_t _bufferBytes;
    VPVirtIOSoundRing _ring;
    dispatch_queue_t _queue;
    IONotificationPortRef _port;
    dispatch_source_t _timer;
    VPStreamState _state;
    BOOL _reportedTransferError;
    /// Periods of silence queued ahead of the mix at each device start.
    uint32_t _leadPeriods;
    /// Since the last start: when it was, what the device still held then,
    /// writes handed to the device, and how many of them found it with
    /// nothing left to play.
    uint64_t _startedAt;
    uint64_t _inFlightAtStart;
    uint64_t _submissions;
    uint64_t _starved;
    /// The fewest and most bytes in flight a write after the first found, for
    /// the run and for the minute `logProgress` last covered.
    uint64_t _minInFlight;
    uint64_t _maxInFlight;
    uint64_t _windowMinInFlight;
    uint64_t _windowMaxInFlight;
    uint64_t _reportedAt;
    /// The host's consumption once the run has settled: when the first write
    /// came back, the bytes returned after it, and when the last one did;
    /// and the longest wait between two returns.
    uint64_t _firstCompletedAt;
    uint64_t _lastCompletedAt;
    uint64_t _completedAfterFirst;
    uint64_t _maxCompletionGap;
    /// The rate CoreAudio runs the stream at, which is the wire rate until a
    /// 44100 aggregate switches the device. The mix block reads it, the rate
    /// change writes it, both lock-free.
    _Atomic uint32_t _halRate;
    VPResampler _resampler;
    float *_resampleScratch;
    VPMixState _mix;
}

/// ASDStream's `stopStream` releases every I/O block the stream holds and
/// `startStream` copies them again from the same properties, so a block set
/// once at init is gone after the first stop: the next start runs with no
/// write block and nothing reaches the ring. It goes back in before every
/// start. The I/O thread must not touch Objective-C or take locks, so the
/// block captures plain state; the stream lives as long as its device.
- (void)installMixBlock {
    VPMixState *mix = &_mix;
    self.writeMixBlock = ^int(UInt32 frameCount, const AudioServerPlugInIOCycleInfo *cycleInfo,
        void *mainBuffer, void *secondaryBuffer, UInt32 clientID) {
        (void)cycleInfo;
        (void)secondaryBuffer;
        (void)clientID;
        return VPMixWrite(mix, mainBuffer, frameCount);
    };
}

- (instancetype)initWithConnection:(io_connect_t)connection
                                   streamID:(uint32_t)streamID
                                     format:(VPVirtIOSoundStreamFormat)format
                                     plugin:(ASDPlugin *)plugin {
    self = [super initWithDirection:ASDStreamDirectionOutput withPlugin:plugin];
    if (!self) {
        return nil;
    }
    _connection = connection;
    _streamID = streamID;
    _format = format;
    // Returning nil from here releases self, so `dealloc` runs on whatever
    // was set up so far: it owns every release, and these branches only
    // return.
    VPVirtIOSoundBufferSizes(&format, (uint32_t)getpagesize(), &_periodBytes, &_bufferBytes);
    if (!VPVirtIOSoundRingInit(&_ring, _bufferBytes, _periodBytes)) {
        os_log_error(VPLog(), "stream %u: cannot allocate a %u-byte ring", streamID, _bufferBytes);
        return nil;
    }
    _queue = dispatch_queue_create("com.vphone.audio.virtiosound.stream", DISPATCH_QUEUE_SERIAL);
    _port = IONotificationPortCreate(kIOMainPortDefault);
    if (!_port) {
        return nil;
    }
    IONotificationPortSetDispatchQueue(_port, _queue);
    _leadPeriods = VPLeadPeriods();
    _resampleScratch = malloc(kResampleScratchFrames * format.bytesPerFrame);
    if (!_resampleScratch) {
        return nil;
    }

    AudioStreamBasicDescription description = {
        .mSampleRate = format.sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = (format.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = format.bytesPerFrame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = format.bytesPerFrame,
        .mChannelsPerFrame = format.channels,
        .mBitsPerChannel = format.bitsPerChannel,
    };
    ASDStreamFormat *physical = [[ASDStreamFormat alloc] initWithAudioStreamBasicDescription:description];
    physical.minimumSampleRate = format.sampleRate;
    physical.maximumSampleRate = format.sampleRate;
    self.streamName = @"Output Stream";
    self.physicalFormat = physical;
    self.physicalFormats = @[physical];
    double nominalRate = 0;
    // The 44100 twin: a ringtone-preview aggregate runs the vdef at 44100,
    // and the aggregate only carries devices that answer that rate. The
    // virtio stream itself stays at the wire rate; the mix resamples. The
    // current format follows the nominal-rate override so the device boots
    // already answering 44100, matching how the vdef composes.
    if (format.sampleRate == 48000.0) {
        AudioStreamBasicDescription alternate = description;
        alternate.mSampleRate = kVPAlternateRate;
        ASDStreamFormat *reduced = [[ASDStreamFormat alloc] initWithAudioStreamBasicDescription:alternate];
        reduced.minimumSampleRate = kVPAlternateRate;
        reduced.maximumSampleRate = kVPAlternateRate;
        self.physicalFormats = @[physical, reduced];
        self.physicalFormatSettable = YES;
        double override = VPNominalRateOverride();
        if (override == kVPAlternateRate) {
            nominalRate = override;
            self.physicalFormat = reduced;
        }
    }

    atomic_init(&_halRate, nominalRate > 0 ? (uint32_t)nominalRate : (uint32_t)format.sampleRate);
    VPResamplerReset(&_resampler);
    _mix = (VPMixState){
        .ring = &_ring,
        .halRate = &_halRate,
        .resampler = &_resampler,
        .scratch = _resampleScratch,
        .bytesPerFrame = format.bytesPerFrame,
        .wireRate = (uint32_t)format.sampleRate,
    };
    [self installMixBlock];
    os_log(VPLog(), "stream %u: %.0f Hz, %u channels, %u-bit %{public}s, period %u bytes",
        streamID, format.sampleRate, format.channels, format.bitsPerChannel,
        format.isFloat ? "float" : "integer", _periodBytes);
    VPLogToFile("stream %u: %.0f Hz, %u channels, %u-bit %s, period %u bytes, lead %u period(s)",
        streamID, format.sampleRate, format.channels, format.bitsPerChannel,
        format.isFloat ? "float" : "integer", _periodBytes, _leadPeriods);
    return self;
}

/// Also the cleanup of a failed init, so it takes any prefix of it: ivars
/// start zeroed, `free(NULL)` is a no-op, and a ring that `RingInit` refused
/// or never saw is zeroed, which `RingDestroy` frees as NULL.
- (void)dealloc {
    if (_timer) {
        dispatch_source_cancel(_timer);
    }
    if (_port) {
        IONotificationPortDestroy(_port);
    }
    free(_resampleScratch);
    VPVirtIOSoundRingDestroy(&_ring);
}

// MARK: Rate changes

- (void)deviceChangedToSamplingRate:(double)rate {
    os_log(VPLog(), "rate-probe: stream %u deviceChangedToSamplingRate %.0f (hal %.0f, format %.0f)",
        _streamID, rate, (double)atomic_load(&_halRate), self.physicalFormat.sampleRate);
    VPLogToFile("rate-probe: stream %u deviceChangedToSamplingRate %.0f (hal %.0f, format %.0f)",
        _streamID, rate, (double)atomic_load(&_halRate), self.physicalFormat.sampleRate);
    [super deviceChangedToSamplingRate:rate];
    uint32_t previous = atomic_load(&_halRate);
    if (rate > 0 && (uint32_t)rate != previous) {
        atomic_store(&_halRate, (uint32_t)rate);
        VPResamplerReset(&_resampler);
        os_log(VPLog(), "stream %u: device rate %.0f -> %.0f, physical format %.0f Hz",
            _streamID, (double)previous, rate, self.physicalFormat.sampleRate);
    }
}

// MARK: Property inventory

// The same five entry points as the device's below, logging what the stream
// object itself is asked (its physical formats and layouts mostly) before
// ASDStream answers.

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("stream-has", address);
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("stream-settable", address);
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("stream-size", address);
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                       andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("stream-get", address);
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("stream-set", address);
    return [super setProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

// MARK: Device commands

- (kern_return_t)callSelector:(uint32_t)selector {
    uint64_t scalar = _streamID;
    kern_return_t result = IOConnectCallScalarMethod(_connection, selector, &scalar, 1, NULL, NULL);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "stream %u: selector %u failed: 0x%x", _streamID, selector, result);
    }
    return result;
}

- (BOOL)startDevice {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundRingReset(&_ring);
    VPVirtIOSoundPCMParameters parameters = VPVirtIOSoundParameters(&_format, _periodBytes, _bufferBytes);
    uint64_t scalar = _streamID;
    kern_return_t result = IOConnectCallMethod(_connection, kVPVirtIOSoundSelectorSetParameters,
        &scalar, 1, &parameters, sizeof(parameters), NULL, NULL, NULL, NULL);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "stream %u: SET_PARAMS failed: 0x%x", _streamID, result);
        return NO;
    }
    if ([self callSelector:kVPVirtIOSoundSelectorPrepare] != KERN_SUCCESS) {
        [self callSelector:kVPVirtIOSoundSelectorRelease];
        return NO;
    }
    if ([self callSelector:kVPVirtIOSoundSelectorStart] != KERN_SUCCESS) {
        [self callSelector:kVPVirtIOSoundSelectorRelease];
        return NO;
    }
    _reportedTransferError = NO;
    return YES;
}

/// The device plays what it is handed as it arrives and the mix arrives in
/// real time, so with nothing queued ahead every late period is a gap on the
/// host: measured, a third to a half of all writes found the device with
/// nothing left to play. A few periods of silence first put that much audio
/// between the guest's writes and the host's playback. The I/O thread queues
/// them itself, ahead of its first write (`VPMixQueueLead`): only then is it
/// known what a draining run still holds and how long the HAL took to start,
/// and `written` keeps its one writer.
- (void)queueLead {
    dispatch_assert_queue(_queue);
    atomic_store_explicit(&_mix.leadRequest, _leadPeriods * _periodBytes, memory_order_release);
}

- (UInt32)queuedLatencyFrames {
    return (_leadPeriods + 1) * (_periodBytes / _format.bytesPerFrame);
}

// MARK: Counters

- (void)resetCounters {
    dispatch_assert_queue(_queue);
    _startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _reportedAt = _startedAt;
    _inFlightAtStart = VPVirtIOSoundRingInFlight(&_ring);
    _submissions = 0;
    _starved = 0;
    _minInFlight = UINT64_MAX;
    _maxInFlight = 0;
    _windowMinInFlight = UINT64_MAX;
    _windowMaxInFlight = 0;
    _firstCompletedAt = 0;
    // A draining run's returns carry on into this one, so a gap between its
    // tail and this run's lead still shows.
    if (_inFlightAtStart == 0) {
        _lastCompletedAt = 0;
    }
    _completedAfterFirst = 0;
    _maxCompletionGap = 0;
    atomic_store(&_mix.framesIn, 0);
    atomic_store(&_mix.bytesOut, 0);
    atomic_store(&_mix.dropped, 0);
    atomic_store(&_mix.leadOut, 0);
}

- (double)periodsForBytes:(uint64_t)bytes {
    return bytes == UINT64_MAX ? 0 : (double)bytes / _periodBytes;
}

/// Wire frames a second the host has played since the run settled, from the
/// device's completions. The mix arrives at the wire rate of the guest's
/// clock, so against it this is how far the host's audio clock runs from
/// the guest's, and how fast the cushion would erode or grow.
- (double)hostRate {
    if (_firstCompletedAt == 0 || _lastCompletedAt <= _firstCompletedAt) {
        return 0;
    }
    return (double)_completedAfterFirst / _format.bytesPerFrame / ((_lastCompletedAt - _firstCompletedAt) / 1e9);
}

- (double)hostDriftPPM {
    double rate = self.hostRate;
    return rate > 0 ? (rate / _format.sampleRate - 1) * 1e6 : 0;
}

/// One line per run of the device, for telling a gap on the host (`starved`)
/// from an unhappy HAL clock (`in` far from the nominal rate) from a full
/// ring (`dropped`). `start` is what a draining run still held when this one
/// started, `lead` the silence queued ahead of it, `in flight` the cushion
/// writes after the first found (whole periods: the device returns whole
/// writes, each a period after the last while it plays), `host` the rate
/// the device played at, and `returns` the longest wait between two returns,
/// which a stall on either side stretches.
- (void)logCounters {
    double seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _startedAt) / 1e9;
    uint64_t framesIn = atomic_load(&_mix.framesIn);
    uint64_t framesOut = atomic_load(&_mix.bytesOut) / _format.bytesPerFrame;
    VPLogToFile("stream %u: %.2f s, %llu writes, %llu starved, %llu bytes dropped, "
        "in %llu frames (%.0f/s, hal %u), out %llu frames (%.0f/s); "
        "start %.2f, lead %.2f, in flight %.2f-%.2f periods; host %.1f/s (%+.0f ppm), returns <= %.0f ms apart",
        _streamID, seconds, (unsigned long long)_submissions, (unsigned long long)_starved,
        (unsigned long long)atomic_load(&_mix.dropped),
        (unsigned long long)framesIn, seconds > 0 ? framesIn / seconds : 0, atomic_load(&_halRate),
        (unsigned long long)framesOut, seconds > 0 ? framesOut / seconds : 0,
        [self periodsForBytes:_inFlightAtStart], [self periodsForBytes:atomic_load(&_mix.leadOut)],
        [self periodsForBytes:_minInFlight], [self periodsForBytes:_maxInFlight],
        self.hostRate, self.hostDriftPPM, _maxCompletionGap / 1e6);
}

/// A line a minute while the device runs, so a long playback shows whether
/// the cushion holds.
- (void)logProgress {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - _reportedAt < 60 * NSEC_PER_SEC) {
        return;
    }
    VPLogToFile("stream %u: running %.0f s, %llu writes, %llu starved, in flight %.2f-%.2f periods "
        "this minute; host %.1f/s (%+.0f ppm)",
        _streamID, (now - _startedAt) / 1e9, (unsigned long long)_submissions, (unsigned long long)_starved,
        [self periodsForBytes:_windowMinInFlight], [self periodsForBytes:_windowMaxInFlight],
        self.hostRate, self.hostDriftPPM);
    _reportedAt = now;
    _windowMinInFlight = UINT64_MAX;
    _windowMaxInFlight = 0;
}

- (void)stopDevice {
    dispatch_assert_queue(_queue);
    [self callSelector:kVPVirtIOSoundSelectorStop];
    [self callSelector:kVPVirtIOSoundSelectorRelease];
    _state = VPStreamStateIdle;
}

// MARK: Transfers

- (void)submitPending:(BOOL)partial {
    dispatch_assert_queue(_queue);
    mach_port_t wakePort = IONotificationPortGetMachPort(_port);
    uint32_t offset = 0;
    uint32_t length = 0;
    while (VPVirtIOSoundRingNextSubmission(&_ring, partial, &offset, &length)) {
        VPTransfer *transfer = malloc(sizeof(*transfer));
        if (!transfer) {
            return;
        }
        transfer->stream = (__bridge void *)self;
        transfer->length = length;
        uint64_t reference[kOSAsyncRef64Count] = {0};
        reference[kIOAsyncCalloutFuncIndex] = (uint64_t)(uintptr_t)VPWriteCompleted;
        reference[kIOAsyncCalloutRefconIndex] = (uint64_t)(uintptr_t)transfer;
        uint64_t scalar = _streamID;
        // Nothing in flight when a period goes out means the device already
        // played everything it had: a gap on the host.
        uint64_t inFlight = VPVirtIOSoundRingInFlight(&_ring);
        if (_submissions > 0) {
            if (inFlight == 0) {
                _starved++;
            }
            _minInFlight = MIN(_minInFlight, inFlight);
            _maxInFlight = MAX(_maxInFlight, inFlight);
            _windowMinInFlight = MIN(_windowMinInFlight, inFlight);
            _windowMaxInFlight = MAX(_windowMaxInFlight, inFlight);
        }
        _submissions++;
        VPVirtIOSoundRingDidSubmit(&_ring, length);
        kern_return_t result = IOConnectCallAsyncMethod(_connection, kVPVirtIOSoundSelectorWrite, wakePort,
            reference, kAsyncReferenceCount, &scalar, 1, _ring.bytes + offset, length, NULL, NULL, NULL, NULL);
        if (result != KERN_SUCCESS) {
            // Nothing will complete this one, so return its space now.
            free(transfer);
            [self transferCompletedWithLength:length result:result];
        }
    }
}

- (void)transferCompletedWithLength:(uint32_t)length result:(IOReturn)result {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundRingDidComplete(&_ring, length);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (_lastCompletedAt > 0) {
        uint64_t gap = now - _lastCompletedAt;
        _maxCompletionGap = MAX(_maxCompletionGap, gap);
    }
    _lastCompletedAt = now;
    // The host's rate counts once the run has settled: its first returns
    // follow the start, a draining run's tail and the host's own buffering.
    if (now - _startedAt >= 5 * NSEC_PER_SEC) {
        if (_firstCompletedAt == 0) {
            _firstCompletedAt = now;
        } else {
            _completedAfterFirst += length;
        }
    }
    if (result != kIOReturnSuccess && !_reportedTransferError) {
        _reportedTransferError = YES;
        os_log_error(VPLog(), "stream %u: write of %u bytes failed: 0x%x", _streamID, length, result);
    }
    if (_state == VPStreamStateDraining && VPVirtIOSoundRingInFlight(&_ring) == 0) {
        [self stopDevice];
    }
}

// MARK: ASDStream

- (void)startStream {
    dispatch_sync(_queue, ^{
        if (self->_state == VPStreamStateIdle && ![self startDevice]) {
            return;
        }
        if (self->_state != VPStreamStateRunning) {
            [self resetCounters];
            [self queueLead];
        }
        self->_state = VPStreamStateRunning;
    });
    if (!_timer) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, kFlushIntervalNanoseconds),
            kFlushIntervalNanoseconds, kFlushIntervalNanoseconds / 10);
        __unsafe_unretained VPVirtIOSoundStream *unretained = self;
        dispatch_source_set_event_handler(_timer, ^{
            if (unretained->_state == VPStreamStateRunning) {
                [unretained submitPending:NO];
                [unretained logProgress];
            }
        });
        dispatch_resume(_timer);
    }
    [self installMixBlock];
    [super startStream];
}

- (void)stopStream {
    dispatch_sync(_queue, ^{
        if (self->_state != VPStreamStateRunning) {
            return;
        }
        [self logCounters];
        // A start the HAL never wrote after leaves no lead behind.
        atomic_store(&self->_mix.leadRequest, 0);
        [self submitPending:YES];
        self->_state = VPStreamStateDraining;
        if (VPVirtIOSoundRingInFlight(&self->_ring) == 0) {
            [self stopDevice];
        }
    });
    [super stopStream];
}

@end

// MARK: - Device

@interface VPVirtIOSoundDevice : ASDAudioDevice
- (instancetype)initWithService:(io_service_t)service index:(unsigned)index plugin:(ASDPlugin *)plugin;
- (void)addSpeakerControls;
@end

@implementation VPVirtIOSoundDevice {
    io_service_t _service;
    io_connect_t _connection;
    VPVirtIOSoundClock _clock;
    /// The virtio wire rate, the only rate the device actually runs at.
    double _wireRate;
    /// The second advertised rate, or 0 when the wire rate leaves nothing to
    /// convert (44100 beside 48000).
    double _alternateRate;
    /// The nominal rate the clock last ran, so a re-set of the current rate
    /// does not re-anchor it.
    double _clockRate;
    /// The mute control `addSpeakerControls` registered, for the device-level
    /// mute selector's forwarding below.
    ASDBooleanControl *_muteControl;
    /// The mute state the device-level selector answers; shadowed beside the
    /// control because the control's own value is only reachable through its
    /// 'bcvl' property, whose getter shape the guest ASD does not publish.
    UInt32 _muteState;
}

static uint32_t VPStreamCount(io_service_t service) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, CFSTR(kVPVirtIOSoundStreamCountKey), kCFAllocatorDefault, 0);
    uint32_t count = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &count);
    }
    if (value) {
        CFRelease(value);
    }
    return count;
}

- (instancetype)initWithService:(io_service_t)service index:(unsigned)index plugin:(ASDPlugin *)plugin {
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "cannot open AppleVirtIOSound: 0x%x", result);
        return nil;
    }
    // The connection is this method's to close until the ivars hold it; from
    // there `dealloc` releases both, including for the nil return below.
    self = [super initWithDeviceUID:VPDeviceUID(index) withPlugin:plugin];
    if (!self) {
        IOServiceClose(connection);
        return nil;
    }
    IOObjectRetain(service);
    _service = service;
    _connection = connection;

    double sampleRate = 0;
    UInt32 latencyFrames = 0;
    uint32_t count = VPStreamCount(service);
    for (uint32_t streamID = 0; streamID < count; streamID++) {
        VPVirtIOSoundPCMInfo info = {0};
        uint64_t scalar = streamID;
        size_t size = sizeof(info);
        result = IOConnectCallMethod(connection, kVPVirtIOSoundSelectorPCMInfo,
            &scalar, 1, NULL, 0, NULL, NULL, &info, &size);
        if (result != KERN_SUCCESS || size != sizeof(info)) {
            os_log_error(VPLog(), "stream %u: PCM_INFO failed: 0x%x", streamID, result);
            continue;
        }
        if (info.direction != kVPVirtIOSoundDirectionOutput) {
            continue;
        }
        VPVirtIOSoundStreamFormat format;
        if (!VPVirtIOSoundChooseFormat(&info, &format)) {
            os_log_error(VPLog(), "stream %u: no usable format (formats 0x%llx, rates 0x%llx)",
                streamID, info.formats, info.rates);
            continue;
        }
        // One device has one clock, so every stream must share its rate.
        if (sampleRate != 0 && format.sampleRate != sampleRate) {
            continue;
        }
        VPVirtIOSoundStream *stream = [[VPVirtIOSoundStream alloc] initWithConnection:connection
                                                                             streamID:streamID
                                                                               format:format
                                                                               plugin:plugin];
        if (!stream) {
            continue;
        }
        sampleRate = format.sampleRate;
        latencyFrames = stream.queuedLatencyFrames;
        [self addOutputStream:stream];
    }
    if (sampleRate == 0) {
        os_log_error(VPLog(), "AppleVirtIOSound has no usable output stream among %u", count);
        return nil;
    }

    _wireRate = sampleRate;
    _alternateRate = sampleRate == 48000.0 ? kVPAlternateRate : 0;
    // The nominal rate the device answers at boot: the wire rate unless the
    // override names the alternate (testing VirtualAudio's aggregate-member
    // selection, which may compare the current nominal rate, not the list).
    double nominalRate = sampleRate;
    double override = VPNominalRateOverride();
    if (_alternateRate > 0 && override == _alternateRate) {
        nominalRate = _alternateRate;
    }
    // The period is fixed at `kTimestampPeriodSeconds` of the rate the device
    // starts at, and published below as its timestamp period.
    VPVirtIOSoundClockConfigure(&_clock, (uint32_t)(nominalRate * kTimestampPeriodSeconds), nominalRate,
        mach_absolute_time());
    _clockRate = nominalRate;
    self.deviceName = @"vphone Speaker";
    self.modelName = @"Virtual Sound Device";
    self.manufacturerName = @"vphone";
    self.canBeDefaultOutputDevice = YES;
    self.canBeDefaultSystemDevice = YES;
    self.canBeDefaultInputDevice = NO;
    self.canChangeDeviceName = NO;
    self.samplingRates = _alternateRate ? @[@(_alternateRate), @(sampleRate)] : @[@(sampleRate)];
    self.samplingRate = nominalRate;
    self.outputSafetyOffset = kSafetyOffsetFrames;
    // What the stream queues ahead of the host, so the HAL presents video
    // against when the sound is heard, not when it is written. Set once, in
    // frames of the rate the device starts at, so after a rate change it is
    // off by the ratio of the rates.
    self.outputLatency = (UInt32)(latencyFrames * nominalRate / sampleRate);
    self.transportType = VPTransportType();
    self.timestampPeriod = _clock.periodFrames;

    [self installIOBlocks];
    UInt32 transport = self.transportType;
    os_log(VPLog(), "device %{public}@: %.0f Hz nominal (%.0f wire, %.0f advertised too), transport '%c%c%c%c'",
        VPDeviceUID(index), nominalRate, sampleRate, _alternateRate,
        (char)(transport >> 24), (char)(transport >> 16), (char)(transport >> 8), (char)transport);
    VPLogToFile("device %s: %.0f Hz nominal (%.0f wire, %.0f advertised too), transport '%c%c%c%c'",
        VPDeviceUID(index).UTF8String, nominalRate, sampleRate, _alternateRate,
        (char)(transport >> 24), (char)(transport >> 16), (char)(transport >> 8), (char)transport);
    return self;
}

- (void)dealloc {
    if (_connection) {
        IOServiceClose(_connection);
    }
    if (_service) {
        IOObjectRelease(_service);
    }
}

/// ASDAudioDevice's `performStopIO` releases every I/O block the device holds
/// (and clears the unretained copies the I/O thread calls), and
/// `performStartIO` copies them again from the same properties. Blocks set
/// once at init therefore survive exactly one start: after the first stop
/// the device has no zero-timestamp block, the HAL reads "Device … is not
/// running", waits five seconds for a timeline and fails the start — every
/// start after the first. They go back in before every start.
- (void)installIOBlocks {
    VPVirtIOSoundClock *clock = &_clock;
    self.getZeroTimestampBlock = ^int(Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed, UInt32 clientID) {
        (void)clientID;
        // False only when anchors kept landing through every read attempt;
        // no timestamp beats one built from two timelines.
        return VPVirtIOSoundClockZeroTimestamp(clock, mach_absolute_time(), sampleTime, hostTime, seed)
            ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
    };
    self.willDoReadInputBlock = ^int(UInt32 operationID, Boolean *willDo, Boolean *willDoInPlace) {
        (void)operationID;
        *willDo = false;
        *willDoInPlace = true;
        return kAudioHardwareNoError;
    };
    self.willDoWriteMixBlock = ^int(UInt32 operationID, Boolean *willDo, Boolean *willDoInPlace) {
        (void)operationID;
        *willDo = true;
        *willDoInPlace = true;
        return kAudioHardwareNoError;
    };
}

- (int)performStartIO {
    [self installIOBlocks];
    int result = [super performStartIO];
    if (result == kAudioHardwareNoError) {
        VPVirtIOSoundClockAnchor(&_clock, mach_absolute_time());
    }
    return result;
}

// MARK: Rate changes

- (BOOL)supportsSamplingRate:(double)rate {
    BOOL supported = rate == _wireRate || (_alternateRate > 0 && rate == _alternateRate);
    os_log(VPLog(), "rate-probe: supportsSamplingRate %.0f -> %{public}s",
        rate, supported ? "yes" : "no");
    VPLogToFile("rate-probe: supportsSamplingRate %.0f -> %s", rate, supported ? "yes" : "no");
    return supported;
}

/// The virtio stream keeps SET_PARAMS at the wire rate whatever the HAL
/// runs; only the clock's period math and the mix's input rate follow the
/// nominal rate, and the streams hear about it from `super` before the
/// clock moves.
- (void)setSamplingRate:(double)rate {
    os_log(VPLog(), "rate-probe: setSamplingRate %.0f (clock %.0f)", rate, _clockRate);
    VPLogToFile("rate-probe: setSamplingRate %.0f (clock %.0f)", rate, _clockRate);
    [super setSamplingRate:rate];
    if (rate > 0 && [self supportsSamplingRate:rate] && rate != _clockRate) {
        _clockRate = rate;
        VPVirtIOSoundClockSetRate(&_clock, rate, mach_absolute_time());
        os_log(VPLog(), "nominal rate -> %.0f Hz", rate);
    }
}

// MARK: Device-level properties

/// VirtualAudio's route code asks the device itself for
/// `kAudioDevicePropertyMute` (scope 'outp', element 0) while establishing
/// the pspk route — Device_HAL_Common's unmute, then a read-back. The iOS
/// ASDAudioDevice's property dispatch has no 'mute' case at all (the
/// disassembly of the guest's AudioServerDriver contains the FourCharCode in
/// exactly two places, both inside ASDBooleanControl's control-level code,
/// none in ASDAudioDevice's selector trees), and the HAL server answers the
/// set 'what' at HALS_UCPlugIn.cpp:1190 without ever forwarding the selector
/// here — a guest probe saw these overrides dispatch for every selector but
/// 'mute'. The route's throw that follows is quieted host-side, in the
/// VirtualAudio binary patch; this dispatch stays as macOS's ASD carries it,
/// with the mute control this device registered as the backing store, for
/// the build that does forward.
static BOOL VPIsDeviceMuteAddress(const AudioObjectPropertyAddress *address) {
    return address->mSelector == kVPDevicePropertyMute
        && (address->mScope == kAudioObjectPropertyScopeOutput
            || address->mScope == kAudioObjectPropertyScopeGlobal)
        && (address->mElement == kAudioObjectPropertyElementMain
            || address->mElement == 0);
}

/// `kAudioDevicePropertyNominalSampleRate` is a global-scope, main-element
/// property ('nsrt'/glob/0). A device-level mute address check accepts the
/// output scope as well; the rate has no per-scope form, so global only.
static BOOL VPIsDeviceRateAddress(const AudioObjectPropertyAddress *address) {
    return address->mSelector == kVPDevicePropertyNominalSampleRate
        && address->mScope == kAudioObjectPropertyScopeGlobal
        && (address->mElement == kAudioObjectPropertyElementMain
            || address->mElement == 0);
}

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("has", address);
    if (VPIsDeviceMuteAddress(address)) {
        return YES;
    }
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("settable", address);
    if (VPIsDeviceMuteAddress(address) || VPIsDeviceRateAddress(address)) {
        return YES;
    }
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("size", address);
    if (VPIsDeviceMuteAddress(address)) {
        return sizeof(UInt32);
    }
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                     andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("get", address);
    if (VPIsDeviceMuteAddress(address)) {
        if (dataSize == NULL || *dataSize < sizeof(UInt32)) {
            return NO;
        }
        *(UInt32 *)data = _muteState;
        *dataSize = sizeof(UInt32);
        return YES;
    }
    if (VPIsDeviceRateAddress(address)) {
        if (dataSize == NULL || *dataSize < sizeof(double) || data == NULL) {
            return NO;
        }
        *(double *)data = _clockRate;
        *dataSize = sizeof(double);
        return YES;
    }
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

/// The rate set the route code's "Synchronously setting sample rate" runs
/// into. ASDAudioDevice's own `setProperty:` 'nsrt' case checks
/// `supportsSamplingRate:` (that call reaches the plugin — the rate-probe
/// log shows it answering) and then hands the change to a second internal
/// gate whose tail call returns NO for a plugin device; the C-op layer maps
/// that NO to 'what' at HALS_UCPlugIn.cpp:1190, the set "Gives up", and a
/// 44100 session finds no device at its rate ("No audio device is
/// available"). The commit the gate would perform lives in
/// `setSamplingRate:` — disassembled, that method logs, then dispatches a
/// block that stores the rate and fans it out to every stream — so the
/// device performs the change itself here, through its own override, and
/// answers YES.
- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("set", address);
    if (VPIsDeviceMuteAddress(address)) {
        if (dataSize < sizeof(UInt32) || data == NULL) {
            return NO;
        }
        _muteState = (*(const UInt32 *)data != 0);
        [_muteControl setValue:_muteState];
        return YES;
    }
    if (VPIsDeviceRateAddress(address)) {
        if (dataSize < sizeof(double) || data == NULL) {
            return NO;
        }
        double rate = *(const double *)data;
        if (rate <= 0 || ![self supportsSamplingRate:rate]) {
            return NO;
        }
        [self setSamplingRate:rate];
        return YES;
    }
    return [super setProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

// MARK: Controls

- (void)addSpeakerControls {
    // The control set a real speaker answers with: one selected data-source
    // value ('ispk', "Speakers"), then mute and volume, all on the master
    // element of the output scope. Mirrored argument for argument from the
    // macOS plugin, which adds these from its own
    // `halInitializeWithPluginHost:` — after the device is built, before it
    // is registered — and never from inside the device's init: calling
    // `addControl:` during `initWithService:` fails the whole device
    // activation (HALS_PlugIn.cpp:162). The pspk route runs in HardwareOnly
    // volume mode and reads this control set; without it every volume query
    // on the route fails and the endpoint is retyped "Unspecified" after
    // the first playback, silencing every later one.
    ASDSelectorValue *speakers = [[ASDSelectorValue alloc] init];
    [speakers setValue:kVPDataSourceInternalSpeaker];
    [speakers setName:@"Speakers"];
    ASDSelectorControl *dataSource = [[ASDSelectorControl alloc]
        initWithIsSettable:YES
                forElement:0
                  inScope:ASDStreamDirectionOutput
                withPlugin:self.plugin
         andObjectClassID:kAudioDataSourceControlClassID];
    [dataSource addValue:speakers];
    [dataSource setSelectedValues:@[speakers]];
    [self addControl:dataSource];

    // The macOS plugin's `-[AVIODevice _addMuteAndVolumeControlsInScope:]`
    // argument-for-argument: mute off, volume at -30 dB in a [-60, 0] dB
    // range pushed to its maximum, both settable. But not through its
    // factories: on the guest ASD those are state-dependent — runs where
    // they returned real controls still failed VirtualAudio's route unmute
    // with 'what' (a factory mute control does not answer
    // kAudioDevicePropertyMute), and later runs crashed audiomxd outright
    // when the volume factory's return value was the raw FourCharCode
    // 'togl', release-faulted in this function's epilogue (audiomxd-*.ips;
    // successive-crash loops in launchd). The explicit-class initializers
    // construct controls deterministically — a guest-side reflection probe
    // confirmed both initializers return real ASD controls — so pin the
    // class IDs the way the data-source control above pins 'dsrc'.
    ASDPlugin *plugin = self.plugin;
    ASDBooleanControl *mute = [[ASDBooleanControl alloc] initWithValue:NO
        isSettable:YES forElement:0 inScope:ASDStreamDirectionOutput
        withPlugin:plugin andObjectClassID:kAudioMuteControlClassID];
    ASDLevelControl *volume = [[ASDLevelControl alloc] initWithDecibelValue:-30.0
        minimumValue:-60.0 maximumValue:0.0 isSettable:YES
        forElement:0 inScope:ASDStreamDirectionOutput
        withPlugin:plugin andObjectClassID:kAudioVolumeControlClassID];
    [self addControl:mute];
    [self addControl:volume];
    [mute setValue:0];
    [volume setDecibelValue:volume.maximumDecibelValue];
    _muteControl = mute;
    _muteState = 0;
    os_log(VPLog(), "speaker controls added: dsrc 'ispk', mute, volume");
    VPLogToFile("speaker controls added: dsrc 'ispk', mute, volume");
}

@end

// MARK: - Plugin

@interface VPVirtIOSoundPlugin : ASDPlugin
@end

@implementation VPVirtIOSoundPlugin

// The plugin object (not a device) answers its own selectors — the box-level
// queries the HAL server makes while enumerating plugins. Logged the same way
// so the inventory covers every object this bundle publishes.

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("plugin-has", address);
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("plugin-settable", address);
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("plugin-size", address);
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                       andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("plugin-get", address);
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("plugin-set", address);
    return [super setProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (void)halInitializeWithPluginHost:(AudioServerPlugInHostRef)host {
    [super halInitializeWithPluginHost:host];
    // First, so this launch's ProductIDOverride, device and stream lines
    // follow it in the file rather than precede it.
    VPLogToFile("=== plugin load ===");
    VPEnsureVirtualAudioProduct();
    io_iterator_t services = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleVirtIOSound"), &services);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "no AppleVirtIOSound service: 0x%x", result);
        return;
    }
    unsigned index = 0;
    io_service_t service;
    while ((service = IOIteratorNext(services))) {
        VPVirtIOSoundDevice *device = [[VPVirtIOSoundDevice alloc] initWithService:service index:index plugin:self];
        IOObjectRelease(service);
        if (device) {
            [device addSpeakerControls];
            [self addAudioDevice:device];
            index++;
        }
    }
    IOObjectRelease(services);
    os_log(VPLog(), "published %u virtio sound device(s)", index);
    VPLogToFile("published %u virtio sound device(s)", index);
}

@end

// MARK: - Factory

__attribute__((visibility("default")))
void *VPVirtIOSoundFactory(CFAllocatorRef allocator, CFUUIDRef requestedType);

void *VPVirtIOSoundFactory(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    static VPVirtIOSoundPlugin *plugin;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plugin = [[VPVirtIOSoundPlugin alloc] init];
    });
    return plugin.driverRef;
}
