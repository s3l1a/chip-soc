#include "platform.h"

_Static_assert(sizeof(struct trap_frame) == 144, "trap.S frame layout changed");

void uart_putc(char c)
{
    if (c == '\n') uart_putc('\r');
    while (mmio_read(UART_BASE) & 1u) {}
    mmio_write(UART_BASE + 4, (uint8_t)c);
    io_fence();
}
void uart_puts(const char *text)
{
    while (*text) uart_putc(*text++);
}
void uart_hex(uint32_t value)
{
    static const char digits[] = "0123456789abcdef";
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc(digits[(value >> shift) & 15u]);
}
int uart_getc(void)
{
    if (!(mmio_read(UART_BASE) & 2u)) return -1;
    return (int)(mmio_read(UART_BASE + 8) & 255u);
}
uint64_t timer_cycles(void)
{
    uint32_t hi, lo, again;
    do {
        hi = mmio_read(TIMER_BASE + 4);
        lo = mmio_read(TIMER_BASE);
        again = mmio_read(TIMER_BASE + 4);
    } while (hi != again);
    return ((uint64_t)hi << 32) | lo;
}
void timer_compare(uint64_t deadline)
{
    /* Avoid a transient early match while updating a split 64-bit compare. */
    mmio_write(TIMER_BASE + 12, UINT32_MAX);
    mmio_write(TIMER_BASE + 8, (uint32_t)deadline);
    mmio_write(TIMER_BASE + 12, (uint32_t)(deadline >> 32));
    io_fence();
}
uint32_t timer_ms(void)
{
    return (uint32_t)(timer_cycles() / (CPU_HZ / 1000u));
}
void sleep_ms(uint32_t ms)
{
    uint64_t start = timer_cycles();
    uint64_t duration = (uint64_t)ms * (CPU_HZ / 1000u);
    while (timer_cycles() - start < duration) {}
}
uint32_t gpio_read(void) { return mmio_read(GPIO_BASE); }
void gpio_write(uint32_t value) { mmio_write(GPIO_BASE + 4, value); }
uint8_t video_rgb332(uint32_t rgb)
{
    return (uint8_t)(((rgb >> 16) & 0xe0u) |
                     ((rgb >> 11) & 0x1cu) | ((rgb >> 6) & 3u));
}
void video_palette_init(void)
{
    for (unsigned i = 0; i < 256; ++i) {
        uint32_t r = ((i >> 5) & 7u) * 255u / 7u;
        uint32_t g = ((i >> 2) & 7u) * 255u / 7u;
        uint32_t b = (i & 3u) * 255u / 3u;
        mmio_write(VIDEO_BASE + 8, i);
        mmio_write(VIDEO_BASE + 12, (r << 16) | (g << 8) | b);
    }
    io_fence();
}
volatile uint8_t *video_page(unsigned page)
{
    return (volatile uint8_t *)(uintptr_t)(FB_BASE + (page & 1u) * FB_STRIDE);
}
unsigned video_back_page(void)
{
    /* Status bit 2 = displayed page; bit 1 = flip pending; bit 0 = enable. */
    while (mmio_read(VIDEO_BASE) & 2u) {}
    return ((mmio_read(VIDEO_BASE) >> 2) & 1u) ^ 1u;
}
void video_enable(void)
{
    io_fence();
    mmio_write(VIDEO_BASE, 1);
    io_fence();
}
void video_present(unsigned page)
{
    io_fence();
    mmio_write(VIDEO_BASE + 4, page & 1u);
    io_fence();
}
_Noreturn void platform_halt(void)
{
    for (;;) __asm__ volatile ("nop");
}
_Noreturn void trap_report(const struct trap_frame *frame)
{
    uart_puts("\nFATAL TRAP mcause="); uart_hex(frame->mcause);
    uart_puts(" mepc="); uart_hex(frame->mepc);
    uart_puts(" mtval="); uart_hex(frame->mtval);
    uart_puts(" mstatus="); uart_hex(frame->mstatus);
    uart_putc('\n');
    for (unsigned i = 0; i < 32; ++i) {
        uart_putc('x'); uart_hex(i); uart_putc('='); uart_hex(frame->x[i]);
        uart_putc((i & 3u) == 3u ? '\n' : ' ');
    }
    platform_halt();
}
