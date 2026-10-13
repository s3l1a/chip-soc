#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "platform.h"

void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest; const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dest;
}
void *memmove(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest; const unsigned char *s = src;
    if ((uintptr_t)d <= (uintptr_t)s) return memcpy(dest, src, n);
    while (n) { --n; d[n] = s[n]; }
    return dest;
}
void *memset(void *dest, int value, size_t n)
{
    unsigned char *d = dest;
    while (n--) *d++ = (unsigned char)value;
    return dest;
}
int memcmp(const void *left, const void *right, size_t n)
{
    const unsigned char *a = left, *b = right;
    while (n--) { if (*a != *b) return (int)*a - (int)*b; ++a; ++b; }
    return 0;
}
size_t strlen(const char *s)
{
    const char *end = s;
    while (*end) ++end;
    return (size_t)(end - s);
}
/* Diagnostic-only monotonic arena. Doom uses newlib's reclaiming allocator. */
extern unsigned char __heap_start[], __heap_end[];
void *malloc(size_t n)
{
    static uintptr_t next;
    if (!next) next = (uintptr_t)__heap_start;
    if (n > SIZE_MAX - 15u) return NULL;
    n = (n + 15u) & ~(size_t)15u;
    if (!n) n = 16;
    if (n > (uintptr_t)__heap_end - next) return NULL;
    void *result = (void *)next;
    next += n;
    return result;
}
void free(void *p) { (void)p; }
void *calloc(size_t count, size_t size)
{
    if (size && count > SIZE_MAX / size) return NULL;
    size_t n = count * size;
    void *p = malloc(n);
    if (p) memset(p, 0, n);
    return p;
}
_Noreturn void abort(void)
{
    uart_puts("abort\n"); platform_halt();
}
