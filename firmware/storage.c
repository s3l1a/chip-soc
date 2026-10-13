#include "storage.h"
#include <string.h>

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
int storage_open_ram(struct storage *out, const void *base, size_t capacity)
{
    const uint8_t *p = base;
    out->data = NULL; out->size = 0;
    if (capacity < STORAGE_HEADER_SIZE || memcmp(p, "CHWAD001", 8)) return -1;
    uint32_t length = le32(p + 8);
    if (le32(p + 12) != STORAGE_HEADER_SIZE || length < 12 ||
        length > capacity - STORAGE_HEADER_SIZE) return -1;
    for (unsigned i = 48; i < STORAGE_HEADER_SIZE; ++i)
        if (p[i]) return -1;
    p += STORAGE_HEADER_SIZE;
    if (memcmp(p, "IWAD", 4) && memcmp(p, "PWAD", 4)) return -1;
    uint32_t count = le32(p + 4), directory = le32(p + 8);
    if (directory > length || count > (length - directory) / 16u) return -1;
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t *entry = p + directory + i * 16u;
        uint32_t offset = le32(entry), size = le32(entry + 4);
        if (offset > length || size > length - offset) return -1;
    }
    out->data = p; out->size = length;
    return 0;
}
size_t storage_read(const struct storage *storage, size_t offset,
                    void *buffer, size_t length)
{
    if (offset >= storage->size) return 0;
    if (length > storage->size - offset) length = storage->size - offset;
    memcpy(buffer, storage->data + offset, length);
    return length;
}
