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
#include <mach/mach.h>
#include <ptrauth.h>
#include <stdint.h>
#include <string.h>

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
/// Execute is asked for alongside write, not traded against it.
///
/// Dropping it is what killed the first run: a page that loses `VM_PROT_EXECUTE`
/// faults on the next instruction fetched from it, and on a page holding live
/// code that is immediate. A detour has the same problem for a different
/// reason — another thread may be inside the function being rewritten — so
/// RWX is what it would ask for too, and this measures the thing that matters.
static kern_return_t vpMakeWritable(vm_address_t address, vm_size_t length) {
    return vm_protect(
        mach_task_self(),
        address,
        length,
        FALSE,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY
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

__attribute__((constructor)) static void vpProbeCacheWrite(void) {
    if (!MISFixConfiguredFlag(kMISFixProbeCacheWriteKey))
        return;

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
    if (dladdr((const void *)(uintptr_t)&vpProbeCacheWrite, &self) != 0
        && self.dli_fbase != NULL)
    {
        Dl_info target;
        if (dladdr(function, &target) != 0 && target.dli_fbase == self.dli_fbase) {
            MISFixNote("probe: %s resolved into libmisfix itself — refusing", kProbeSymbol);
            return;
        }
    }

    // Page alignment, because protection is a per-page property and asking
    // about four bytes would silently widen to the page anyway.
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)(uintptr_t)function & ~(vm_address_t)(page - 1);
    vpDescribeRegion(start);

    uint8_t before[kProbeLength];
    memcpy(before, function, sizeof(before));

    kern_return_t opened = vpMakeWritable(start, page);
    if (opened != KERN_SUCCESS) {
        MISFixNote("probe: vm_protect(rwx|copy) failed: %s — a detour is not possible here",
                   mach_error_string(opened));
        return;
    }
    MISFixNote("probe: vm_protect(rwx|copy) succeeded");
    vpDescribeRegion(start);

    // The same bytes, written back. Nothing about this process's behaviour
    // changes whether it lands or not; only whether it lands is interesting.
    memcpy((void *)(uintptr_t)function, before, sizeof(before));

    uint8_t after[kProbeLength];
    memcpy(after, function, sizeof(after));
    int identical = memcmp(before, after, sizeof(before)) == 0;

    kern_return_t closed = vpRestore(start, page);
    MISFixNote(
        "probe: wrote %u bytes, readback %s, restore r-x %s — a detour %s possible here",
        kProbeLength,
        identical ? "matches" : "DIFFERS",
        closed == KERN_SUCCESS ? "ok" : mach_error_string(closed),
        identical && closed == KERN_SUCCESS ? "is" : "may not be"
    );
}
