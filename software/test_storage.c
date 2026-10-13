/* Native host test of the portable RAM storage parser. */
#include "storage.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    unsigned char image[96] = {0};
    memcpy(image, "CHWAD001", 8);
    image[8] = 32; image[12] = 64;
    memcpy(image + 64, "IWAD", 4);
    image[68] = 1; image[72] = 16;
    memcpy(image + 76, "test", 4);
    image[80] = 12; image[84] = 4;
    struct storage storage;
    char buffer[8] = {0};
    assert(storage_open_ram(&storage, image, sizeof(image)) == 0);
    assert(storage_read(&storage, 12, buffer, 4) == 4);
    assert(memcmp(buffer, "test", 4) == 0);
    assert(storage_read(&storage, 30, buffer, 8) == 2);
    assert(storage_read(&storage, (size_t)-1, buffer, 8) == 0);
    assert(storage_open_ram(&storage, image, 63) == -1);
    image[48] = 1;
    assert(storage_open_ram(&storage, image, sizeof(image)) == -1);
    image[48] = 0; image[84] = 255;
    assert(storage_open_ram(&storage, image, sizeof(image)) == -1);
    assert(storage.data == NULL && storage.size == 0);
    image[84] = 4; image[72] = 255;
    assert(storage_open_ram(&storage, image, sizeof(image)) == -1);
    puts("storage parser tests passed");
    if (argc > 1) {
        FILE *file = fopen(argv[1], "rb");
        assert(file && fseek(file, 0, SEEK_END) == 0);
        long length = ftell(file);
        assert(length >= 64 && length <= 64 * 1024 * 1024);
        assert(fseek(file, 0, SEEK_SET) == 0);
        unsigned char *packed = malloc((size_t)length);
        assert(packed && fread(packed, 1, (size_t)length, file) == (size_t)length);
        assert(fclose(file) == 0);
        assert(storage_open_ram(&storage, packed, (size_t)length) == 0);
        assert(storage.size == (size_t)length - 64);
        assert(storage_read(&storage, storage.size - 1, buffer, sizeof(buffer)) == 1);
        assert((unsigned char)buffer[0] == packed[length - 1]);
        printf("actual packed WAD parser passed: %zu payload bytes\n", storage.size);
        free(packed);
    }
    return 0;
}
