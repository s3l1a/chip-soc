# Official ISA Test Results

These are executions of pinned, official upstream RISC-V assembly tests on
the real `rv32im_cpu` RTL using Icarus Verilog 14, not reimplementations of the
tests or architectural execution bypasses. Results apply to the recorded RTL
snapshot; rerun the subsets after CPU changes.
The original project root license remains MIT; external dependencies retain
their own licenses and attribution.

## Source Pins

| Dependency | Repository | Exact Commit |
| --- | --- | --- |
| riscv-tests | https://github.com/riscv-software-src/riscv-tests | `7b68f7b91f827f8d94cc1c57ff123752c5c8f704` |
| riscv-test-env | https://github.com/riscv/riscv-test-env | `6de71edb142be36319e380ce782c3d1830c65d68` |
| riscv-arch-test | https://github.com/riscv-non-isa/riscv-arch-test | `96e3589a867955e94c95ba098822da54d3ae39c0` |

The environment commit is exactly the `env` gitlink in the pinned
`riscv-tests` tree. It is checked out separately and included from there,
without changing that tree or using a replacement `p/riscv_test.h`.

The architecture pin is the official **legacy 2.7.4 release**. That release
includes checked-in RV32 reference signatures, enabling a runnable subset
without the much larger current ACT4/Sail/UDB dependency stack. This is not a
claim to have run the latest architecture suite, a RISCOF certification flow,
or ACT4. Neither upstream sources nor their expected signatures are patched.

## Licensing

`tools/isa_tests.py fetch` retrieves and checks the license notices at each
exact SHA **before fetching source code**, then compares the retained checkout
notices byte-for-byte. It refuses modified or wrong-revision checkouts rather
than resetting them. Build/run also require clean, exact-revision checkouts.
All downloads, ELFs, memory images, traces, logs, and results reside in ignored
`external/isa/`, leaving existing `external/assets/` alone.

- riscv-tests and riscv-test-env retain the Regents' BSD-style three-condition `LICENSE`, including the copyright, redistribution requirements, and disclaimer.
- riscv-arch-test retains `COPYING.BSD`, `COPYING.APACHE`, and `COPYING.CC`; the code is BSD-3-Clause/Apache-2.0 as marked per file, and documentation is CC-BY-4.0. The selected I/M sources' SPDX notices are checked before compilation.
- Complete licenses are also copied into `external/isa/build/NOTICES/` alongside generated binaries. `ATTRIBUTION.txt` preserves selected tests' actual copyright/SPDX header notices, because the architecture `COPYING.BSD` file is a template; `CHIP-MIT` preserves the original adapter/harness license. Do not redistribute binaries without these licenses and source attribution.
- The original `sim/isa/` adapter and harness contributions are MIT. No license is replaced or relicensed by this integration.

Verified notice SHA-256 values are recorded in
`external/isa/provenance.json`:

| Notice | SHA-256 |
| --- | --- |
| riscv-tests / riscv-test-env `LICENSE` | `43b7309213293b4323d65301a90e05472579abcd51feb260a850354bcb49ff8f` |
| architecture `COPYING.BSD` | `c0244a5bdfac2a90eca99d7e208752b85af1b19ace65801a82358d3e6ed0d8f6` |
| architecture `COPYING.APACHE` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| architecture `COPYING.CC` | `2a82ac9bbc3e3ee066908381e8d373896db5a6025d083fbd59692fe9ccfb9111` |

## Reproduce

Run from the project root:

```text
python tools/isa_tests.py fetch
python tools/isa_tests.py build
python tools/isa_tests.py run --jobs 2
```

Or combine those stages with `python tools/isa_tests.py all`.
Default seed is decimal `427296003` (`0x19780503`), maximum response delay 11,
cycle watchdog 2,000,000, and host timeout 120 seconds per executable. The
watchdogs fail the test, never supply a synthetic completion.

The verified toolchain is user-local xPack **GNU GCC 15.2.0 / binutils 2.45**:

```text
%APPDATA%/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/15.2.0-1.1/.content/bin/riscv-none-elf-
```

The driver uses that prefix if `riscv-none-elf-gcc` is not on PATH. Override
with `--cross <prefix>`. Icarus is found on PATH or in the installed portable
directory `%TEMP%/chip-tools/iverilog-v14/bin/`;
`--iverilog` and `--vvp` accept explicit executable paths. No permanent PATH
or Git configuration changes are required.

All binaries use `-march=rv32im_zicsr_zifencei -mabi=ilp32`, `-mcmodel=medany`,
no relaxation, no standard library/startup, and no build ID. Compressed and
floating-point ABI ELF flags are rejected. Actual compiler/assembler versions,
full build commands, ELF digests, symbol addresses, and reference digests are
recorded in `external/isa/build/manifest.json`.

`--suite tests` or `--suite arch` selects a build subset. `--filter` selects
test names using a glob, for example `--filter "rv32um-p-*"`. Use a separate
`--out external/isa/<output-name>` to preserve a previous selection. The run
stage executes the existing build manifest; it does not rebuild or silently
expand that selection. Do not run two pipelines concurrently in the same
output directory. Jobs within a single run operate on distinct test folders.

Per-test outputs include `test.elf`, `test.mem`, `test.map`, `build.log`,
`run-<seed>.log`, and `trace-<seed>.txt`. Architecture tests additionally emit
`signature-<seed>.txt`. The aggregate machine-readable report is
`external/isa/build/results-427296003.json`.

## Harness Contract

`sim/isa/tb_isa.sv` instantiates the actual CPU with the permitted
`RESET_PC=0x80000000` parameter. Every ELF entry must equal that address.
The harness supplies a 4 MiB unified behavioral RAM window at
`0x80000000..0x803fffff`; the large window accommodates official far-jump/NOP
padding. This unit harness does not exercise the SoC boot ROM, caches, MMIO,
or board memory. SoC boot and Doom runs remain separate integration work.

`tools/elf_to_mem.py`'s existing `elf_image`/`words` functions validate ELF32
little-endian RISC-V executable identity-mapped PT_LOAD segments, bounds,
overlap, executable entry, and BSS. Memory indices are 32-bit words relative
to RAM base, not absolute addresses. RAM starts zeroed. Each run revalidates
the ELF digest and reconverts the actual ELF, rather than trusting an old
memory image.

Instruction and data transactions use `soc_pkg::req_t` and `rsp_t` directly.
Requests receive seeded random backpressure and delayed responses; stores
apply only the actual accepted byte strobes. Both request and response
stable-under-stall monitors, single-outstanding ownership, response ownership,
retirement-order checks, and delayed `FENCE.I` completion checks are active.
Instruction fetch observes actual RAM, including self-modifying stores.
There is no register/CSR initialization through hierarchy, instruction
emulation, trap emulation, or precomputed architectural result injection.

The `tohost` address comes from each compiled ELF's symbol table. The harness
accepts only a full-word nonzero store; value 1 is successful termination,
while another value fails with the upstream encoded test number. It waits
for the data acknowledgment and the actual store's retirement before ending.
An accepted store alone, timeout, or printed diagnostic is not a pass.

The riscv-tests physical `p` environment runs unchanged, including its
optional RNMI/SATP/PMP/delegation CSR probes and actual ECALL/trap handler.
Unsupported optional probes trap and are recovered by that upstream code;
the bench does not emulate them. The CPU remains machine-only, so these
results do not establish U/S-mode behavior. Unexpected exceptions handled
by the upstream failure path still fail via non-1 `tohost`.

The architecture runtime adapter is `sim/isa/model_test.h`, linked by
`sim/isa/arch.ld`. It disables interrupts, supplies an actual `tohost` halt,
and defines 16-byte-aligned signature bounds matching the legacy reference
format. Optional debug/assert-print hooks are empty because the **complete
signature is checked independently offline**. The instruction/test macros
remain upstream. Unexpected architecture-test traps fail immediately.

For architecture tests, `tohost=1` is only a completion marker, **not enough
to report PASS**. Every dumped word between `begin_signature` and
`end_signature`, including padding, must exactly match the pinned upstream
`.reference_output`. Unknown values, malformed/empty signatures, length
mismatches, and any changed reference digest fail. Expectations are not
derived from the DUT, the earlier hand-golden generator, or Unicorn.

## Verified Results

Actual Icarus 14 execution with seed `427296003`, maximum delay 11:

| Official Subset | Candidates | Executed PASS | Executed FAIL | Inapplicable | Build Blocked |
| --- | ---: | ---: | ---: | ---: | ---: |
| riscv-tests rv32ui/p | 42 | 41 | 0 | 1 | 0 |
| riscv-tests rv32um/p | 8 | 8 | 0 | 0 | 0 |
| legacy riscv-arch-test RV32 I | 38 | 37 | 0 | 0 | 1 |
| legacy riscv-arch-test RV32 M | 8 | 8 | 0 | 0 | 0 |
| **Total** | **96** | **94** | **0** | **1** | **1** |

All 49 applicable riscv-tests binaries return success through the original
`p` environment. All 45 executed architecture binaries return completion
and match every word of their independent official reference signatures.
No CPU RTL bug was reproduced by these executed subsets.
Python byte-compilation passes. pyslang 11 elaboration of the package, CPU,
divider, and ISA bench reports zero diagnostics and zero errors.

## Exclusions And Blockers

- `rv32ui-p-ma_data` is declared inapplicable before execution: it requires successful unaligned loads/stores. This CPU correctly traps those accesses; neither the hardware nor the environment is modified to emulate them.
- `arch-rv32-I-jalr-01` is applicable in principle but **build-blocked**, not passed or waived for CPU behavior. The legacy `TEST_JALR_OP` expands `LA(x0, 5b)` into `la x0,5b`, rejected by GNU assembler 2.45. The driver attempts the build, retains its command/error in `build.log`, and records the blocker separately. No test-source/header/reference patch is applied. The separate official `rv32ui-p-jalr` binary does pass on RTL.
- RV64, A, floating-point, compressed, vector, and other unsupported extension suites are not selected. Machine/supervisor/translation/PMP/privilege suites are not claimed; this CPU does not implement the complete configuration they require. The selected architecture I load/store tests are the aligned variants.
- These are official-source subset results, not complete architectural certification, not current ACT4 results, and not a full trusted-model retirement differential. riscv-tests uses its own executed self-checks; the legacy architecture subset uses independent checked-in upstream signatures.
