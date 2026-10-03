#import <Foundation/Foundation.h>

#import "VphonedNative.h"

/*
 * Link-local IPv4 over the virtual iPhone's USB link.
 *
 * Besides its NIC (en0) a guest has the network link a USB-connected iPhone
 * gives the Mac: an Ethernet interface with a self-assigned 169.254 address.
 * The Mac answers mDNS there, so a lookup of the Mac's .local name lists the
 * Mac's 169.254 address on that link, and, being link-local, first. But iOS
 * routes 169.254.0.0/16 through the primary interface only, so a plain
 * connect() to that address leaves through en0, where nothing answers, and
 * waits out its timeout. (Network.framework binds to the interface the answer
 * came from and is not affected; BSD sockets are.)
 *
 * Two /17 routes through the USB link are more specific than the /16 on en0,
 * so they win without touching it. They are interface routes, as
 * `route add -net 169.254.0.0/17 -interface enN` makes, and go away when the
 * interface does.
 */

#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
// <net/route.h> is not in the iOS SDK. The routing socket's message layout
// is the kernel ABI, the same as macOS's (copied from its net/route.h).
struct vp_rt_metrics {
    u_int32_t rmx_locks, rmx_mtu, rmx_hopcount;
    int32_t rmx_expire;
    u_int32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar, rmx_pksent;
    u_int32_t rmx_filler[4];
};
struct vp_rt_msghdr {
    u_short rtm_msglen;
    u_char rtm_version;
    u_char rtm_type;
    u_short rtm_index;
    int rtm_flags;
    int rtm_addrs;
    pid_t rtm_pid;
    int rtm_seq;
    int rtm_errno;
    int rtm_use;
    u_int32_t rtm_inits;
    struct vp_rt_metrics rtm_rmx;
};
enum {
    VP_RTM_VERSION = 5, VP_RTM_ADD = 0x1, VP_RTM_DELETE = 0x2,
    VP_RTF_UP = 0x1, VP_RTF_STATIC = 0x800,
    VP_RTA_DST = 0x1, VP_RTA_GATEWAY = 0x2, VP_RTA_NETMASK = 0x4,
};
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

/// The interface other than `primary` with a 169.254 address: the USB link.
static NSString *vp_usb_link_interface(NSString *primary) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = @(entry->ifa_name);
        if ([name isEqualToString:primary] || ![name hasPrefix:@"en"]) continue;
        uint32_t address = ntohl(((struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr);
        if ((address & 0xFFFF0000) == 0xA9FE0000) {
            found = name;
            break;
        }
    }
    freeifaddrs(list);
    return found;
}

/// RTM_ADD or RTM_DELETE for `network`/17 as an interface route on `index`.
/// Returns 0, or the errno.
static int vp_route_message(int type, uint32_t network, unsigned int index) {
    int fd = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (fd < 0) return errno;

    struct {
        struct vp_rt_msghdr header;
        struct sockaddr_in destination;
        struct sockaddr_dl gateway;
        struct sockaddr_in netmask;
    } message;
    memset(&message, 0, sizeof(message));
    message.header.rtm_msglen = sizeof(message);
    message.header.rtm_version = VP_RTM_VERSION;
    message.header.rtm_type = type;
    message.header.rtm_flags = VP_RTF_UP | VP_RTF_STATIC;
    message.header.rtm_addrs = VP_RTA_DST | VP_RTA_GATEWAY | VP_RTA_NETMASK;
    message.header.rtm_pid = getpid();
    message.header.rtm_seq = 1;

    message.destination.sin_len = sizeof(struct sockaddr_in);
    message.destination.sin_family = AF_INET;
    message.destination.sin_addr.s_addr = htonl(network);
    message.gateway.sdl_len = sizeof(struct sockaddr_dl);
    message.gateway.sdl_family = AF_LINK;
    message.gateway.sdl_index = index;
    message.netmask.sin_len = sizeof(struct sockaddr_in);
    message.netmask.sin_family = AF_INET;
    message.netmask.sin_addr.s_addr = htonl(0xFFFF8000);

    int result = write(fd, &message, sizeof(message)) < 0 ? errno : 0;
    close(fd);
    return result;
}

NSDictionary *vp_network_usb_link_route_set(BOOL enabled, NSString *primary, NSString **error) {
    NSString *interface = vp_usb_link_interface(primary ?: @"en0");
    if (!interface) {
        if (error) *error = @"no USB link interface with a 169.254 address yet";
        return nil;
    }
    unsigned int index = if_nametoindex(interface.UTF8String);
    const uint32_t halves[2] = {0xA9FE0000, 0xA9FE8000};
    NSMutableArray *results = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        int code;
        if (enabled) {
            code = vp_route_message(VP_RTM_ADD, halves[i], index);
            // Already there: an interface's routes go with it, so an existing
            // one points at the link as it is now.
            if (code == EEXIST) code = 0;
        } else {
            code = vp_route_message(VP_RTM_DELETE, halves[i], 0);
            if (code == ESRCH) code = 0;
        }
        [results addObject:code == 0 ? @"ok" : @(strerror(code))];
    }
    return @{@"interface": interface, @"enabled": @(enabled), @"routes": results};
}
