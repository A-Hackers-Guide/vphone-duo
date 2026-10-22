// The synthetic camera's source on iOS 27.
//
// iOS 27 no longer keeps a source list the daemon serializes for clients
// (`_sSourceList`, which VCamSourceInstallation.m appends to on 26.x).
// -[FigCaptureSourceManager copySourcesWithType:clientAuditToken:
// clientIsBincompat:] makes each client's sources on request, one per
// FigCaptureSourceBacking in +[FigCaptureSourceBackingsProvider
// sharedCaptureSourceBackingsProvider].sourceBackings, through
// FigVideoCaptureSourceCreateFromBacking for video backings. The shared
// FigCaptureSourceManager is itself made from that array.
//
// So the synthetic camera is published by adding its backing to the
// provider's `_sourceBackings`, before the source manager is created. The
// provider is the one VCamMicrophoneSource.m serves when the daemon could
// build none of its own, which is the case on every VM. See
// Research/Guest/virtual_camera_transport.md.

#include "VCamSynthetic.h"

BOOL vcc_provider_publishes_sources(void) {
  return NSClassFromString(@"FigCaptureSourceManager") != Nil;
}

void vcc_provider_add_synthetic_camera(id provider) {
  if (!provider || !vcc_provider_publishes_sources()) return;
  Ivar iv = class_getInstanceVariable(object_getClass(provider), "_sourceBackings");
  if (!iv) {
    vcc_log(@"  provider camera: no _sourceBackings ivar");
    return;
  }
  id backings = object_getIvar(provider, iv);
  if (![backings isKindOfClass:NSMutableArray.class]) {
    vcc_log(@"  provider camera: _sourceBackings is %@, not a mutable array",
            [backings class]);
    return;
  }
  id backing = vcc_build_backing();
  if (!backing) {
    vcc_log(@"  provider camera: no synthetic backing");
    return;
  }
  [(NSMutableArray *)backings addObject:backing];
  vcc_log(@"  provider camera: added synthetic backing %p, %lu backing(s)",
          backing, (unsigned long)[(NSMutableArray *)backings count]);
}
