#ifndef CHIP_STORAGE_H
#define CHIP_STORAGE_H
#include <stddef.h>
#include <stdint.h>
/* CHWAD001, LE length, LE header size (64), SHA-256, 16 zero bytes. */
#define STORAGE_HEADER_SIZE 64u
struct storage { const uint8_t *data; size_t size; };
int storage_open_ram(struct storage *out, const void *base, size_t capacity);
size_t storage_read(const struct storage *storage, size_t offset,
                    void *buffer, size_t length);
#endif
