#include "platform.h"
#include "storage.h"
#include <stdlib.h>

static volatile uint32_t initialized = 0x12345678;
static volatile uint32_t zeroed;
int main(void)
{
    uart_puts("chip RV32IM diagnostic\n");
    if (initialized != 0x12345678 || zeroed || !malloc(32)) {
        uart_puts("startup/heap FAIL\n"); platform_halt();
    }
    uart_puts("data/bss/heap OK\n");
    timer_compare(UINT64_MAX); /* Polling only; machine interrupts stay disabled. */
    video_palette_init();
    for (unsigned page = 0; page < 2; ++page) {
        volatile uint8_t *fb = video_page(page);
        for (unsigned y = 0; y < 200; ++y)
            for (unsigned x = 0; x < 320; ++x)
                fb[y * 320 + x] = (uint8_t)(((x * 8 / 320) << 5) |
                    ((y * 8 / 200) << 2) | (page ? 3u : 0u));
    }
    video_enable();
    video_present(1);
    struct storage wad;
    uart_puts(storage_open_ram(&wad, (const void *)(uintptr_t)WAD_BASE,
                              WAD_CAPACITY) ? "asset WAD absent/invalid\n" :
                                             "asset WAD bounds OK\n");
    uint32_t heartbeat = 0;
    for (;;) {
        gpio_write(++heartbeat);
        uart_puts("ms="); uart_hex(timer_ms());
        uart_puts(" gpio="); uart_hex(gpio_read()); uart_putc('\n');
        sleep_ms(1000);
    }
}
