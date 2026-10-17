#include "VPhoneMachMessage.h"
#include <stdint.h>

typedef uint64_t vp_mach_msg_option64_t;

extern mach_msg_return_t mach_msg2_internal(void *data,
    vp_mach_msg_option64_t options, uint64_t bits_and_send_size,
    uint64_t remote_and_local_port, uint64_t voucher_and_id,
    uint64_t descriptor_count_and_receive_name,
    uint64_t receive_size_and_priority, uint64_t timeout);

enum {
    VP_MACH64_SEND_KOBJECT_CALL = 0x0000000200000000ULL,
};

static uint64_t vp_pair(uint32_t low, uint32_t high) {
    return (uint64_t)high << 32 | low;
}

mach_msg_return_t vp_mach_msg_kobject(mach_msg_header_t *message,
    mach_msg_option_t options, mach_msg_size_t send_size,
    mach_msg_size_t receive_size, mach_port_name_t receive_name,
    mach_msg_timeout_t timeout, mach_port_name_t notify) {
    uint32_t descriptors = 0;
    if ((options & MACH_SEND_MSG) &&
        (message->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
        descriptors = ((mach_msg_base_t *)message)->body.msgh_descriptor_count;
    }
    uint32_t priority = (options & MACH_SEND_MSG) ? notify : 0;
    return mach_msg2_internal(message,
        (vp_mach_msg_option64_t)options | VP_MACH64_SEND_KOBJECT_CALL,
        vp_pair(message->msgh_bits, send_size),
        vp_pair(message->msgh_remote_port, message->msgh_local_port),
        vp_pair(message->msgh_voucher_port, message->msgh_id),
        vp_pair(descriptors, receive_name),
        vp_pair(receive_size, priority), timeout);
}
