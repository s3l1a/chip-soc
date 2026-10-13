/* Original platform glue: MIT. Linked Doom executables remain GPL works. */
#include "platform.h"
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doomstat.h"

_Static_assert(DOOMGENERIC_RESX == 320 && DOOMGENERIC_RESY == 200,
               "framebuffer requires 320x200 Doom output");
_Static_assert(sizeof(pixel_t) == 4, "use RGB32, not CMAP256");

#ifndef CHIP_FRAME_LOG
#define CHIP_FRAME_LOG 8
#endif

void DG_Init(void)
{
    if (!DG_ScreenBuffer) {
        uart_puts("DG screen allocation failed\n"); platform_halt();
    }
    timer_compare(UINT64_MAX);
    video_palette_init();
    for (unsigned page = 0; page < 2; ++page)
        for (unsigned i = 0; i < FB_PIXELS / 4; ++i)
            ((volatile uint32_t *)video_page(page))[i] = 0;
    video_enable();
    uart_puts("DoomGeneric platform initialized (no audio)\n");
}
void DG_DrawFrame(void)
{
    static uint32_t frames;
    unsigned page = video_back_page();
    volatile uint32_t *fb = (volatile uint32_t *)video_page(page);
    uint32_t hash = UINT32_C(2166136261);
    for (unsigned i = 0; i < FB_PIXELS; i += 4) {
        uint32_t word = 0;
        for (unsigned lane = 0; lane < 4; ++lane) {
            uint8_t pixel = video_rgb332(DG_ScreenBuffer[i + lane]);
            word |= (uint32_t)pixel << (lane * 8);
            if (frames < CHIP_FRAME_LOG) hash = (hash ^ pixel) * UINT32_C(16777619);
        }
        fb[i / 4] = word;
    }
    video_present(page);
    ++frames;
    if (frames <= CHIP_FRAME_LOG) {
        uint64_t cycles = timer_cycles();
        uart_puts("DG_FRAME frame="); uart_hex(frames);
        uart_puts(" fnv1a="); uart_hex(hash);
        uart_puts(" cycles="); uart_hex((uint32_t)(cycles >> 32));
        uart_hex((uint32_t)cycles);
        uart_puts(" tic="); uart_hex((uint32_t)gametic); uart_putc('\n');
    }
}
void DG_SleepMs(uint32_t ms) { sleep_ms(ms); }
/* The pinned upstream API uses DG_GetTicksMs, not DG_GetTicks. */
uint32_t DG_GetTicks(void) { return timer_ms(); }
uint32_t DG_GetTicksMs(void) { return DG_GetTicks(); }
int DG_GetKey(int *pressed, unsigned char *key)
{
    /* UART press followed by release on the next poll; GPIO provides held keys. */
    static unsigned char release;
    static uint32_t previous;
    static const unsigned char gpio_keys[8] = {
        KEY_UPARROW, KEY_DOWNARROW, KEY_LEFTARROW, KEY_RIGHTARROW,
        KEY_FIRE, KEY_USE, KEY_ENTER, KEY_ESCAPE
    };
    if (release) { *pressed = 0; *key = release; release = 0; return 1; }
    uint32_t now = gpio_read() & 255u;
    uint32_t changed = now ^ previous;
    for (unsigned i = 0; i < 8; ++i) {
        if (changed & (1u << i)) {
            previous ^= 1u << i;
            *pressed = !!(now & (1u << i)); *key = gpio_keys[i]; return 1;
        }
    }
    int c = uart_getc();
    if (c < 0) return 0;
    switch (c) {
    case 'w': c = KEY_UPARROW; break;
    case 's': c = KEY_DOWNARROW; break;
    case 'a': c = KEY_LEFTARROW; break;
    case 'd': c = KEY_RIGHTARROW; break;
    case ' ': c = KEY_FIRE; break;
    case 'e': c = KEY_USE; break;
    case '\r': case '\n': c = KEY_ENTER; break;
    case 27: c = KEY_ESCAPE; break;
    default: if (c < 32 || c > 126) return 0; break;
    }
    *pressed = 1; *key = (unsigned char)c; release = *key; return 1;
}
void DG_SetWindowTitle(const char *title)
{
#if CHIP_TIMEDEMO
    /* Level loading forces a wipe; this callback runs after that load. */
    wipegamestate = gamestate;
#endif
    uart_puts("title: "); uart_puts(title); uart_putc('\n');
}
