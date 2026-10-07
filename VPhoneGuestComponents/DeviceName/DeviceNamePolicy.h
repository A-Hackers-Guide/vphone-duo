#ifndef VPHONE_DEVICE_NAME_POLICY_H
#define VPHONE_DEVICE_NAME_POLICY_H

// The decisions libdevicename makes, as pure CoreFoundation, so the host tests
// can check them without a guest. See libdevicename.c for where each is used.

#include <CoreFoundation/CoreFoundation.h>

// Internal to the library that compiles them in.
#define VP_DEVICE_NAME_INTERNAL __attribute__((visibility("hidden")))

// The NVRAM variable the host writes before boot: the name's UTF-8 bytes, no
// terminator. Absent, empty or not a valid name means the feature is off.
#define VP_DEVICE_NAME_NVRAM_VARIABLE "vphone-device-name"

// The longest name taken, in UTF-8 bytes. A longer value is invalid, so the
// feature is off rather than truncating the name.
#define VP_DEVICE_NAME_MAX_BYTES 255

// The dynamic store key configd publishes the name under
// (`SCDynamicStoreKeyCreateComputerName`), and the entries in it
// (`kSCPropSystemComputerName`, `kSCPropSystemComputerNameEncoding`).
#define VP_DEVICE_NAME_SYSTEM_KEY CFSTR("Setup:/System")
#define VP_DEVICE_NAME_COMPUTER_NAME CFSTR("ComputerName")
#define VP_DEVICE_NAME_COMPUTER_NAME_ENCODING CFSTR("ComputerNameEncoding")

// The name in an NVRAM property: CFData holding UTF-8 (trailing NULs are
// dropped) or a CFString. NULL when the property is absent, empty, longer than
// VP_DEVICE_NAME_MAX_BYTES, not UTF-8, or holds a control character.
VP_DEVICE_NAME_INTERNAL CFStringRef VPDeviceNameCreateFromProperty(CFTypeRef property);

// The same for raw bytes.
VP_DEVICE_NAME_INTERNAL CFStringRef VPDeviceNameCreateFromBytes(const UInt8 *bytes, CFIndex length);

// A copy of a `Setup:/System` value with ComputerName set to `name` and its
// encoding to UTF-8; every other entry is kept. A missing value, or one that is
// not a dictionary, counts as empty. NULL when the value already names `name`,
// so the caller passes the original through.
VP_DEVICE_NAME_INTERNAL CFDictionaryRef VPDeviceNameCreatePinnedSystem(CFTypeRef system, CFStringRef name);

// Whether an SCDynamicStoreSetMultiple call sets or removes anything in the
// `Setup:` domain, which in configd is the preferences monitor publishing
// preferences.plist.
VP_DEVICE_NAME_INTERNAL Boolean VPDeviceNameIsSetupPublication(CFDictionaryRef keysToSet, CFArrayRef keysToRemove);

// Whether VPDeviceNameCreatePinnedPublication needs the store's current
// `Setup:/System`: true when the call neither sets nor removes it, because the
// monitor leaves out a key whose value has not changed.
VP_DEVICE_NAME_INTERNAL Boolean VPDeviceNameNeedsStoredSystem(CFDictionaryRef keysToSet, CFArrayRef keysToRemove);

// Rewrites one publication so `Setup:/System` names `name`:
//   - set: its value gets the pinned ComputerName;
//   - removed (the preferences lost their System entry): the removal is dropped
//     and a value holding only the pinned name is set instead;
//   - neither: `stored`, the store's current value, is pinned and set if it
//     does not already name `name`.
// Returns true with *outSet (and *outRemove, which may be NULL when
// `keysToRemove` is) to pass on instead, both owned by the caller; false, with
// both NULL, when the call can go through unchanged.
VP_DEVICE_NAME_INTERNAL Boolean VPDeviceNameCreatePinnedPublication(CFDictionaryRef keysToSet, CFArrayRef keysToRemove,
                                            CFTypeRef stored, CFStringRef name,
                                            CFDictionaryRef *outSet, CFArrayRef *outRemove);

// Whether lockdownd may set the ComputerName `requested` while `pinned` is in
// force: only to the pinned name itself, or anything when nothing is pinned.
VP_DEVICE_NAME_INTERNAL Boolean VPDeviceNameAllowsRename(CFStringRef pinned, CFStringRef requested);

#endif
