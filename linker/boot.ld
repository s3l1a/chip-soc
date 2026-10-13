OUTPUT_ARCH(riscv)
ENTRY(_reset)
MEMORY { ROM (rx) : ORIGIN = 0, LENGTH = 16K }
SECTIONS
{
    .text : { KEEP(*(.text.reset)) } > ROM
    /DISCARD/ : { *(.comment .eh_frame .riscv.attributes) }
}
