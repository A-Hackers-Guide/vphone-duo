// MISFixDeviceIdentity.c — answer the profile check with a chosen UDID.
//
// A provisioning profile names the devices it covers. misagent refuses to
// install one that does not name this device:
//
//     Failed to install embedded profile for plus.yellow.AirBuild : 0xE8008012
//       (This provisioning profile cannot be installed on this device.)
//       -[MIInstallableBundle _installEmbeddedProfilesWithError:]
//
// which is correct — a VM's UDID is not in anyone's `ProvisionedDevices`
// unless Xcode has just registered it, and Xcode can only do that for a free
// personal team. For a paid team the VM would have to be added to the account
// by hand, and again after every `vm create`.
//
// ## Where the comparison gets its UDID
//
// misagent carries the same UDID-query helper libmis does — its strings give
// the order outright:
//
//     amfi_emulate_device_udid / "Using emulated device UDID: %{public}@"
//     "got NULL when querying UDID" / "got non-string when querying UDID"
//     "could not get device UDID" / deviceUDID / UniqueDeviceID
//     ProvisionedDevices / ProvisionsAllDevices
//
// It first asks the kernel's codesigning configuration for an emulated UDID,
// then falls back to MobileGestalt. On a vphone600 guest the first path is
// dead: `amfi_emulate_device_udid` appears in neither the kernelcache nor TXM,
// so nothing ever publishes that key and the fallback is what runs. misagent's
// only imports that could answer are `_MGCopyAnswer` and lockdown's check-in,
// and MobileGestalt is where `UniqueDeviceID` lives.
//
// `MGCopyAnswer` is exported from libMobileGestalt, so the fallback is the one
// place a hook can stand.
//
// ## What this does
//
// When `/usr/lib/libmisfix.plist` sets `UniqueDeviceID`, a MobileGestalt query
// for that property is answered with the configured string instead of the
// guest's own. Every other query is passed through untouched. With no
// configuration the hook is inert.
//
// Point it at a device the team has already registered and that team's
// profiles install here, with no portal round trip and nothing to redo after a
// rebuild.
//
// ## How far this reaches, measured
//
// misagent, and nothing else that matters. Its main executable calls
// `MGCopyAnswer` itself, so the interpose catches it and a profile naming the
// configured device installs.
//
// installd does not benefit, and no version of this dylib can make it. Its
// profile check runs MobileInstallation → libmis → libMobileGestalt, all three
// inside the dyld shared cache, and an interpose rewrites call sites in the
// images dyld links — not the cache's own. Measured on test-26.4 (2026-09-30,
// `libmisfix[726]`): one `devicectl device install app`, `LogQueries` on, and
// the only line from installd is `MGCopyAnswer(BuildVersion) from installd`.
// No `UniqueDeviceID` query, although libmis plainly resolved one — it skipped
// every installed profile with `0xE8008012` and then returned
//
//     +[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]:
//         80: Failed to verify code signature of …/AirBuild.app : 0xe8008015
//
// The signature itself was fine; the same capture has `cdhash: <private> is
// trusted`. libmis's other route to a UDID is closed too:
// `amfi_interface_query_bootarg_state returned error Function not implemented`.
//
// So an Xcode or `devicectl` install still needs the guest's *own* UDID to be
// in the profile. Two things could give it that, and neither belongs in this
// file: a shared-cache patch on libmis, or creating the VM with the ECID of a
// device the team has already registered — a modern UDID is
// `<chip-id>-<ECID>`, and the ECID is chosen at `vm create`, so that one needs
// no hook and tells no lie.
//
// ## The inconsistency this creates, stated plainly
//
// The guest gives two different answers about which device it is. What Xcode,
// `devicectl` and lockdown report is unchanged — that UDID is built by TXM
// before the kernel runs, out of the device tree's `chip-id` and
// `unique-chip-id`, and nothing in userspace can alter it. Only the processes
// carrying this hook see the configured value.
//
// That is deliberate. Making the two agree would mean rewriting
// `unique-chip-id`, which is the ECID the guest's SHSH blob is issued against,
// so the VM would have to be restored again — and `chip-id` is fixed at
// 0x0000FE01 by the virtual SoC, so a real iPhone's UDID could not be
// reproduced even then.

#include "MISFixConfig.h"
#include "MISFixInterpose.h"

#include <mach-o/dyld.h>

extern CFTypeRef MGCopyAnswer(CFStringRef property);
extern CFTypeRef MGCopyAnswerWithError(CFStringRef property, uint32_t *error);

/// Log every MobileGestalt query this hook sees, and whether it answered.
///
/// Off unless the config sets `LogQueries`, because these daemons are asked a
/// lot and the log is how a person watches an install. It exists because the
/// interesting failure is *silence*: the override reaches misagent and a
/// profile installs, but installd then refuses the same app with
/// `0xE8008015`, and the two explanations — installd asking and getting the
/// wrong answer, versus installd never asking through this symbol at all —
/// look identical from outside.
///
/// It has now told us which. Each line names the caller's image, and installd
/// produced exactly one, `MGCopyAnswer(BuildVersion) from installd`: the main
/// executable's own call and nothing else. The header's "How far this reaches"
/// has the rest. The instrument stays because the answer is a property of this
/// cache and this dyld, not a law, and one capture re-checks it.
static void vpLogQuery(CFStringRef property, int answered, const char *caller) {
    char name[128];
    if (property == NULL
        || !CFStringGetCString(property, name, sizeof(name), kCFStringEncodingUTF8))
    {
        return;
    }
    MISFixLog(
        "MGCopyAnswer(%s) from %s %s",
        name,
        caller,
        answered ? "-> override" : "passed through"
    );
}

/// Say, once, that this dylib is in this process.
///
/// The positive control the diagnosis needs. Without it, "installd logged no
/// MGCopyAnswer" has two readings that look the same — the call never came
/// through the interposed symbol, or the hook was not in the process at all —
/// and they call for opposite fixes. With it, the pair of lines is decisive:
/// this one and no query line means the call is bypassing the interpose.
__attribute__((constructor)) static void vpAnnounce(void) {
    char path[4096];
    uint32_t size = sizeof(path);
    MISFixLog("loaded into %s", _NSGetExecutablePath(path, &size) == 0 ? path : "<unknown>");
}

/// MobileGestalt's key for the UDID. A plain string, not the SDK constant:
/// there is no public header, and this is the literal misagent carries.
#define kMISFixUniqueDeviceIDProperty CFSTR("UniqueDeviceID")

/// The configured answer for `property`, already retained for the caller, or
/// NULL to let MobileGestalt answer.
static CFTypeRef vpOverrideFor(CFStringRef property) {
    if (property == NULL || CFGetTypeID(property) != CFStringGetTypeID())
        return NULL;
    if (!CFEqual(property, kMISFixUniqueDeviceIDProperty))
        return NULL;

    CFStringRef configured = MISFixCopyConfiguredDeviceIdentifier();
    if (configured == NULL)
        return NULL;

    // MGCopyAnswer returns +1; the caller releases what it gets.
    return CFStringCreateCopy(kCFAllocatorDefault, configured);
}

static CFTypeRef vpMGCopyAnswer(CFStringRef property) {
    const char *caller = MISFixCaller();
    CFTypeRef override = vpOverrideFor(property);
    vpLogQuery(property, override != NULL, caller);
    return override != NULL ? override : MGCopyAnswer(property);
}

static CFTypeRef vpMGCopyAnswerWithError(CFStringRef property, uint32_t *error) {
    const char *caller = MISFixCaller();
    CFTypeRef override = vpOverrideFor(property);
    vpLogQuery(property, override != NULL, caller);
    if (override == NULL)
        return MGCopyAnswerWithError(property, error);
    if (error != NULL)
        *error = 0;
    return override;
}

// Both spellings are replaced. misagent imports only the plain one; the
// variant is covered so a different consumer of this hook cannot read around
// it by accident.
MISFIX_INTERPOSE(vpMGCopyAnswer, MGCopyAnswer);
MISFIX_INTERPOSE(vpMGCopyAnswerWithError, MGCopyAnswerWithError);
