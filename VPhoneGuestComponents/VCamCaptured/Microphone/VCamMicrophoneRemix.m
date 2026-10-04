// No Audio Mix analysis on a guest that has no capture hardware.
//
// A spatial recording (Voice Memos on iOS 27 records first-order ambisonics,
// because the microphone source built from the product plist advertises
// cinematic audio) gets a BWAudioRemixAnalysisMetadataNode in its movie-file
// pipeline. At the start marker the node calls
// -[AudioRemixSessionManager startNewSessionBlocking], which builds a
// SoundAnalysis movie-remix session; initialising that session's neural net
// faults in cameracaptured on the guest (BNNSGraphContextMakeStreaming,
// KERN_INVALID_ADDRESS 0x300), about 2 s into every recording.
//
// The node already copes with a session that does not start: a non-zero
// return leaves _shouldSendData clear, buffers are passed through
// (emitSampleBuffer:), submitAudioBuffer: is skipped while sessionReady is NO,
// and -finishAndGetResultsBlockingWithStartingPTS:andEndingPTS: returns an
// error instead of waiting when there is no subscriber. So while the daemon
// runs on the microphone-only provider (no camera device: a VM), the method
// returns the error its own failure path signals, without creating the
// session. With a real capture device it runs unchanged.
// See Research/Guest/ios27_capture_microphone_source.md §7.

#include "VCamCapturedPrivate.h"

// The code -startNewSessionBlocking signals when its session does not start.
static const int kVccRemixSessionNotStarted = -16992;

static IMP vcc_remix_start_orig = NULL;
static BOOL vcc_remix_skip_logged = NO;

static int vcc_remix_start_hook(id self, SEL _cmd) {
  if (!vcc_microphone_only_source_active()) {
    return ((int (*)(id, SEL))vcc_remix_start_orig)(self, _cmd);
  }
  if (!vcc_remix_skip_logged) {
    vcc_remix_skip_logged = YES;
    vcc_log(@"  mic source: no capture hardware; Audio Mix analysis session not started (%d)",
            kVccRemixSessionNotStarted);
  }
  return kVccRemixSessionNotStarted;
}

void vcc_install_remix_session_skip(void) {
  Class cls = NSClassFromString(@"AudioRemixSessionManager");
  SEL sel = NSSelectorFromString(@"startNewSessionBlocking");
  Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
  if (!m) {
    vcc_log(@"  remix: -[AudioRemixSessionManager startNewSessionBlocking] missing");
    return;
  }
  // The node branches on a 32-bit status (cbnz w0); refuse any other shape.
  const char *types = method_getTypeEncoding(m);
  if (!types || (types[0] != 'i' && types[0] != 'I')) {
    vcc_log(@"  remix: startNewSessionBlocking has type %s, not wrapped",
            types ?: "?");
    return;
  }
  vcc_remix_start_orig = method_setImplementation(m, (IMP)vcc_remix_start_hook);
  vcc_log(@"  remix: wrapped -[AudioRemixSessionManager startNewSessionBlocking] (orig imp=%p)",
          vcc_remix_start_orig);
}
