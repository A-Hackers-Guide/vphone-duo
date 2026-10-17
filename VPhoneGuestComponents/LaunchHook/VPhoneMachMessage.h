#ifndef VPHONE_MACH_MESSAGE_H
#define VPHONE_MACH_MESSAGE_H

#include <mach/message.h>

/// Sends MIG requests through the kernel-kobject IPC path.
mach_msg_return_t vp_mach_msg_kobject(mach_msg_header_t *message,
    mach_msg_option_t options, mach_msg_size_t send_size,
    mach_msg_size_t receive_size, mach_port_name_t receive_name,
    mach_msg_timeout_t timeout, mach_port_name_t notify);

#endif
