// MISFixInstallPolicy.c — the two places installd refuses an app for a reason
// that does not apply to this guest.
//
// MISFixSignature.c widens what MIS itself will accept. This file is what sits
// above MIS: MobileInstallation's own policy, which asks for things a research
// VM cannot have and then treats their absence as a failed install.
//
// Both hooks call the real implementation first and only override a refusal,
// so on anything that would have installed anyway the behaviour is unchanged.
//
// ## The embedded profile
//
//     Failed to install embedded profile for plus.yellow.AirBuild : 0xE8008012
//       (This provisioning profile cannot be installed on this device.)
//       -[MIInstallableBundle _installEmbeddedProfilesWithError:]
//
// `0xE8008012` is correct and always will be. A profile names the devices it
// covers, in `ProvisionedDevices`, and a VM's UDID is in nobody's list. Xcode
// papers over that for a *free* personal team by registering whatever device
// is plugged in; for a paid team there is no auto-registration, and the VM
// would have to be added to the account by hand and again after every
// `vm create`.
//
// A profile does two things — it vouches that a signing identity may run on
// this device, and it carries the entitlements the app may claim — and neither
// is load-bearing here. The kernel patches admit the code whatever signed it,
// and MIS has already validated the bundle on its own signature with
// `ValidatedByProfile = 0`. So a profile that cannot install is noted and
// skipped; one that can install still does, unchanged.
//
// ## The signer identity
//
//     Failed to extract signer identity from <MIExecutableBundle …>
//       -[MICodeSigningVerifier performValidationWithError:]  line 424
//
// This is the gate behind the gate, and it is why widening MIS's options is
// not by itself enough. MIS accepts an ad-hoc signature and fills its info
// dictionary — `CdHash`, `Entitlements`, `SigningID` — but MobileInstallation
// then wants a *signer*: the leaf certificate out of a CMS blob, which an
// ad-hoc signature does not have and never will, because the whole point of
// ad-hoc is that nobody signed it.
//
// Measured on test-26.4 (2026-09-30) with a `codesign --sign -` bundle:
// `MISValidateSignature(…/SignTest.app) -> 0x0`, and the install still failed,
// here, at line 424 with `LibMISErrorNumber = -402620415`.
//
// There is nothing to widen and nothing to supply. The decision itself is what
// has to change, and this is the decision the guest is entitled to make
// differently: it runs unsigned code on purpose. So validation is allowed to
// fail and the install proceeds. Everything the verifier *could* determine has
// already been determined by the time it gets to the signer — the real
// implementation runs first, and fails late.
//
// ## Why a swizzle and not a detour
//
// Both are Objective-C methods in MobileInstallation, and an Objective-C
// method list is *data*. Replacing an implementation through the runtime
// reaches every caller, in the shared cache or out of it, without making a
// single page of cache text writable. Where that is available it is strictly
// better than MISFixDetour.h, and here it is available.
//
// The classes are looked up rather than linked, and a version that does not
// have one leaves that hook inert with a line in the log. That is deliberate:
// these are private methods on private classes, and the guest is expected to
// be a version this project has not seen yet.

#include "MISFixConfig.h"

#include <dlfcn.h>
#include <objc/objc.h>
#include <objc/runtime.h>

/// MobileInstallation's install name, for the case where a class is not
/// registered yet. Our constructor runs among the inserted libraries, ahead of
/// most of the process; every image present at launch has had its classes
/// realised by then, but a framework installd only dlopens later would not be
/// there at all.
#define kMISFixMobileInstallationPath \
    "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

/// The shape both hooks have: a `BOOL`-returning method whose only argument is
/// an `NSError **` out-parameter.
typedef BOOL (*MISFixCheckIMP)(id self, SEL selector, void *error);

/// Replace `class`'s `-selector` with `replacement`, keeping the original.
///
/// Returns zero and logs when there is no such class or method, which is the
/// expected outcome on an OS version that renamed one.
static int vpSwizzle(
    const char *className,
    const char *selectorName,
    MISFixCheckIMP replacement,
    MISFixCheckIMP *original
) {
    Class found = objc_getClass(className);
    if (found == NULL) {
        if (dlopen(kMISFixMobileInstallationPath, RTLD_LAZY) != NULL)
            found = objc_getClass(className);
    }
    if (found == NULL) {
        MISFixNote("%s is not in this process", className);
        return 0;
    }
    Method method = class_getInstanceMethod(found, sel_registerName(selectorName));
    if (method == NULL) {
        MISFixNote("%s has no -%s", className, selectorName);
        return 0;
    }
    *original = (MISFixCheckIMP)method_setImplementation(method, (IMP)replacement);
    MISFixNote("swizzled -[%s %s]", className, selectorName);
    return 1;
}

/// Clear an `NSError **` the failing implementation wrote.
///
/// A caller handed `YES` alongside a populated `NSError *` is a shape no
/// ordinary method produces, and installd does read the out-parameter. The
/// error object itself is left to the autorelease pool it came from.
static void vpClearError(void *error) {
    if (error != NULL)
        *(void **)error = NULL;
}

// MARK: - The embedded profile

static MISFixCheckIMP vpOriginalInstallProfiles;

static BOOL vpInstallEmbeddedProfiles(id self, SEL selector, void *error) {
    if (vpOriginalInstallProfiles(self, selector, error))
        return YES;
    vpClearError(error);
    MISFixNote("embedded profile refused; installing without one");
    return YES;
}

// MARK: - The signer identity

static MISFixCheckIMP vpOriginalPerformValidation;

static BOOL vpPerformValidation(id self, SEL selector, void *error) {
    if (vpOriginalPerformValidation(self, selector, error))
        return YES;
    vpClearError(error);
    MISFixNote("code-signing validation refused; installing anyway");
    return YES;
}

__attribute__((constructor)) static void vpInstallPolicyHooks(void) {
    vpSwizzle(
        "MIInstallableBundle",
        "_installEmbeddedProfilesWithError:",
        &vpInstallEmbeddedProfiles,
        &vpOriginalInstallProfiles
    );
    vpSwizzle(
        "MICodeSigningVerifier",
        "performValidationWithError:",
        &vpPerformValidation,
        &vpOriginalPerformValidation
    );
}
