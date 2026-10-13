/* Test-only syscall failures and Darwin waitid encodings at the actual guardian
 * and capture boundaries. Each wrapper is compiled only for the build that
 * injects its --wrap flag, so no helper references an unresolved __real_*. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef LEAF_SPLIT_FAULT_TEST
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
#endif

#ifdef LEAF_SPLIT_DARWIN_WAITID
int __real_waitid(idtype_t idtype, id_t id, siginfo_t *infop, int options);
/*
 * Replays Darwin's waitid exit reporting, which Linux cannot produce.
 *
 * macOS stores the whole 32-bit exit value: waitid reports
 * `WEXITSTATUS(p_xstat) & 0x00FFFFFF` OR'ed with the once-only p_xhighbits
 * (xnu kern_exit.c, CLD_EXITED). Nim's quit saturates POSIX statuses to int8,
 * so leaf_cli.exitCli reports the conventional 130 as quit(-126): Darwin's
 * first inspection therefore yields -126, and any later inspection - the
 * kernel clears p_xhighbits even under WNOWAIT - yields 0x00FFFF82. Linux only
 * reports the low eight bits, so this wrapper rewrites the conventional 130
 * into one of those forms for the same child pid. LEAF_SPLIT_WAITID_FORM picks
 * which form the first inspection returns; later inspections always use the
 * cleared-high-bits form. Real signal mapping (SIGKILL -> 137) and every other
 * status stay untouched.
 */
int __wrap_waitid(idtype_t idtype, id_t id, siginfo_t *infop, int options) {
    static pid_t tracked[8];
    static unsigned calls[8];
    const char *form = getenv("LEAF_SPLIT_WAITID_FORM");
    unsigned index = 0;
    int result = __real_waitid(idtype, id, infop, options);
    if (result != 0 || infop == NULL || infop->si_code != CLD_EXITED ||
        infop->si_status != 130) {
        return result;
    }
    while (index < 8 && tracked[index] != 0 && tracked[index] != infop->si_pid) {
        index++;
    }
    if (index == 8) {
        return result;
    }
    tracked[index] = infop->si_pid;
    unsigned seen = calls[index]++;
    int cleared = seen > 0 || (form != NULL && strcmp(form, "cleared") == 0);
    infop->si_status = cleared ? 0x00FFFF82 : -126;
    return result;
}
#endif
