/* Read-only, single-file memory-mapped backend for newlib. No filesystem or SD. */
#include "platform.h"
#include "storage.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static struct storage wad;
static struct { int used; size_t position; } files[4];
extern unsigned char __heap_start[], __heap_end[];
void *_sbrk(ptrdiff_t increment)
{
    static uintptr_t end;
    if (!end) end = (uintptr_t)__heap_start;
    if ((increment >= 0 && (uintptr_t)increment > (uintptr_t)__heap_end - end) ||
        (increment < 0 && (uintptr_t)(-(increment + 1)) + 1 > end - (uintptr_t)__heap_start)) {
        errno = ENOMEM; return (void *)-1;
    }
    uintptr_t old = end;
    end += increment;
    return (void *)old;
}
int _open(const char *path, int flags, ...)
{
    if ((flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT | O_TRUNC | O_APPEND))) {
        errno = EROFS; return -1;
    }
    if (strcmp(path, "doom1.wad") && strcmp(path, "./doom1.wad")) {
        errno = ENOENT; return -1;
    }
    if (!wad.data && storage_open_ram(&wad, (const void *)(uintptr_t)WAD_BASE, WAD_CAPACITY)) {
        errno = EIO; return -1;
    }
    for (int i = 0; i < 4; ++i) {
        if (!files[i].used) { files[i].used = 1; files[i].position = 0; return i + 3; }
    }
    errno = EMFILE; return -1;
}
int _close(int fd)
{
    if (fd < 3 || fd >= 7 || !files[fd - 3].used) { errno = EBADF; return -1; }
    files[fd - 3].used = 0; return 0;
}
ssize_t _read(int fd, void *buffer, size_t length)
{
    if (fd == 0) {
        if (!length) return 0;
        int c; do { c = uart_getc(); } while (c < 0);
        *(unsigned char *)buffer = (unsigned char)c; return 1;
    }
    if (fd < 3 || fd >= 7 || !files[fd - 3].used) { errno = EBADF; return -1; }
    size_t n = storage_read(&wad, files[fd - 3].position, buffer, length);
    files[fd - 3].position += n; return (ssize_t)n;
}
ssize_t _write(int fd, const void *buffer, size_t length)
{
    if (fd != 1 && fd != 2) { errno = EROFS; return -1; }
    const char *p = buffer;
    for (size_t i = 0; i < length; ++i) uart_putc(p[i]);
    return (ssize_t)length;
}
off_t _lseek(int fd, off_t offset, int whence)
{
    if (fd < 3 || fd >= 7 || !files[fd - 3].used) { errno = EBADF; return -1; }
    int64_t origin;
    if (whence == SEEK_SET) origin = 0;
    else if (whence == SEEK_CUR) origin = files[fd - 3].position;
    else if (whence == SEEK_END) origin = wad.size;
    else { errno = EINVAL; return -1; }
    int64_t position = origin + offset;
    if (position < 0 || position > (int64_t)wad.size) { errno = EINVAL; return -1; }
    files[fd - 3].position = (size_t)position; return (off_t)position;
}
int _fstat(int fd, struct stat *st)
{
    memset(st, 0, sizeof(*st));
    if (fd >= 0 && fd <= 2) { st->st_mode = S_IFCHR; return 0; }
    if (fd < 3 || fd >= 7 || !files[fd - 3].used) { errno = EBADF; return -1; }
    st->st_mode = S_IFREG | 0444; st->st_size = (off_t)wad.size; return 0;
}
int _stat(const char *path, struct stat *st)
{
    int fd = _open(path, O_RDONLY);
    if (fd < 0) return -1;
    int result = _fstat(fd, st); _close(fd); return result;
}
int _isatty(int fd) { if (fd >= 0 && fd <= 2) return 1; errno = ENOTTY; return 0; }
int _getpid(void) { return 1; }
int _kill(int pid, int signal) { (void)pid; (void)signal; errno = ENOSYS; return -1; }
int _unlink(const char *path) { (void)path; errno = EROFS; return -1; }
int _link(const char *a, const char *b) { (void)a; (void)b; errno = EROFS; return -1; }
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; errno = EROFS; return -1; }
_Noreturn void _exit(int status)
{
    uart_puts("exit="); uart_hex((uint32_t)status); uart_putc('\n'); platform_halt();
}
