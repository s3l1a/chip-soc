OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    APP (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
    WAD (r)   : ORIGIN = 0x80800000, LENGTH = 8M
}
PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}
SECTIONS
{
    . = ORIGIN(APP);
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > APP :text
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > APP :text
    .data : ALIGN(16)
    {
        __data_start = .;
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        __data_end = .;
    } > APP :data
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        __bss_end = .;
    } > APP :data
    . = ALIGN(16);
    __heap_start = .;
    __stack_top = ORIGIN(APP) + LENGTH(APP);
    __stack_bottom = __stack_top - 64K;
    __heap_end = __stack_bottom;
    __wad_start = ORIGIN(WAD);
    __wad_end = ORIGIN(WAD) + LENGTH(WAD);
    /DISCARD/ : { *(.eh_frame .eh_frame.* .comment) }
    ASSERT(__heap_start <= __heap_end, "Application overlaps reserved stack")
    ASSERT(__data_load + SIZEOF(.data) <= __stack_bottom, "Load image exceeds APP")
}
