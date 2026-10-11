/* Test-only syscall failures at the actual guardian and capture boundaries. */
#include <errno.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
pid_t __real_waitpid(pid_t pid, int *status, int options);
ssize_t __real_read(int fd, void *buffer, size_t count);
pid_t __wrap_waitpid(pid_t pid, int *status, int options) {
    static unsigned failures;
    const char *marker = getenv("LEAF_SPLIT_FAULT_WAIT");
    if (pid == -1 && marker && access(marker, F_OK) == 0 && failures++ < 3) {
        errno = EINVAL;
        return -1;
    }
    return __real_waitpid(pid, status, options);
}
ssize_t __wrap_read(int fd, void *buffer, size_t count) {
    static unsigned failures;
    if (count == 8192 && getenv("LEAF_SPLIT_FAULT_READ") && failures++ == 0) {
        errno = EIO;
        return -1;
    }
    return __real_read(fd, buffer, count);
}
