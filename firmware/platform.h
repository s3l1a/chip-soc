#ifndef CHIP_PLATFORM_H
#define CHIP_PLATFORM_H
#include <stddef.h>
#include <stdint.h>

#define CPU_HZ UINT32_C(50000000)
#define UART_BASE UINT32_C(0x10000000)
#define TIMER_BASE UINT32_C(0x10001000)
#define GPIO_BASE UINT32_C(0x10002000)
#define VIDEO_BASE UINT32_C(0x10003000)
#define FB_BASE UINT32_C(0x20000000)
#define FB_STRIDE UINT32_C(65536)
#define FB_PIXELS (320u * 200u)
#ifndef WAD_BASE
#define WAD_BASE UINT32_C(0x60000000)
#endif
#ifndef WAD_CAPACITY
#define WAD_CAPACITY UINT32_C(0x04000000)
#endif

static inline uint32_t mmio_read(uintptr_t address)
{
    return *(volatile uint32_t *)address;
}
static inline void mmio_write(uintptr_t address, uint32_t value)
{
    *(volatile uint32_t *)address = value;
}
static inline void io_fence(void)
{
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}
void uart_putc(char c);
void uart_puts(const char *text);
void uart_hex(uint32_t value);
int uart_getc(void);
uint64_t timer_cycles(void);
void timer_compare(uint64_t deadline);
uint32_t timer_ms(void);
void sleep_ms(uint32_t ms);
uint32_t gpio_read(void);
void gpio_write(uint32_t value);
void video_palette_init(void);
void video_enable(void);
unsigned video_back_page(void);
volatile uint8_t *video_page(unsigned page);
void video_present(unsigned page);
uint8_t video_rgb332(uint32_t rgb);
struct trap_frame { uint32_t x[32], mcause, mepc, mtval, mstatus; };
_Noreturn void trap_report(const struct trap_frame *frame);
_Noreturn void platform_halt(void);
#endif
