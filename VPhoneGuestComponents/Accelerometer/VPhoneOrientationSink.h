#pragma once
#import <Foundation/Foundation.h>
#import "VPhoneAccelerometerHID.h"

// The virtual board has no motion coprocessor to classify gravity for
// CMDeviceOrientationManager. Deliver the HID sample to backboardd's own sink.
void VPhoneOrientationSinkInstall(dispatch_queue_t statusQueue, dispatch_block_t statusChanged);
void VPhoneOrientationSinkRetry(void);
void VPhoneOrientationSinkPublish(id<VPhoneAccelerometerHIDEvent> event);
NSDictionary *VPhoneOrientationSinkStatus(void);
void VPhoneOrientationGateInstall(void);
