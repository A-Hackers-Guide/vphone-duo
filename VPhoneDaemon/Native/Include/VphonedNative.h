#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

/// Sign all executable code in an extracted app. Returns a malloc-owned error or NULL.
char *vp_sign_app_for_install(const char *appPath, const char *certificatePath);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
/// 0 = launchd proxy, 1 = --io worker, -1 = invalid arguments.
int vp_native_process_mode(void);
int vp_native_run_proxy(void);
int vp_native_watch_proxy(void);
void vp_vcam_start(void);

/// Load the IOKit digitizer symbols used for multi-finger injection. Idempotent,
/// safe to call more than once; returns false (injection then stays a no-op)
/// on bases that do not expose the private symbols.
bool vp_hid_load(void);

/// Inject one two-finger digitizer event, the shape a trackpad pinch needs.
/// Phase is 0 = down, 1 = move, 3 = up; coordinates are normalized 0..1 with
/// the origin at the top-left. Neither icli's `input.touch` nor its
/// `touchSequence` can carry two fingers at once, which is why this exists.
void vp_hid_touch2(int phase, double x1, double y1, double x2, double y2);

typedef struct {
    int32_t pid;
    int32_t ppid;
    uint32_t uid;
    double start_time;
    double cpu_seconds;
    uint64_t footprint_bytes;
    uint64_t resident_bytes;
    bool has_task_info;
} VPProcessUsage;

/// Identity and resource usage for one process. Returns false when the process is gone.
bool vp_process_usage(int pid, VPProcessUsage *usage);

/// Make `serial` the USB serial string the host sees, re-enumerating only when
/// it changes or `force` is set (`*changed`). Returns a malloc-owned error or NULL.
char *vp_usb_set_serial(const char *serial, bool force, bool *changed);

/// The guest's own USB serial, built from `/chosen` `chip-id` and
/// `unique-chip-id`. malloc-owned, or NULL when the device tree lacks either.
char *vp_usb_own_serial(void);

#ifdef __OBJC__
/// Snapshot-local nested accessibility tree, using actual private iOS child links.
NSDictionary *vp_ax_hierarchy(int pid, int maxElements, int maxDepth, int timeoutMS);

/// `interface`'s IPv4 settings in configd's network preferences: `method`
/// (dhcp or manual), `address`, `subnet_mask`, `router`, `dns`, and `managed`
/// when vphoned wrote them. Nil with `*error` set when there is no such service.
NSDictionary *vp_network_ipv4_get(NSString *interface, NSString **error);

/// Set `interface` to `params` (`method` dhcp, or manual with `address`,
/// `subnet_mask`, `router` and `dns`), commit and apply. DHCP only undoes a
/// manual setting vphoned made. Returns the result of `vp_network_ipv4_get`
/// plus `changed`.
NSDictionary *vp_network_ipv4_set(NSString *interface, NSDictionary *params, NSString **error);

/// The guest's mDNS name (`local_host_name`, null when unset) and whether
/// vphoned set it (`managed`).
NSDictionary *vp_network_hostname_get(NSString **error);

/// Set the mDNS name, or with nil put back the one vphoned replaced. Only a
/// name vphoned set is ever undone. Returns the get result plus `changed`.
NSDictionary *vp_network_hostname_set(NSString *name, NSString **error);
#endif
