#import <Foundation/Foundation.h>

// Installs only in SoundBoard when HomePodSiriSpeech.plist enables the adapter.
// The native say:completion: NSError contract remains unchanged. A nil error
// means native finalization, and does not assert that a person heard the speech.
BOOL VPHomePodSiriSpeechInstall(void);
