#import <Foundation/Foundation.h>
#include <sys/types.h>

typedef struct {
    int (*listPIDs)(uint32_t, uint32_t, void *, int);
    int (*processPath)(int, void *, uint32_t);
    int (*signalProcess)(pid_t, int);
} VPHomePodSetupProcessAPI;

// Called only after the persisted/native completion transition. Only mobile's
// exact Apple setup executable may receive SIGTERM. No escalation to SIGKILL.
BOOL VPHomePodSetupStopProcesses(VPHomePodSetupProcessAPI api, uid_t user,
                                NSUInteger maximumPolls, void (^wait)(void), NSError **error);
