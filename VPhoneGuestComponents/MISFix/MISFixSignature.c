// MISFixSignature.c — widen MIS's idea of an acceptable signature.
//
// ## Measured 2026-09-30: this never runs in installd, and cannot
//
// Read this first, because the rest of the file was written believing
// otherwise. A `__DATA,__interpose` replacement is applied to *call sites*, and
// every call site that matters here is inside the dyld shared cache:
//
//     MobileInstallation.framework  →  libmis.dylib        (cache to cache)
//     libmis.dylib                  →  libMobileGestalt    (cache to cache)
//
// Neither is rewritten, whether this dylib arrives as a weak dependency of the
// main executable or ahead of everything through `DYLD_INSERT_LIBRARIES`. On
// test-26.4, with `LogQueries` on and the log for `MISValidateSignatureAndCopyInfo`
// made unconditional, a whole `devicectl device install app` produced exactly
// one line from installd:
//
//     libmisfix[726]: MGCopyAnswer(BuildVersion) from installd passed through
//
// `from installd` is the point: the one call this hook catches is the one the
// main executable makes itself. `+[MICodeSigningVerifier
// _validateSignatureAndCopyInfoForURL:withOptions:error:]` ran to its line 80
// and failed, and no line here records it.
//
// So the options are never widened in installd. What that daemon actually
// refuses, and why, is in MISFixDeviceIdentity.c; fixing it means changing the
// shared cache, not this dylib. misagent is different — its main executable
// calls `MGCopyAnswer` itself — and the UDID override there does work.
//
// The hook is kept because it costs nothing and is correct where it is
// reached, and because it is the control that measured all of this.
//
// A guest restored by this project runs unsigned code happily: the kernel
// patches (`amfi_trustcache`, `jb.post_validation`, `jb.amfi_execve`) admit it,
// lsd registers it, and SpringBoard launches it. An app pushed in through
// vphoned's `apps.install` proves the whole chain — it is signed with nothing
// but the project's own ldid-shaped signature and it reaches the foreground.
//
// Everything except installd. `xcrun devicectl device install app` stops at a
// single userspace gate:
//
//     +[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]
//         → MISValidateSignatureAndCopyInfo   (/usr/lib/libmis.dylib)
//
//     unsigned                  → 0xE800801C  No code signature found.
//     ldid, no CMS blob         → 0xE800801C
//     codesign --sign - (adhoc) → 0xE8008014  The executable contains an invalid signature.
//
// so Xcode cannot install anything it did not sign with a real Apple leaf.
//
// ## What this does
//
// MIS already knows how to accept an ad-hoc signature; installd simply never
// asks it to. The options dictionary carries a documented-by-string key for
// exactly that, and setting it is the whole fix. Measured in the guest, on a
// bundle signed with `codesign --sign -`:
//
//     no options                                     → 0xE8008014
//     AllowAdHocSigning                              → 0  ✅
//     AllowAdHocSigning + ValidateSignatureOnly      → 0
//     AllowAdHocSigning + SkipProfileIdentifierPolicy→ 0
//     ValidateSignatureOnly                          → 0xE8008014
//     TrustCacheOnly                                 → 0xE8008014
//
// and the info dictionary MIS returns on success is complete — `CdHash`,
// `Entitlements`, `SigningID`, `SignerType`, `SignatureVersion`,
// `IsNativeForPlatform`, `ValidatedByProfile` — so nothing here has to
// synthesise a reply. That matters: installd reads those keys, and a hook that
// faked success without them would break the install further down.
//
// So the hook adds one key to the options and calls through. On anything MIS
// would have accepted anyway the behaviour is bit for bit unchanged, because
// the key only widens what counts as an acceptable signature.
//
// ## What this deliberately does not do
//
// An unsigned binary still fails, with `0xE800801C`, and that is left alone.
// Everything past installd needs the cdhash that only a signature carries, and
// `codesign --sign -` (Xcode's "Sign to Run Locally") costs nothing and
// supplies one. Forging a reply for a bundle with no signature at all would
// mean inventing a cdhash the kernel never agreed to.
//
// The online-authorization gate is a different patch: `mis_trust_auth` covers
// a profile that wants network validation on a hacktivated guest. This one is
// only about the signature's shape.
//
// ## Mechanism
//
// See `MISFixInterpose.h`. SystemHook puts this dylib in
// `DYLD_INSERT_LIBRARIES` for the processes it recognises by path, so it is
// loaded ahead of everything — which is the strongest position an interpose
// can be in, and still not enough to reach the cache-internal call sites
// above.

#include "MISFixConfig.h"
#include "MISFixInterpose.h"

#include <CoreFoundation/CoreFoundation.h>

// libmis's own option keys, taken from the cache's string table rather than
// from a header — libmis.tbd exports the `kMISValidationOption*` symbols but
// the SDK declares none of them.
#define kMISValidationOptionAllowAdHocSigning CFSTR("AllowAdHocSigning")
#define kMISValidationOptionRespectUppTrustAndAuthorization CFSTR("RespectUppTrustAndAuthorization")

// The first argument is a path string, not a URL. Handing MIS an NSURL aborts
// the process inside libmis with `-[NSURL length]: unrecognized selector`,
// which is how this was pinned down.
typedef CFStringRef MISPath;

extern int MISValidateSignatureAndCopyInfo(MISPath path, CFDictionaryRef options, CFDictionaryRef *info);
extern int MISValidateSignatureAndCopyInfoWithProgress(
    MISPath path,
    CFDictionaryRef options,
    CFDictionaryRef *info,
    void *progress
);

/// The caller's options, widened. Never returns NULL for a NULL input: MIS is
/// called with an options dictionary either way.
///
/// Two keys go in.
///
/// `AllowAdHocSigning` is the signature half described above.
///
/// `RespectUppTrustAndAuthorization = false` is the online-authorization half,
/// and it replaces a patch that used to edit the shared cache. libmis reaches
/// `checkTrustAndAuthorization` — the only producer of `0xE8008026`, "missing
/// trust and/or authorization" — through a branch gated on precisely this
/// option, so turning it off means the check is never called and the failure
/// cannot arise. A hacktivated guest has no activation record and so can never
/// satisfy that check; `mis_trust_auth` used to force the function to return
/// success by rewriting its prologue in the cache, which is what leaves a 27.0
/// guest unable to boot (issue #532).
///
/// Steering rather than forcing also matters for correctness, not just for the
/// cache: on the failure path libmis returns without ever writing the `info`
/// out-parameter, so a hook that rewrote the return code to 0 would hand its
/// caller success with no `CdHash` and no `Entitlements`. Declining the check
/// makes the ordinary success path run and fill the dictionary for real.
///
/// The option parser writes a flag's slot only when the key is present, so an
/// explicit value always beats the defaults `UnauthoritativeLaunch` installs —
/// and nothing else in the shared cache passes this key, so there is no
/// caller's own value to override.
static CFDictionaryRef vpWidenedOptions(CFDictionaryRef options) {
    CFMutableDictionaryRef widened =
        options != NULL
            ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, options)
            : CFDictionaryCreateMutable(
                  kCFAllocatorDefault,
                  2,
                  &kCFTypeDictionaryKeyCallBacks,
                  &kCFTypeDictionaryValueCallBacks
              );
    if (widened == NULL)
        return NULL;
    CFDictionarySetValue(widened, kMISValidationOptionAllowAdHocSigning, kCFBooleanTrue);
    CFDictionarySetValue(
        widened,
        kMISValidationOptionRespectUppTrustAndAuthorization,
        kCFBooleanFalse
    );
    return widened;
}

/// Log one validation, under `LogQueries`.
///
/// This is the other half of the control. `MISValidateSignatureAndCopyInfo` is
/// reached the same way the UDID query is — from MobileInstallation, in the
/// shared cache, into libmis, also in the shared cache, with the main
/// executable's own image not involved. So if this line appears in installd
/// and the `MGCopyAnswer` line does not, the two calls are being treated
/// differently and the difference is in MobileGestalt, not in whether an
/// interpose can cross the cache at all.
/// Never returns early. A first run logged nothing here from installd, which
/// was read as "the interpose was not reached" — but a `path` this could not
/// turn into a C string would have produced exactly the same silence. The line
/// is unconditional now, and says what the argument was when it is not a
/// string, so an absent line means one thing only.
static void vpLogValidation(MISPath path, int result, const char *caller) {
    char buffer[1024];
    if (path == NULL) {
        MISFixLog("MISValidateSignatureAndCopyInfo(NULL) from %s -> 0x%x", caller, (unsigned)result);
        return;
    }
    if (CFGetTypeID(path) != CFStringGetTypeID()
        || !CFStringGetCString(path, buffer, sizeof(buffer), kCFStringEncodingUTF8))
    {
        MISFixLog(
            "MISValidateSignatureAndCopyInfo(<non-string %lu>) from %s -> 0x%x",
            (unsigned long)CFGetTypeID(path),
            caller,
            (unsigned)result
        );
        return;
    }
    MISFixLog(
        "MISValidateSignatureAndCopyInfo(%s) from %s -> 0x%x",
        buffer,
        caller,
        (unsigned)result
    );
}

static int vpMISValidateSignatureAndCopyInfo(
    MISPath path,
    CFDictionaryRef options,
    CFDictionaryRef *info
) {
    const char *caller = MISFixCaller();
    CFDictionaryRef widened = vpWidenedOptions(options);
    // Out of memory: pass the caller's own options through rather than fail.
    if (widened == NULL)
        return MISValidateSignatureAndCopyInfo(path, options, info);
    int result = MISValidateSignatureAndCopyInfo(path, widened, info);
    CFRelease(widened);
    vpLogValidation(path, result, caller);
    return result;
}

static int vpMISValidateSignatureAndCopyInfoWithProgress(
    MISPath path,
    CFDictionaryRef options,
    CFDictionaryRef *info,
    void *progress
) {
    const char *caller = MISFixCaller();
    CFDictionaryRef widened = vpWidenedOptions(options);
    if (widened == NULL)
        return MISValidateSignatureAndCopyInfoWithProgress(path, options, info, progress);
    int result = MISValidateSignatureAndCopyInfoWithProgress(path, widened, info, progress);
    CFRelease(widened);
    vpLogValidation(path, result, caller);
    return result;
}

// Both entry points are replaced. The plain one is what MobileInstallation
// calls; the progress variant is where libmis's own body lives, and a future
// caller that reaches for it directly gets the same treatment.
MISFIX_INTERPOSE(vpMISValidateSignatureAndCopyInfo, MISValidateSignatureAndCopyInfo);
MISFIX_INTERPOSE(vpMISValidateSignatureAndCopyInfoWithProgress, MISValidateSignatureAndCopyInfoWithProgress);
