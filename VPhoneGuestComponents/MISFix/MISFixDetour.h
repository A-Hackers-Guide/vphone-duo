// MISFixDetour.h — replace a function, not its call sites.
//
// `__DATA,__interpose` rewrites the places that *call* a symbol, in the images
// dyld links. It never reaches a call made from one shared-cache image to
// another, which is measured in MISFixDeviceIdentity.c and is the reason
// libmisfix cannot touch installd: `MobileInstallation → libmis →
// libMobileGestalt` happens entirely inside the cache.
//
// A detour rewrites the *callee*. The first four instructions of the target
// become an absolute jump to the replacement, and those four instructions are
// moved to a trampoline that jumps back. Every caller is then redirected,
// wherever it lives, because there is only one copy of the function.
//
// What it costs, and what it therefore refuses to guess about:
//
//   - The target's page must be made writable. The cache is mapped
//     read-execute and shared with every process, so the only way in is
//     copy-on-write, and whether this guest's kernel permits that is a
//     property of its codesigning patches. `MISFixCacheWriteProbe.c` measures
//     it; this file reports failure rather than assuming.
//   - The displaced instructions must survive being moved. `adr` and `adrp`
//     are rewritten to materialise the same absolute address, and an
//     unconditional `b` becomes an absolute jump. Anything else PC-relative —
//     `bl`, `b.cond`, `cbz`, `tbz`, a literal load — is **refused**, because a
//     wrong relocation is a corrupted daemon and a refusal is a log line.
//
// Install detours from a constructor. Four words cannot be replaced atomically,
// so a thread already executing the target's prologue is a hazard; at image
// load the process has not begun serving and that is as close to safe as this
// gets.

#ifndef MISFIX_DETOUR_H
#define MISFIX_DETOUR_H

/// Why a detour was not installed. `MISFixDetourOK` is zero.
typedef enum {
    MISFixDetourOK = 0,
    /// The image is not mapped in this process.
    MISFixDetourImageMissing,
    /// The image is mapped but exports no such symbol.
    MISFixDetourSymbolMissing,
    /// The symbol resolved into libmisfix itself. Refused: dyld applies
    /// interposing to `dlsym`, so a hooked symbol can resolve to our own
    /// replacement and a detour would point at itself.
    MISFixDetourSymbolIsOurs,
    /// A displaced instruction is PC-relative in a way this does not rewrite.
    MISFixDetourUnrelocatable,
    /// No executable memory could be obtained for the trampoline.
    MISFixDetourNoTrampoline,
    /// The target's page could not be made writable.
    MISFixDetourPageReadOnly,
    /// The bytes did not read back as written.
    MISFixDetourWriteFailed,
} MISFixDetourResult;

/// A sentence for the log, never NULL.
const char *MISFixDetourDescribe(MISFixDetourResult result);

/// Point `symbol` of `image` at `replacement`.
///
/// On success `*original` receives a pointer that behaves as the untouched
/// function did, already signed for an arm64e indirect call, and the
/// replacement calls through it for everything it does not mean to change.
/// On failure nothing is written and `*original` is left alone.
///
/// `image` is an install name, resolved with `RTLD_NOLOAD`: a detour is only
/// meaningful for an image this process already has.
MISFixDetourResult MISFixDetour(
    const char *image,
    const char *symbol,
    void *replacement,
    void **original
);

#endif
