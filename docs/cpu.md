# CPU Directed Verification

The SystemVerilog benches exercise `rtl/core/rv32im_cpu.sv` and
`rtl/core/divider.sv` directly.

## Running

Run from the repository root with Python 3 and Icarus Verilog 14 on `PATH`:

```text
python tools/cpu_vectors.py
iverilog -g2012 -s tb_cpu -o sim/generated/tb_cpu.vvp rtl/soc/soc_pkg.sv rtl/core/divider.sv rtl/core/rv32im_cpu.sv sim/unit/tb_cpu.sv
vvp sim/generated/tb_cpu.vvp
python tools/check_trace.py sim/generated/cpu.golden sim/generated/cpu.trace
vvp sim/generated/tb_cpu.vvp +SEED=12345 +MAX_DELAY=127 +TRACE=sim/generated/cpu_s12345.trace
python tools/check_trace.py sim/generated/cpu.golden sim/generated/cpu_s12345.trace
vvp sim/generated/tb_cpu.vvp +SEED=987654321 +MAX_DELAY=1 +TRACE=sim/generated/cpu_s987654321.trace
python tools/check_trace.py sim/generated/cpu.golden sim/generated/cpu_s987654321.trace
python tools/cpu_vectors.py --case misa --out sim/generated/misa
vvp sim/generated/tb_cpu.vvp +DIR=sim/generated/misa +TRACE=sim/generated/misa/cpu.trace
python tools/check_trace.py sim/generated/misa/cpu.golden sim/generated/misa/cpu.trace
iverilog -g2012 -s tb_divider -o sim/generated/tb_divider.vvp rtl/core/divider.sv sim/unit/tb_divider.sv
vvp sim/generated/tb_divider.vvp
```

The runner also checks the portable installation destination
`%TEMP%\chip-tools\iverilog-v14\bin` (or `CHIP_TOOL_DIR`). Install Icarus first;
this path is not a bundled dependency. In PowerShell, expand environment
variables with `$env:TEMP` and invoke a quoted executable path with `&`.
Icarus emits non-fatal `always_comb` constant-select sensitivity notices for
the RTL; these do not prevent simulation.

`tb_cpu` accepts `+DIR=<vector-directory>`, `+TRACE=<output-file>`,
`+SEED=<nonzero-decimal-seed>`, and `+MAX_DELAY=<1..1000>`.
Use distinct trace paths for parallel runs. Its watchdog fails rather than
fabricating a response or abandoning a transaction. `sim/generated/.gitignore`
keeps generated images, expectations, traces, and compiled benches out of Git.
The full suite requires instruction and data request stalls to be observed.
No-data arithmetic tests and a single-request CSR regression do not require
data-stall coverage. Every retiring `FENCE.I` must have received delayed
completion, regardless of case size.

## Expectations

`tools/cpu_vectors.py` is a small test assembler. The `full` and `misa` cases
have hand-derived expectations at each directed operation. Those cases are
**not trusted-model differential verification**. The separate `arithmetic`
case uses an external model as described below. Exhaustiveness refers to the
listed bounded domains and encoding families, not all 32-bit operand pairs or
all possible machine states.

Generated files:

- `cpu.hex`: little-endian memory words; both instruction and data ports access the same behavioral memory.
- `cpu.golden`: one row per retirement or trap entry, including handler instructions.
- `cpu.bus`: an independent list of every expected data request, including faulting accesses.
- `cpu.events`: ordered timer-pin transitions triggered by fetch acceptance, data acceptance, fence wait, or divider busy.
- `cpu.coverage.json`: directed mnemonic and trap counts, not RTL structural coverage.

Golden rows contain hexadecimal columns:

```text
order pc insn next_pc rd result trap cause tval result_mask
```

Actual traces have the same first nine columns. Both the bench and
`tools/check_trace.py` compare every entry and reject missing/extra entries.
The offline checker validates contiguous order as well. Trap entries advance
trace order but not `minstret`.

Cycle-CSR read results have a zero result mask in the static golden because
they depend on latency. They are nevertheless checked **exactly in `tb_cpu`**
against an elapsed-clock counter, including explicit writes, high/low aliases,
rollover, and write-over-increment precedence. The offline text checker alone
does not validate those cycle results. All other trace fields are unmasked.
`minstret` and its aliases have exact static expectations, including writes and
the exclusion of faulting instructions.

Data rows contain `addr write strb data len strb_mask data_mask`. Loads check
address, direction, and length; read strobes and write-data are don't-care.
Stores check all lanes and shifted write data. Misaligned accesses must not
produce a data request. Failed stores do not modify the behavioral memory.

## Coverage

- Every RV32I/M mnemonic, all six Zicsr forms, `FENCE`, `FENCE.I`, `ECALL`, `EBREAK`, `MRET`, and the permitted no-op implementation of `WFI`.
- Eleven boundary operands crossed for all register ALU and M operations; every immediate shift amount; signed/unsigned comparisons and immediate extrema.
- x0 suppression, all register destinations, immediate dependency chains, register ALU/M destination aliases with either source and immediate result-use checks, and load-use/base-destination hazards.
- All six branches taken and untaken, backward loops, positive/negative JAL offsets, JALR destination/base aliasing and bit-zero clearing, skipped poison instructions, and taken versus untaken misaligned targets.
- Every byte lane and both halfword lanes; signed/unsigned byte/halfword loads; merged byte/halfword stores and readback; negative data offsets; loads into x0.
- All unsupported 7-bit major opcodes; exhaustive reserved register-ALU `funct7/funct3` pairs and immediate-shift `funct7` patterns; invalid load/store, branch, JALR, fence, and SYSTEM subencodings.
- Instruction-target misalignment, instruction access fault, load/store misalignment, load/store access faults, illegal instruction, breakpoint, and machine ECALL. Handler reads check `mepc`, `mcause`, `mtval`, `mstatus`, `mie`, and `mip`; return uses `MRET`.
- Implemented CSR read/write/set/clear forms, zero-source no-write forms, a nonzero register containing zero, read-only counter/ID write faults, unknown CSR faults, WARL masks, counter aliases, and writable counter halves.
- Timer pending with either global or individual enable masked; enabling a pending IRQ; direct and vectored delivery during delayed fetch, load, store, divide, and fence. A timer arriving during an access fault verifies synchronous-trap priority and immediate IRQ delivery after `MRET`.
- Randomized instruction/data request backpressure and response delays; request/response stable-under-stall monitors; single outstanding ownership; no retirement before a delayed operation completes; delayed fence completion and self-modifying code visibility after `FENCE.I`.

The divider bench independently tests all 256-by-256 unsigned 8-bit pairs and
all sign-extended signed 8-bit pairs, quotient and remainder: 262,144 cases.
It adds the full 11-by-11 32-bit boundary matrix in all four modes, 2,000
deterministic random cases, and four post-reset cases, totaling **264,632**.
It checks divide by zero, signed overflow, quotient truncation toward zero,
remainder sign, 32 iteration latency, adjacent operations without an idle
bubble, changing live operands/modes, ignored start while busy, completion
pulsing, and reset cancellation of an active divide.

This is a machine-only CPU test suite, not a complete privileged-architecture
conformance suite, cache-coherence test, or SoC integration test.
The generator now includes all six write/set/clear forms and zero readbacks for
fixed-zero WARL `mstatush` (`0x310`), plus read-only `mconfigptr` (`0xF15`) reads
and illegal-write cases. The expanded suite passes all three latency seeds.

## External Arithmetic Reference

The optional reference is **Unicorn 2.1.4**, pinned in the installation
command and by runtime checks of both the Python package and native core
release version. Its upstream release tag resolves to
commit [`8028ec436f2d9376525352dd38ed9ed6b9f6be10`](https://github.com/unicorn-engine/unicorn/tree/8028ec436f2d9376525352dd38ed9ed6b9f6be10).
It uses `UC_ARCH_RISCV`, `UC_MODE_RISCV32`, and the `SIFIVE_E31` CPU model.
The native Windows wheel works with the installed Python 3.14.4. No external
source code is vendored into this project.

```text
python -m pip install --user unicorn==2.1.4
python tools/cpu_vectors.py --case arithmetic --out sim/generated/arithmetic
vvp sim/generated/tb_cpu.vvp +DIR=sim/generated/arithmetic +TRACE=sim/generated/arithmetic/cpu.trace
python tools/check_trace.py --unicorn sim/generated/arithmetic/cpu.hex sim/generated/arithmetic/cpu.trace
vvp sim/generated/tb_cpu.vvp +DIR=sim/generated/arithmetic +SEED=12345 +MAX_DELAY=127 +TRACE=sim/generated/arithmetic/cpu_s12345.trace
python tools/check_trace.py --unicorn sim/generated/arithmetic/cpu.hex sim/generated/arithmetic/cpu_s12345.trace
vvp sim/generated/tb_cpu.vvp +DIR=sim/generated/arithmetic +SEED=987654321 +MAX_DELAY=1 +TRACE=sim/generated/arithmetic/cpu_s987654321.trace
python tools/check_trace.py --unicorn sim/generated/arithmetic/cpu.hex sim/generated/arithmetic/cpu_s987654321.trace
```

The generator reuses the directed instruction stimuli, but **discards every
hand-derived retirement expectation** for this case. It single-steps Unicorn
to create the bench golden. The offline `--unicorn` checker then independently
replays the hex image; it does not load that golden or seed model registers
from DUT results. All 32 registers initially contain zero, matching CPU reset,
and model state persists across instructions. Results and next PC come from
Unicorn; instruction encoding supplies destination metadata. Every actual
trace field is compared without masking, and missing/extra entries fail.

The supported reference scope is straight-line legal `LUI`, `AUIPC`, integer
register/immediate ALU operations, and all eight M operations. The 4,196
instructions cover the eleven-boundary-operand matrix, all shift amounts,
signed/unsigned comparisons, divide-by-zero and signed overflow, x0,
destination/source aliases, and dependent result use. Dense hex padding is
zero; the first zero terminates code, and nonzero data after it is rejected.
Instructions outside the allowlist are rejected, not skipped or approximated.

**Limitations:** this is limited external-model arithmetic differential
verification, not complete RISC-V architectural certification. It does not
differentially check branches/jumps, loads/stores, CSRs, counters, traps,
interrupts, `FENCE.I`, privilege transitions, or bus timing. The E31 model
supports other features, but the adapter deliberately excludes them. Only
the destination value is observable in the RTL retirement trace; dependent
instructions exercise register-state persistence. Unicorn is an independent
third-party emulator, not the official RISC-V Sail specification model, and
can itself contain bugs.

The pinned official riscv-tests and legacy riscv-arch-test subsets executed
94 binaries successfully on the RTL. Their source pins, harness, signatures,
exclusions and build-blocked JALR case are in [ISA Tests](isa-tests.md). These
results are separate from arithmetic differential checking; current ACT4 and
full privileged-architecture conformance have not been run.

## Verified Results

The release regression includes the `mstatush` and `mconfigptr` additions.
Native Icarus 14 executed all three variants at each of these seed/delay pairs:
`1/17`, `0x1205abcd/31`, and `0xdeadbeef/63`. All nine simulations and trace
comparisons passed.

| Variant | Trace Entries Per Run | Data Requests | IRQ Events | Passing Seeds |
| --- | ---: | ---: | ---: | ---: |
| Full directed | 21,726 | 119 | 24 | 3 |
| MISA fixed-WARL regression | 15 | 1 | 0 | 3 |
| Independent Unicorn arithmetic | 4,196 | 0 | 0 | 3 |

The new CSR cases cover all six `mstatush` forms and readbacks of unsupported
bits, plus eight successful no-write `mconfigptr` reads and eight illegal write
attempts. A nonzero register index containing zero still expresses write intent
for CSRRS/CSRRC and must trap on the read-only CSR. The expanded suite failed
against the earlier decoder and passes with both registers implemented.

Each arithmetic simulation passes against the Unicorn-generated bench golden,
and each saved trace passes independent `--unicorn` replay from the hex image.
Corrupted results, truncated/extra traces, and unsupported reference opcodes
are rejected. The recorded divider bench passed all 264,632 cases, and pyslang
11 elaboration of the package, CPU, divider and both benches reported zero
diagnostics and zero errors for that snapshot.

## Fixed Regression

CSR `0x301` is fixed WARL: writes are accepted and ignored, fixing the previous
`misa` write-trap regression. The minimal case is:

```text
x1 = 0x40001100
csrrw x3, misa, x1       # instruction 0x301091f3
```

It retires normally with `x3 = 0x40001100`; subsequent write/set/clear forms
retain that value. The architectural requirement is documented in the
[Machine ISA Register specification](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html#_machine_isa_misa_register).
