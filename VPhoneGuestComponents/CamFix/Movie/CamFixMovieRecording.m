// AVCaptureMovieFileOutput recording for vcam sessions.
//
// Camera.app's VIDEO mode records with
// -[AVCaptureMovieFileOutput startRecordingToOutputFileURL:recordingDelegate:]
// and -stopRecording. A vcam session's capture graph never runs, so the
// output never starts: the recording timer stays at 00:00:00, no file is
// written, and CAMCaptureEngine, still waiting for its request to finish,
// refuses photos until the app is relaunched.
//
// For an output bound to the virtual camera the original is never called.
// A recorder writes the shm frame at 30 Hz into the requested file with
// AVAssetWriter (H.264 in a QuickTime movie, the frame as photos get it),
// and sends the delegate the two callbacks a real recording sends:
// -captureOutput:didStartRecordingToOutputFileAtURL:fromConnections: once
// the first frame is written, and
// -captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:
// once the file is finished. The output's recording getters answer for the
// recorder meanwhile.
//
// When the session has an audio input (Camera.app's VIDEO mode adds the
// microphone), the daemon records no audio either, so an AVAudioEngine input
// tap in the client records the microphone into an AAC track, timed on the
// same uptime clock as the frames. Without a usable input format the movie
// is video only.

#import "CamFixPrivate.h"

// MARK: - recorder

@interface CfxMovieRecorder : NSObject
@property(nonatomic, weak) id output;
@property(nonatomic, strong) id delegate;
@property(nonatomic, copy) NSURL *url;
@property(nonatomic, copy) NSArray *connections;
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *input;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioFormat *audioFormat;
@property(nonatomic, strong) AVAssetWriterInput *audioInput;
@property(nonatomic) NSUInteger audioBuffers;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) uint64_t startNs;
@property(nonatomic) CMTime lastTime;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL stopping;
@end

@implementation CfxMovieRecorder
@end

static const void *CFX_ASSOC_RECORDER_KEY = &CFX_ASSOC_RECORDER_KEY;

static CfxMovieRecorder *cfx_recorder_for(id output) {
  return objc_getAssociatedObject(output, CFX_ASSOC_RECORDER_KEY);
}

static void cfx_recorder_set(id output, CfxMovieRecorder *recorder) {
  objc_setAssociatedObject(output, CFX_ASSOC_RECORDER_KEY, recorder,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static uint64_t cfx_now_ns(void) {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// The recorded length so far, zero before the first frame.
static CMTime cfx_recorder_duration(CfxMovieRecorder *r) {
  if (!r.started) return kCMTimeZero;
  return CMTimeMake((int64_t)((cfx_now_ns() - r.startNs) / 1000000ull), 1000);
}

static void cfx_send_did_start(CfxMovieRecorder *r) {
  SEL sel = @selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:);
  id output = r.output;
  if (!output || ![r.delegate respondsToSelector:sel]) return;
  cfxlog(@"[movie] -> didStartRecordingToOutputFileAtURL: %@", r.url.lastPathComponent);
  ((void (*)(id, SEL, id, id, id))objc_msgSend)(r.delegate, sel, output, r.url, r.connections);
}

static void cfx_send_did_finish(CfxMovieRecorder *r, NSError *error) {
  SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
  id output = r.output;
  if (output) cfx_recorder_set(output, nil);
  if (!output || ![r.delegate respondsToSelector:sel]) return;
  cfxlog(@"[movie] -> didFinishRecordingToOutputFileAtURL: %@ frames=%lu audio=%lu error=%@",
         r.url.lastPathComponent, (unsigned long)r.frames, (unsigned long)r.audioBuffers, error);
  ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(r.delegate, sel, output, r.url,
                                                    r.connections, error);
}

static NSError *cfx_movie_error(NSString *reason) {
  return [NSError errorWithDomain:AVFoundationErrorDomain
                             code:AVErrorUnknown
                         userInfo:@{NSLocalizedDescriptionKey: reason}];
}

static void cfx_recorder_stop_audio(CfxMovieRecorder *r);

// Runs on the recorder's queue. Creates the writer on the first frame, when
// the frame size is known.
static void cfx_recorder_tick(CfxMovieRecorder *r) {
  if (r.stopping) return;
  uint32_t w = 0, h = 0;
  CMSampleBufferRef sb =
      cfx_build_oriented_cmsb(VCC_FMT_420V, 0, 0, 0, 1.0, 0, NO, &w, &h);
  if (!sb) return;
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
  if (!pb) {
    CFRelease(sb);
    return;
  }
  if (!r.writer) {
    NSError *err = nil;
    [NSFileManager.defaultManager removeItemAtURL:r.url error:NULL];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:r.url
                                                     fileType:AVFileTypeQuickTimeMovie
                                                        error:&err];
    AVAssetWriterInput *input = [AVAssetWriterInput
        assetWriterInputWithMediaType:AVMediaTypeVideo
                       outputSettings:@{
                         AVVideoCodecKey: AVVideoCodecTypeH264,
                         AVVideoWidthKey: @(w),
                         AVVideoHeightKey: @(h),
                         AVVideoCompressionPropertiesKey: @{
                           AVVideoAverageBitRateKey: @(6000000),
                           AVVideoExpectedSourceFrameRateKey: @(30),
                           AVVideoMaxKeyFrameIntervalKey: @(30),
                         },
                       }];
    input.expectsMediaDataInRealTime = YES;
    if (!writer || ![writer canAddInput:input]) {
      CFRelease(sb);
      cfxlog(@"[movie] cannot create writer for %@: %@", r.url.path, err);
      r.stopping = YES;
      dispatch_source_cancel(r.timer);
      cfx_recorder_stop_audio(r);
      cfx_send_did_finish(r, cfx_movie_error(@"The recording could not be started."));
      return;
    }
    [writer addInput:input];
    if (r.audioFormat) {
      AVAssetWriterInput *audio = [AVAssetWriterInput
          assetWriterInputWithMediaType:AVMediaTypeAudio
                         outputSettings:@{
                           AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                           AVSampleRateKey: @(r.audioFormat.sampleRate),
                           AVNumberOfChannelsKey: @(MIN(r.audioFormat.channelCount, 2u)),
                           AVEncoderBitRateKey: @(128000),
                         }
                       sourceFormatHint:r.audioFormat.formatDescription];
      audio.expectsMediaDataInRealTime = YES;
      if ([writer canAddInput:audio]) {
        [writer addInput:audio];
        r.audioInput = audio;
      } else {
        cfxlog(@"[movie] audio input refused for %@; recording video only", r.audioFormat);
      }
    }
    r.adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                   sourcePixelBufferAttributes:nil];
    if (![writer startWriting]) {
      CFRelease(sb);
      cfxlog(@"[movie] startWriting failed: %@", writer.error);
      r.stopping = YES;
      dispatch_source_cancel(r.timer);
      cfx_recorder_stop_audio(r);
      cfx_send_did_finish(r, writer.error ?: cfx_movie_error(@"The recording could not be started."));
      return;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    r.writer = writer;
    r.input = input;
    r.startNs = cfx_now_ns();
    cfxlog(@"[movie] writing %ux%u H.264%@ to %@", w, h, r.audioInput ? @" + AAC" : @"",
           r.url.path);
  }
  CMTime t = CMTimeMake((int64_t)((cfx_now_ns() - r.startNs) / 1000000ull), 1000);
  if (r.frames == 0 || CMTimeCompare(t, r.lastTime) > 0) {
    if (r.input.readyForMoreMediaData && [r.adaptor appendPixelBuffer:pb withPresentationTime:t]) {
      r.lastTime = t;
      r.frames++;
      if (!r.started) {
        r.started = YES;
        cfx_send_did_start(r);
      }
    }
  }
  CFRelease(sb);
}

// MARK: - microphone

// YES when the output's session records sound: it has a device input whose
// device delivers audio.
static BOOL cfx_session_has_audio_input(id output) {
  @try {
    AVCaptureSession *session = [output valueForKey:@"session"];
    for (AVCaptureInput *input in session.inputs) {
      if ([input isKindOfClass:[AVCaptureDeviceInput class]] &&
          [((AVCaptureDeviceInput *)input).device hasMediaType:AVMediaTypeAudio]) {
        return YES;
      }
    }
  } @catch (NSException *e) {}
  return NO;
}

// A copy of the tap's buffer, timed from startNs, or NULL. The engine reuses
// its buffer once the tap returns, so the samples are copied here, on the
// tap's thread.
static CMSampleBufferRef cfx_audio_sample_buffer(AVAudioPCMBuffer *buffer, AVAudioTime *when,
                                                 uint64_t startNs) CF_RETURNS_RETAINED {
  if (!buffer.frameLength) return NULL;
  uint64_t hostNs = when.hostTimeValid
      ? (uint64_t)([AVAudioTime secondsForHostTime:when.hostTime] * 1e9)
      : cfx_now_ns();
  if (hostNs < startNs) return NULL;
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, (int32_t)buffer.format.sampleRate),
      .presentationTimeStamp = CMTimeMake((int64_t)((hostNs - startNs) / 1000ull), 1000000),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef sb = NULL;
  OSStatus err = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL,
                                      buffer.format.formatDescription, buffer.frameLength, 1,
                                      &timing, 0, NULL, &sb);
  if (err == noErr) {
    err = CMSampleBufferSetDataBufferFromAudioBufferList(sb, kCFAllocatorDefault,
                                                         kCFAllocatorDefault, 0,
                                                         buffer.audioBufferList);
  }
  if (err != noErr) {
    static int logged = 0;
    if (logged++ == 0) cfxlog(@"[movie] audio sample buffer failed: %d", (int)err);
    if (sb) CFRelease(sb);
    return NULL;
  }
  return sb;
}

// Runs on the recorder's queue. Consumes sb.
static void cfx_recorder_append_audio(CfxMovieRecorder *r, CMSampleBufferRef sb) {
  if (!r.stopping && r.audioInput.readyForMoreMediaData && [r.audioInput appendSampleBuffer:sb]) {
    r.audioBuffers++;
  }
  CFRelease(sb);
}

// Starts the microphone tap. Leaves audioFormat nil, so the movie is video
// only, when the input has no usable format or the engine will not start.
static void cfx_recorder_start_audio(CfxMovieRecorder *r) {
  AVAudioEngine *engine = [AVAudioEngine new];
  AVAudioInputNode *mic = engine.inputNode;
  AVAudioFormat *format = [mic outputFormatForBus:0];
  if (format.sampleRate <= 0 || format.channelCount == 0) {
    cfxlog(@"[movie] microphone has no input format (%@); recording video only", format);
    return;
  }
  __weak CfxMovieRecorder *weak = r;
  [mic installTapOnBus:0
            bufferSize:1024
                format:format
                 block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                   CfxMovieRecorder *strong = weak;
                   // Nothing before the first frame starts the writer's
                   // session at time zero.
                   if (!strong.started) return;
                   CMSampleBufferRef sb = cfx_audio_sample_buffer(buffer, when, strong.startNs);
                   if (!sb) return;
                   dispatch_async(strong.queue, ^{ cfx_recorder_append_audio(strong, sb); });
                 }];
  NSError *error = nil;
  if (![engine startAndReturnError:&error]) {
    [mic removeTapOnBus:0];
    cfxlog(@"[movie] microphone did not start (%@); recording video only", error);
    return;
  }
  r.engine = engine;
  r.audioFormat = format;
  cfxlog(@"[movie] microphone %@", format);
}

static void cfx_recorder_stop_audio(CfxMovieRecorder *r) {
  if (!r.engine) return;
  [r.engine.inputNode removeTapOnBus:0];
  [r.engine stop];
  r.engine = nil;
}

// Runs on the recorder's queue.
static void cfx_recorder_finish(CfxMovieRecorder *r) {
  if (r.stopping) return;
  r.stopping = YES;
  dispatch_source_cancel(r.timer);
  cfx_recorder_stop_audio(r);
  if (!r.writer || r.frames == 0) {
    cfxlog(@"[movie] stopped before any frame was written");
    [r.writer cancelWriting];
    cfx_send_did_finish(r, cfx_movie_error(@"No camera frames were recorded."));
    return;
  }
  [r.input markAsFinished];
  [r.audioInput markAsFinished];
  [r.writer endSessionAtSourceTime:r.lastTime];
  [r.writer finishWritingWithCompletionHandler:^{
    dispatch_async(r.queue, ^{
      NSError *error = r.writer.status == AVAssetWriterStatusCompleted ? nil : r.writer.error;
      cfx_send_did_finish(r, error);
    });
  }];
}

// MARK: - AVCaptureMovieFileOutput hooks

static IMP cfx_orig_movie_start = NULL;
static IMP cfx_orig_movie_stop = NULL;
static IMP cfx_orig_movie_isRecording = NULL;
static IMP cfx_orig_movie_recordedDuration = NULL;
static IMP cfx_orig_movie_outputFileURL = NULL;

static void cfx_movie_start_hook(id self, SEL _cmd, NSURL *url, id delegate) {
  if (!cfx_output_is_for_vcam(self)) {
    ((void (*)(id, SEL, NSURL *, id))cfx_orig_movie_start)(self, _cmd, url, delegate);
    return;
  }
  cfxlog(@"[movie] startRecordingToOutputFileURL: %@ delegate=%@", url.path, delegate);
  CfxMovieRecorder *previous = cfx_recorder_for(self);
  if (previous) {
    dispatch_async(previous.queue, ^{ cfx_recorder_finish(previous); });
  }
  CfxMovieRecorder *r = [CfxMovieRecorder new];
  r.output = self;
  r.delegate = delegate;
  r.url = url;
  @try { r.connections = [self valueForKey:@"connections"]; } @catch (NSException *e) {}
  r.queue = dispatch_queue_create("com.vphone.camfix.movie", DISPATCH_QUEUE_SERIAL);
  r.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, r.queue);
  dispatch_source_set_timer(r.timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                            NSEC_PER_SEC / 30, NSEC_PER_MSEC);
  __weak CfxMovieRecorder *weak = r;
  dispatch_source_set_event_handler(r.timer, ^{
    @autoreleasepool {
      CfxMovieRecorder *strong = weak;
      if (strong) cfx_recorder_tick(strong);
    }
  });
  if (cfx_session_has_audio_input(self)) cfx_recorder_start_audio(r);
  cfx_recorder_set(self, r);
  dispatch_resume(r.timer);
}

static void cfx_movie_stop_hook(id self, SEL _cmd) {
  CfxMovieRecorder *r = cfx_recorder_for(self);
  if (!r) {
    ((void (*)(id, SEL))cfx_orig_movie_stop)(self, _cmd);
    return;
  }
  cfxlog(@"[movie] stopRecording after %lu frame(s)", (unsigned long)r.frames);
  dispatch_async(r.queue, ^{ cfx_recorder_finish(r); });
}

static BOOL cfx_movie_isRecording_hook(id self, SEL _cmd) {
  CfxMovieRecorder *r = cfx_recorder_for(self);
  if (r) return r.started && !r.stopping;
  return ((BOOL (*)(id, SEL))cfx_orig_movie_isRecording)(self, _cmd);
}

static CMTime cfx_movie_recordedDuration_hook(id self, SEL _cmd) {
  CfxMovieRecorder *r = cfx_recorder_for(self);
  if (r) return cfx_recorder_duration(r);
  return ((CMTime (*)(id, SEL))cfx_orig_movie_recordedDuration)(self, _cmd);
}

static NSURL *cfx_movie_outputFileURL_hook(id self, SEL _cmd) {
  CfxMovieRecorder *r = cfx_recorder_for(self);
  if (r) return r.url;
  return ((NSURL * (*)(id, SEL)) cfx_orig_movie_outputFileURL)(self, _cmd);
}

static void cfx_swizzle(Class cls, SEL sel, IMP imp, IMP *orig) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    cfxlog(@"[movie] -[%s %@] missing", class_getName(cls), NSStringFromSelector(sel));
    return;
  }
  *orig = method_setImplementation(m, imp);
}

void cfx_install_movie_recording_hooks(void) {
  Class cls = NSClassFromString(@"AVCaptureMovieFileOutput");
  if (!cls) {
    cfxlog(@"AVCaptureMovieFileOutput missing");
    return;
  }
  cfx_swizzle(cls, @selector(startRecordingToOutputFileURL:recordingDelegate:),
              (IMP)cfx_movie_start_hook, &cfx_orig_movie_start);
  cfx_swizzle(cls, @selector(stopRecording), (IMP)cfx_movie_stop_hook, &cfx_orig_movie_stop);
  cfx_swizzle(cls, @selector(isRecording), (IMP)cfx_movie_isRecording_hook,
              &cfx_orig_movie_isRecording);
  cfx_swizzle(cls, @selector(recordedDuration), (IMP)cfx_movie_recordedDuration_hook,
              &cfx_orig_movie_recordedDuration);
  cfx_swizzle(cls, @selector(outputFileURL), (IMP)cfx_movie_outputFileURL_hook,
              &cfx_orig_movie_outputFileURL);
  cfxlog(@"installed movie recording hooks");
}

// MARK: - Camera.app's VIDEO mode (iOS 26)
//
// Camera.app on 26.x lists VIDEO only when -[CAMCaptureCapabilities
// isVideoSupported] is set, and -initWithHostProcess: sets the
// _videoSupported ivar it reads from AVGestaltGetBoolAnswer(
// AVGQVideoCameraCapability), which is NO on a guest. Other CameraUI code
// reads the ivar directly, so it is the ivar that is set, once the
// initializer returns and only when the vcam device is there. iOS 27 dropped
// the ivar and lists VIDEO with the camera; this does nothing there.

static IMP cfx_orig_capabilities_init = NULL;

__attribute__((ns_returns_retained))
static id cfx_capabilities_init_hook(id self, SEL _cmd, id hostProcess) {
  typedef id (*Fn)(id, SEL, id);
  id caps = ((Fn)cfx_orig_capabilities_init)(self, _cmd, hostProcess);
  Ivar iv = caps ? class_getInstanceVariable(object_getClass(caps), "_videoSupported") : NULL;
  if (!iv) return caps;
  BOOL *flag = (BOOL *)((char *)(__bridge void *)caps + ivar_getOffset(iv));
  if (!*flag && [AVCaptureDevice deviceWithUniqueID:VCAM_UID]) {
    *flag = YES;
    cfxlog(@"[movie] CAMCaptureCapabilities: video supported (vcam device present)");
  }
  return caps;
}

void cfx_install_video_mode_capability(void) {
  Class cls = NSClassFromString(@"CAMCaptureCapabilities");
  if (!cls || !class_getInstanceVariable(cls, "_videoSupported")) return;
  cfx_swizzle(cls, NSSelectorFromString(@"initWithHostProcess:"),
              (IMP)cfx_capabilities_init_hook, &cfx_orig_capabilities_init);
  cfxlog(@"installed CAMCaptureCapabilities video mode hook");
}
