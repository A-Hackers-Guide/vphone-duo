#ifndef VPHONE_X1_SPAWN_H
#define VPHONE_X1_SPAWN_H

#include <mach/mach.h>
#include <spawn.h>

typedef int (*VPX1SpawnFunction)(
    pid_t *restrict,
    const char *restrict,
    const posix_spawn_file_actions_t *restrict,
    const posix_spawnattr_t *restrict,
    char *const[restrict],
    char *const[restrict]
);

int vpSpawnWithInheritedX1Port(
    VPX1SpawnFunction spawn,
    pid_t *restrict pid,
    const char *restrict path,
    const posix_spawn_file_actions_t *restrict actions,
    const posix_spawnattr_t *restrict attributes,
    char *const argv[restrict],
    char *const envp[restrict]
);

int vpSetSpawnExceptionPortsPreservingX1(
    posix_spawnattr_t *attributes,
    exception_mask_t mask,
    mach_port_t port,
    exception_behavior_t behavior,
    thread_state_flavor_t flavor
);

#endif
