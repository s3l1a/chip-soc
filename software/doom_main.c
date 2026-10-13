#include "platform.h"
#include "storage.h"
#include "doomgeneric.h"

#ifndef CHIP_TIMEDEMO
#define CHIP_TIMEDEMO 1
#endif

int main(void)
{
    struct storage wad;
    if (storage_open_ram(&wad, (const void *)(uintptr_t)WAD_BASE, WAD_CAPACITY)) {
        uart_puts("Doom requires a verified memory-mapped WAD\n");
        platform_halt();
    }
    uart_puts("Doom engine GPL-2.0-or-later; no warranty. See upstream LICENSE.\n");
    uart_puts("DG_WAD bytes="); uart_hex((uint32_t)wad.size);
    uart_puts(" base="); uart_hex(WAD_BASE); uart_putc('\n');
    char *argv[] = {"doom", "-iwad", "doom1.wad", "-mb", "4",
                    "-nosound", "-nomusic",
#if CHIP_TIMEDEMO
                    "-timedemo", "demo1",
#endif
                    NULL};
    doomgeneric_Create((int)(sizeof(argv) / sizeof(argv[0])) - 1, argv);
    uart_puts("DG_CREATE_RETURN\n");
    for (;;) doomgeneric_Tick();
}
