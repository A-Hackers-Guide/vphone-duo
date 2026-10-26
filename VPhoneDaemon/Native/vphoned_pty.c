#include "vphoned_session.h"

#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

// The worker's side of a session: it spawns its own executable again so the
// script runs with vphoned's signature and entitlements, and keeps it in
// another process so a script that crashes or wedges takes only itself down.

/// What one session may hand back. Past this a script is misusing the API
/// rather than reporting something, and the worker must not grow with it.
#define VP_COLLECT_LIMIT (8u << 20)

static void vp_ignore_broken_pipe(void) {
    // Writing to a child that has already gone must report EPIPE rather than
    // end the process. The worker runs NIO, which ignores SIGPIPE itself, but
    // a session process has only this: `proc.run` on a program that exits
    // before reading its input would otherwise kill the session.
    signal(SIGPIPE, SIG_IGN);
}

static void vp_prepare_spawning(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, vp_ignore_broken_pipe);
}

/// Keep a descriptor out of children started elsewhere in the worker. The
/// spawns here pass POSIX_SPAWN_CLOEXEC_DEFAULT, but two others in the daemon
/// pass no file actions at all, and a child of theirs that inherited one end
/// of a session's pipe would hold it open: an eval would then wait out its
/// whole timeout for an end of file that cannot arrive, and an interactive
/// session's terminal would never report that the session had ended, leaving
/// its reader waiting for good. Setting the flag right after the descriptor
/// exists leaves a window of a few instructions, which is as narrow as it
/// gets without an atomic pipe2 to open them with. The file actions below
/// dup2 onto 0, 1 and 2, which clears the flag for the child meant to have
/// them.
static void vp_keep_from_children(int descriptor) {
    if (descriptor < 0) return;
    int flags = fcntl(descriptor, F_GETFD);
    if (flags >= 0) fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
}

// MARK: - Buffers

struct vp_buffer {
    char *data;
    size_t length;
    size_t capacity;
};

static bool vp_buffer_append(struct vp_buffer *buffer, const char *bytes, size_t count) {
    if (buffer->length + count + 1 > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity * 2 : 8192;
        while (capacity < buffer->length + count + 1) capacity *= 2;
        char *grown = realloc(buffer->data, capacity);
        if (!grown) return false;
        buffer->data = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, bytes, count);
    buffer->length += count;
    buffer->data[buffer->length] = '\0';
    return true;
}

/// The buffer's bytes as a C string, or an empty one, and the buffer is spent.
static char *vp_buffer_finish(struct vp_buffer *buffer) {
    if (buffer->data) {
        char *data = buffer->data;
        *buffer = (struct vp_buffer){0};
        return data;
    }
    return strdup("");
}

// MARK: - Clock

static double vp_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

// MARK: - Pumping a Child

/// Feed `input` in and collect both outputs until each closes. `timeout` is
/// seconds, or 0 to wait as long as the child takes. Returns 0, or ETIMEDOUT
/// with whatever arrived so far kept.
///
/// Every descriptor passed in is closed before this returns, on the timeout
/// and error paths as much as on the ordinary one. A caller cannot close them
/// itself without racing the child it is still waiting for, and an eval that
/// timed out would otherwise leave the worker one descriptor short each time
/// until it could no longer accept a connection.
static int vp_pump(int input_fd, const char *input, int output_fd, struct vp_buffer *output,
                   int errors_fd, struct vp_buffer *errors, double timeout) {
    int result = 0;
    size_t written = 0;
    size_t remaining = input ? strlen(input) : 0;
    if (input_fd >= 0 && remaining == 0) {
        close(input_fd);
        input_fd = -1;
    }
    double deadline = timeout > 0 ? vp_now() + timeout : 0;

    while (input_fd >= 0 || output_fd >= 0 || errors_fd >= 0) {
        struct pollfd watched[3];
        int slots[3];
        int count = 0;
        if (input_fd >= 0) {
            watched[count] = (struct pollfd){.fd = input_fd, .events = POLLOUT};
            slots[count++] = 0;
        }
        if (output_fd >= 0) {
            watched[count] = (struct pollfd){.fd = output_fd, .events = POLLIN};
            slots[count++] = 1;
        }
        if (errors_fd >= 0) {
            watched[count] = (struct pollfd){.fd = errors_fd, .events = POLLIN};
            slots[count++] = 2;
        }

        int wait_ms = -1;
        if (deadline > 0) {
            double left = deadline - vp_now();
            if (left <= 0) {
                result = ETIMEDOUT;
                goto done;
            }
            wait_ms = (int)(left * 1000) + 1;
        }
        int ready = poll(watched, (nfds_t)count, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            result = errno;
            goto done;
        }
        if (ready == 0) {
            result = ETIMEDOUT;
            goto done;
        }

        for (int index = 0; index < count; index++) {
            short events = watched[index].revents;
            if (!events) continue;
            if (slots[index] == 0) {
                // Nothing is reading any more: there is no one left to send
                // the rest to, and writing would only raise EPIPE.
                bool done = (events & (POLLERR | POLLHUP)) != 0;
                if (!done) {
                    ssize_t sent = write(input_fd, input + written, remaining - written);
                    if (sent > 0) written += (size_t)sent;
                    done = sent == 0 || (sent < 0 && errno != EINTR && errno != EAGAIN) ||
                           written >= remaining;
                }
                if (done) {
                    close(input_fd);
                    input_fd = -1;
                }
                continue;
            }
            int *source = slots[index] == 1 ? &output_fd : &errors_fd;
            struct vp_buffer *sink = slots[index] == 1 ? output : errors;
            char bytes[16384];
            ssize_t read_count = read(*source, bytes, sizeof(bytes));
            if (read_count > 0) {
                if (sink->length < VP_COLLECT_LIMIT) {
                    if (!vp_buffer_append(sink, bytes, (size_t)read_count)) {
                        result = ENOMEM;
                        goto done;
                    }
                }
                continue;
            }
            if (read_count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            close(*source);
            *source = -1;
        }
    }
done:
    if (input_fd >= 0) close(input_fd);
    if (output_fd >= 0) close(output_fd);
    if (errors_fd >= 0) close(errors_fd);
    return result;
}

static void vp_reap(pid_t pid, int *status) {
    int collected = 0;
    while (waitpid(pid, &collected, 0) < 0 && errno == EINTR) {}
    if (status) *status = collected;
}

// MARK: - Running One Program

int vp_spawn_collect(const char *path, const char *const *argv, const char *input,
                     int *status, char **output, char **errors) {
    vp_prepare_spawning();
    if (output) *output = NULL;
    if (errors) *errors = NULL;
    int in[2] = {-1, -1};
    int out[2] = {-1, -1};
    int err[2] = {-1, -1};
    if (pipe(in) != 0) return errno;
    if (pipe(out) != 0 || pipe(err) != 0) {
        int failure = errno;
        for (int index = 0; index < 2; index++) {
            if (in[index] >= 0) close(in[index]);
            if (out[index] >= 0) close(out[index]);
            if (err[index] >= 0) close(err[index]);
        }
        return failure;
    }
    for (int index = 0; index < 2; index++) {
        vp_keep_from_children(in[index]);
        vp_keep_from_children(out[index]);
        vp_keep_from_children(err[index]);
    }

    posix_spawn_file_actions_t actions;
    vp_spawn_file_actions_init(&actions);
    vp_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    vp_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    vp_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO);
    posix_spawnattr_t attributes;
    vp_spawnattr_init(&attributes);
    // Only the three descriptors above reach the child: vphoned holds the
    // VSOCK listener and every client connection.
    vp_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t child = -1;
    int failure = vp_spawn(&child, path, &actions, &attributes, (char *const *)argv, environ);
    vp_spawn_file_actions_destroy(&actions);
    vp_spawnattr_destroy(&attributes);
    close(in[0]);
    close(out[1]);
    close(err[1]);
    if (failure != 0) {
        close(in[1]);
        close(out[0]);
        close(err[0]);
        return failure;
    }

    struct vp_buffer collected = {0};
    struct vp_buffer problems = {0};
    int pumped = vp_pump(in[1], input, out[0], &collected, err[0], &problems, 0);
    vp_reap(child, status);
    if (output) *output = vp_buffer_finish(&collected);
    else free(collected.data);
    if (errors) *errors = vp_buffer_finish(&problems);
    else free(problems.data);
    return pumped == ETIMEDOUT ? 0 : pumped;
}

// MARK: - Session Processes

/// vphoned's own path, which may be the verified copy in the cache rather
/// than the installed binary, so a session is always the same image.
static bool vp_own_executable(char *path, size_t size) {
    uint32_t length = (uint32_t)size;
    return _NSGetExecutablePath(path, &length) == 0;
}

int vp_session_open(const char *program, int columns, int rows, pid_t *pid) {
    vp_prepare_spawning();
    char executable[4096];
    if (!vp_own_executable(executable, sizeof(executable))) {
        errno = ENOENT;
        return -1;
    }
    struct winsize size = {
        .ws_col = (unsigned short)(columns > 0 && columns < 10000 ? columns : 80),
        .ws_row = (unsigned short)(rows > 0 && rows < 10000 ? rows : 24),
    };
    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &size) != 0) return -1;
    vp_keep_from_children(master);
    vp_keep_from_children(slave);

    posix_spawn_file_actions_t actions;
    vp_spawn_file_actions_init(&actions);
    vp_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO);
    vp_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO);
    vp_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO);
    posix_spawnattr_t attributes;
    vp_spawnattr_init(&attributes);
    vp_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

    char *arguments[5];
    int count = 0;
    arguments[count++] = executable;
    arguments[count++] = "--session";
    if (program) {
        arguments[count++] = "exec";
        arguments[count++] = (char *)program;
    } else {
        arguments[count++] = "repl";
    }
    arguments[count] = NULL;

    pid_t child = -1;
    int failure = vp_spawn(&child, executable, &actions, &attributes, arguments, environ);
    vp_spawn_file_actions_destroy(&actions);
    vp_spawnattr_destroy(&attributes);
    close(slave);
    if (failure != 0) {
        close(master);
        errno = failure;
        return -1;
    }
    if (pid) *pid = child;
    return master;
}

void vp_session_resize(int master, int columns, int rows) {
    if (master < 0 || columns <= 0 || rows <= 0 || columns >= 10000 || rows >= 10000) return;
    struct winsize size = {.ws_col = (unsigned short)columns, .ws_row = (unsigned short)rows};
    // The terminal driver signals the foreground group itself, which is how
    // a program inside the session learns its window changed.
    ioctl(master, TIOCSWINSZ, &size);
}

/// A session leads its own process group, so the whole tree it started is
/// signalled with it. The pid is only a group while the session is alive and
/// unreaped; afterwards the number belongs to whatever the guest starts next,
/// which is why every caller signals before it reaps.
int vp_session_close(int master, pid_t pid, double grace) {
    if (master >= 0) {
        // Hanging the terminal up is what ends a well-behaved session: the
        // REPL reads EOF and the signal reaches anything it started.
        close(master);
    }
    if (pid <= 0) return -1;
    kill(pid, SIGHUP);
    kill(-pid, SIGHUP);

    double deadline = vp_now() + (grace > 0 ? grace : 2);
    for (;;) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) return status;
        if (waited < 0 && errno != EINTR) return -1;
        if (vp_now() >= deadline) break;
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000};
        nanosleep(&delay, NULL);
    }
    kill(pid, SIGKILL);
    kill(-pid, SIGKILL);
    int status = 0;
    vp_reap(pid, &status);
    return status;
}

char *vp_session_evaluate(const char *source, double timeout, int *status) {
    vp_prepare_spawning();
    if (status) *status = -1;
    char executable[4096];
    if (!vp_own_executable(executable, sizeof(executable))) {
        errno = ENOENT;
        return NULL;
    }
    int in[2] = {-1, -1};
    int out[2] = {-1, -1};
    if (pipe(in) != 0) return NULL;
    if (pipe(out) != 0) {
        int failure = errno;
        close(in[0]);
        close(in[1]);
        errno = failure;
        return NULL;
    }
    for (int index = 0; index < 2; index++) {
        vp_keep_from_children(in[index]);
        vp_keep_from_children(out[index]);
    }

    posix_spawn_file_actions_t actions;
    vp_spawn_file_actions_init(&actions);
    vp_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    vp_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    // The session keeps vphoned's stderr: a crash report from a script belongs
    // in the guest log, and its stdout carries nothing but the reply.
    vp_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
    posix_spawnattr_t attributes;
    vp_spawnattr_init(&attributes);
    vp_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);

    char *arguments[] = {executable, "--session", "eval", NULL};
    pid_t child = -1;
    int failure = vp_spawn(&child, executable, &actions, &attributes, arguments, environ);
    vp_spawn_file_actions_destroy(&actions);
    vp_spawnattr_destroy(&attributes);
    close(in[0]);
    close(out[1]);
    if (failure != 0) {
        close(in[1]);
        close(out[0]);
        errno = failure;
        return NULL;
    }

    struct vp_buffer collected = {0};
    int pumped = vp_pump(in[1], source, out[0], &collected, -1, NULL, timeout);
    if (pumped == ETIMEDOUT) {
        // The group, so a program the script started dies with it rather
        // than outliving the session as an orphan.
        kill(child, SIGKILL);
        kill(-child, SIGKILL);
    }
    vp_reap(child, status);
    if (pumped == ETIMEDOUT) {
        free(collected.data);
        errno = ETIMEDOUT;
        return NULL;
    }
    return vp_buffer_finish(&collected);
}
