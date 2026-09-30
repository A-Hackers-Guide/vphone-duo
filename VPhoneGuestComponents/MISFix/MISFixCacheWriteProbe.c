// MISFixCacheWriteProbe.c — can this process write a shared-cache text page?
//
// One question, asked at load, behind the `ProbeCacheWrite` flag, and it
// decides how the whole MIS problem gets fixed.
//
// `__DATA,__interpose` rewrites *call sites* in the images dyld links, so it
// never reaches a call made from one shared-cache image to another — measured
// in MISFixDeviceIdentity.c, and the reason libmisfix cannot touch installd's
// profile check. Rewriting the *callee* instead would reach every caller,
// inside the cache or out: the classic five-instruction detour at the top of
// `MGCopyAnswer` and `MISValidateSignatureAndCopyInfo`, with the displaced
// instructions moved to a trampoline.
//
// That costs a few hundred lines of arm64e relocation work, and all of it is
// wasted unless the process can make a cache text page writable first. The
// cache is mapped read-execute and shared by every process on the system, so
// the only way in is copy-on-write: ask for `VM_PROT_COPY` and get a private
// copy of that page. Whether the kernel allows it here depends on this guest's
// codesigning patches, not on anything this dylib does — so it is measured,
// not assumed.
//
// ## What the probe does, and what it deliberately does not
//
// It writes the bytes that are already there. The four bytes at the top of
// `MGCopyAnswer` are read, the page is made writable *without giving up
// execute*, those same four bytes are written back, the result is read again
// and compared, and the page is put back to read-execute. A run that succeeds
// completely leaves the process byte-for-byte as it found it; a run that fails
// anywhere leaves it as it found it too, because nothing different was ever
// written.
//
// Two mistakes from the first run are guarded against by name, because both
// are easy to make again and both crash a daemon that installs software:
// resolving the symbol through `RTLD_DEFAULT` (interposed — it returns this
// dylib's own replacement), and asking for write *instead of* execute on a
// page holding live code.
//
// The region's current and maximum protections are logged first. That is the
// cheap half of the answer: a region whose `max_protection` carries no write
// bit can never be made writable, and no amount of entitlement changes that.
//
// The probe never touches `MISValidateSignatureAndCopyInfo`, and never leaves
// a page writable. Making a real detour is a separate change, and it should
// not be able to happen by accident in a daemon that installs software.

#include "MISFixConfig.h"

// The iPhoneOS SDK refuses `mach/mach_vm.h` outright, so this uses the
// `vm_*` entry points in `mach/vm_map.h` instead. On arm64 they take the same
// 64-bit addresses and sizes; only the names differ.
#include <dlfcn.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

/// The symbol the probe stands on. Exported by libMobileGestalt, in the shared
/// cache, and the one a real detour would go on first.
#define kProbeSymbol "MGCopyAnswer"

/// The image it must come out of. Named explicitly, because the obvious way to
/// resolve the symbol is wrong: dyld applies interposing to `dlsym` as well as
/// to call sites, so `dlsym(RTLD_DEFAULT, "MGCopyAnswer")` returns *this
/// dylib's* replacement. The first run of this probe did exactly that, stripped
/// execute from the page it was executing on, and took installd down with it.
#define kProbeImage "/usr/lib/libMobileGestalt.dylib"

/// How many bytes the probe rewrites. One instruction: enough to prove the
/// page is writable, small enough that a partial write cannot straddle a page.
#define kProbeLength 4u

/// The region this address is in, logged for its protections.
///
/// `max_protection` is the half that cannot be argued with: it is the ceiling
/// `mach_vm_protect` may raise the current protection to, and a cache text
/// region that does not carry `VM_PROT_WRITE` in it rules the detour out
/// before any of the rest is tried.
static void vpDescribeRegion(vm_address_t address) {
    vm_address_t start = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(
        mach_task_self(),
        &start,
        &size,
        VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info,
        &count,
        &object
    );
    if (result != KERN_SUCCESS) {
        MISFixNote("probe: vm_region_64 failed: %s", mach_error_string(result));
        return;
    }
    MISFixNote(
        "probe: region %p+%llx prot=%x max=%x shared=%d reserved=%d",
        (void *)start,
        (unsigned long long)size,
        info.protection,
        info.max_protection,
        info.shared,
        info.reserved
    );
}

/// Try to make `length` bytes at `address` writable, and say how it went.
///
/// `VM_PROT_COPY` is the whole point: without it the request is "let this
/// shared mapping be written", which the kernel refuses for a region other
/// processes have mapped. With it, the request is "give me my own copy of
/// these pages, writable", which is what a detour needs and what leaves every
/// other process on the system untouched.
/// Write, without execute. Measured, both ways round, and this is the way that
/// works.
///
/// Asking for RWX succeeds at the VM layer — the region comes back `prot=7`,
/// `max=7` — and then the store still faults:
///
///     EXC_BAD_ACCESS (SIGBUS), UNKNOWN_0x32 at 0x1027543dc
///     __TEXT 102754000-102758000 [16K] rwx/rwx SM=COW /usr/lib/libmisfix.dylib
///
/// Apple silicon enforces write-xor-execute in hardware below the VM
/// permissions, so a page that is writable *and* executable is writable only
/// to a thread that has said so. Dropping execute for the duration is the
/// simpler answer and the one a detour can use, because the page it rewrites
/// is not the page it is running from — that was the first run's mistake, and
/// the two failures look identical from outside, which is why both are
/// written down here.
static kern_return_t vpMakeWritable(vm_address_t address, vm_size_t length) {
    return vm_protect(
        mach_task_self(),
        address,
        length,
        FALSE,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    );
}

static kern_return_t vpRestore(vm_address_t address, vm_size_t length) {
    return vm_protect(
        mach_task_self(),
        address,
        length,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE
    );
}

/// Write back the four bytes already at `function`, and say whether they stuck.
///
/// Shared by both write steps, because "can this page be rewritten" is the
/// same question for the cache and for this dylib's own text, and the answer
/// may well differ.
static void vpProbeWriteAt(const char *what, const uint8_t *function) {
    // Page alignment, because protection is a per-page property and asking
    // about four bytes would silently widen to the page anyway.
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)(uintptr_t)function & ~(vm_address_t)(page - 1);
    vpDescribeRegion(start);

    uint8_t before[kProbeLength];
    memcpy(before, function, sizeof(before));

    kern_return_t opened = vpMakeWritable(start, page);
    if (opened != KERN_SUCCESS) {
        MISFixNote("probe: %s vm_protect(rw|copy) failed: %s", what, mach_error_string(opened));
        return;
    }
    MISFixNote("probe: %s vm_protect(rw|copy) succeeded, writing", what);
    vpDescribeRegion(start);

    // The same bytes, written back. Nothing about this process's behaviour
    // changes whether it lands or not; only whether it lands is interesting.
    memcpy((void *)(uintptr_t)function, before, sizeof(before));

    uint8_t after[kProbeLength];
    memcpy(after, function, sizeof(after));
    int identical = memcmp(before, after, sizeof(before)) == 0;

    kern_return_t closed = vpRestore(start, page);
    MISFixNote(
        "probe: %s wrote %u bytes, readback %s, restore r-x %s",
        what,
        kProbeLength,
        identical ? "matches" : "DIFFERS",
        closed == KERN_SUCCESS ? "ok" : mach_error_string(closed)
    );
}

/// `mov w0, #42 ; ret`, for the executable-memory step.
static const uint32_t kProbeThunk[] = { 0x52800540u, 0xD65F03C0u };
#define kProbeThunkAnswer 42

/// Can this process get memory it wrote and then run it?
///
/// The other half of what a detour needs. Rewriting the top of a function
/// costs nothing if the displaced instructions have nowhere to live: a
/// trampoline is memory this process fills in and then jumps to, which on iOS
/// is exactly what codesigning is there to prevent.
///
/// Both spellings are tried, write-then-`mprotect` first. That order is not
/// arbitrary: a page that is writable *and* executable at once is subject to
/// the same hardware write-xor-execute rule that made the cache write fault
/// with `SIGBUS` above, so the RWX spelling is the one expected to fail and it
/// goes second.
///
/// This step is last, and deliberately. It is the only part of the probe that
/// can take the process down — running a page the kernel has not blessed is a
/// kill, not an error return — so everything else is already in the log by the
/// time it runs.
static void vpProbeExecutableMemory(void) {
    for (int rwxAtOnce = 0; rwxAtOnce < 2; rwxAtOnce += 1) {
        int writeThenProtect = !rwxAtOnce;
        const char *how = writeThenProtect ? "rw then mprotect r-x" : "rwx from mmap";
        int protection = writeThenProtect ? (PROT_READ | PROT_WRITE)
                                          : (PROT_READ | PROT_WRITE | PROT_EXEC);
        void *page = mmap(NULL, vm_page_size, protection, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (page == MAP_FAILED) {
            MISFixNote("probe: mmap %s failed: %s", how, strerror(errno));
            continue;
        }
        memcpy(page, kProbeThunk, sizeof(kProbeThunk));
        if (writeThenProtect && mprotect(page, vm_page_size, PROT_READ | PROT_EXEC) != 0) {
            MISFixNote("probe: mprotect r-x failed: %s", strerror(errno));
            munmap(page, vm_page_size);
            continue;
        }
        sys_icache_invalidate(page, sizeof(kProbeThunk));
        MISFixNote("probe: %s mapped at %p, calling it", how, page);

        // Signed for the indirect call arm64e requires. If the kernel refuses
        // the page, this line does not return and the log above is the record.
        int (*thunk)(void) = ptrauth_sign_unauthenticated(
            (int (*)(void))page,
            ptrauth_key_function_pointer,
            0
        );
        int answer = thunk();
        munmap(page, vm_page_size);
        MISFixNote(
            "probe: %s returned %d (%s)",
            how,
            answer,
            answer == kProbeThunkAnswer ? "usable" : "WRONG"
        );
        if (answer == kProbeThunkAnswer)
            return;
    }
}

/// Whether this process is the one the probe is allowed to run in.
///
/// installd, and only installd. SystemHook also inserts this dylib into
/// misagent and SpringBoard, and the executable-memory step can end the
/// process outright — in SpringBoard that is a respring, and a repeating one
/// while the flag is on. installd is on-demand and launchd starts it again for
/// the next client, so a kill there costs one failed install and nothing else.
static int vpProbeIsPermittedProcess(void) {
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0)
        return 0;
    static const char suffix[] = "/installd";
    size_t length = strlen(path);
    return length >= sizeof(suffix) - 1
        && strcmp(path + length - (sizeof(suffix) - 1), suffix) == 0;
}

__attribute__((constructor)) static void vpProbeCacheWrite(void) {
    if (!MISFixConfiguredFlag(kMISFixProbeCacheWriteKey))
        return;
    if (!vpProbeIsPermittedProcess())
        return;

    // This dylib's own text was measured here too, as a warm-up, and it is
    // gone: it is the one page that must never lose execute, because the probe
    // is running from it, and with execute kept the store faults under the
    // hardware's write-xor-execute rule. Both spellings crash, for opposite
    // reasons, and neither says anything about the page a detour targets. What
    // it did establish before crashing is worth keeping: copy-on-write works,
    // and the page came back `prot=7 max=7` as its own region.

    // RTLD_NOLOAD, because the answer is only interesting for an image already
    // mapped from the cache, and a handle-scoped dlsym is not interposed.
    void *image = dlopen(kProbeImage, RTLD_LAZY | RTLD_NOLOAD);
    if (image == NULL) {
        MISFixNote("probe: %s is not loaded here: %s", kProbeImage, dlerror());
        return;
    }
    void *symbol = dlsym(image, kProbeSymbol);
    dlclose(image);
    if (symbol == NULL) {
        MISFixNote("probe: %s not found in %s", kProbeSymbol, kProbeImage);
        return;
    }
    // A function pointer out of dlsym is signed on arm64e; the address the VM
    // functions want is the plain one.
    const uint8_t *function = ptrauth_strip(symbol, ptrauth_key_function_pointer);
    const char *owner = MISFixCallerImage(function);
    MISFixNote("probe: %s at %p in %s", kProbeSymbol, function, owner);

    // Last line of defence against the first run's mistake. Whatever the
    // resolution did, refuse to touch a page this dylib's own code is on.
    Dl_info self;
    if (dladdr(ptrauth_strip((const void *)&vpProbeCacheWrite, ptrauth_key_function_pointer),
               &self) != 0
        && self.dli_fbase != NULL)
    {
        Dl_info target;
        if (dladdr(function, &target) != 0 && target.dli_fbase == self.dli_fbase) {
            MISFixNote("probe: %s resolved into libmisfix itself — refusing", kProbeSymbol);
            return;
        }
    }

    vpProbeWriteAt("cache-text", function);

    vpProbeExecutableMemory();
    MISFixNote("probe: done");
}
