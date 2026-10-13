/* Simulation preload only: this is not a RAM loader. */
    .section .text.reset,"ax",@progbits
    .option norvc
    .option norelax
    .globl _reset
_reset:
    lui t0, 0x80000
    fence.i
    jalr zero, 0(t0)
