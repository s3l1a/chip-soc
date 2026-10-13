/* SPDX-License-Identifier: MIT */
/* DUT-only runtime adapter. Expected signatures remain unmodified upstream. */
#ifndef CHIP_ISA_MODEL_TEST_H
#define CHIP_ISA_MODEL_TEST_H
#define RVMODEL_BOOT csrwi mie, 0; csrwi mstatus, 0;
#define RVMODEL_HALT \
  fence; li t0, 1; la t1, tohost; sw t0, 0(t1); 1: j 1b;
#define RVMODEL_DATA_BEGIN \
  .pushsection .tohost,"aw",@progbits; \
  .balign 8; .global tohost; tohost: .dword 0; \
  .popsection; .balign 16; .global begin_signature; begin_signature:
#define RVMODEL_DATA_END .balign 16; .global end_signature; end_signature:
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_WRITE_STR(_S, _STR)
#define RVMODEL_IO_INIT
/* These hooks are unused: interrupt/privileged tests are not selected. */
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT
#endif
