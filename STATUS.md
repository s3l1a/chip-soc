# Project Status

Last recorded: 2026-10-13. **Simulation-proven is not hardware-proven.**

## Current Result

The original SystemVerilog CPU and complete SoC execute DoomGeneric with legal
Freedoom data in Verilator. Two fresh six-frame runs advanced game tics 2-7,
matched all captures, and passed CPU, bus, cache-protocol and framebuffer-bound
assertions. Independent Unicorn execution matched all 64,000 indexed bytes of
every frame. This proves a short deterministic segment, not full demo completion.

Original code is MIT. No commercial WAD or generated build artifact is
committed.

## Evidence Matrix

| Area | Implemented | Tested | Formally Verified | Synthesized | Vivado Implemented | Hardware Tested |
| --- | --- | --- | --- | --- | --- | --- |
| Custom RV32IM/Zicsr/Zifencei CPU | Yes | Directed, official I/M, arithmetic reference | No full CPU proof | XC7/Yosys | No | No |
| Iterative divider | Yes | 264,632 cases | Completion/control; not all arithmetic | XC7/Yosys | No | No |
| Valid/ready protocol monitors | Yes | Legal and 8 negative tests | Included in scoped arbiter harness | Checkers excluded | No | No |
| Locked round-robin arbitration | Yes | Randomized and directed | Safety induction and covers | XC7/Yosys | No | No |
| 16 KiB I/D caches and bypass | Yes | Reset, refill, hit, conflict, faults, strobes | No full cache proof | BRAM inference checked | No | No |
| Behavioral RAM/assets | Yes | Random latency, writes, bounds and Doom | No | Not physical RTL | No | No |
| UART / timer / GPIO | Yes | Serial/FIFO/timer/inputs and firmware | FIFO bounds/control at BIT_CLKS=16 | XC7/Yosys | No | No |
| Indexed framebuffer / video | Yes | Full timing/pixel/flip tests, two clock ratios | No CDC proof | BRAM inference checked | No | No |
| Bare-metal boot/runtime | Yes | Build, host tests and RTL diagnostic | Not applicable | Boot ROM mapped | No | No |
| Doom/newlib platform | Yes | Functional and complete RTL six-frame segment | Not applicable | Generic SoC mapped; software not synthesized | No | No |
| CI configuration | Yes | GitHub lint, units, firmware, Doom build and graphical diagnostic PASS | Not applicable | Not applicable | No | No |

## Completed Gates

1. Repository, protocol, memory/register specifications, licenses and tooling.
2. Bus monitors and scoped formal arbitration checks.
3. Custom CPU with behavioral memory.
4. Directed RV32I/M and divide corner tests.
5. CSR, precise traps, timer interrupt, FENCE and FENCE.I tests.
6. Official applicable ISA subsets and independent arithmetic differential checks.
7. Locked interconnect and external-memory simulation models.
8. Two 16 KiB caches, burst refills, reset and fence invalidation.
9. UART, timer, GPIO/input tests.
10. Dual-clock BRAM video, palette, timing and page-flip tests.
11. Reset-vector boot through ROM into preloaded application RAM.
12. C runtime and exact graphical diagnostic.
13. Doom in a functional emulator with image/tic comparison.
14. Six-frame deterministic Doom segment on the complete RTL SoC in Verilator.
15. Measured performance and packed framebuffer-store optimization.

Completion here means the specific evidence described in the linked documents,
not every conceivable ISA encoding, game level, formal property or board behavior.

## Measurements

Both final RTL Doom runs: 626,567,682 cycles, 87,905,457 retired instructions,
83,780,800 external bytes and 128,000 framebuffer write transactions. The final
four frame intervals were 39,480,000 cycles each. Startup is included in the
12.531354 simulated seconds and 6.685694 MB/s average external traffic.

`docs/doom-hashes.json` records the firmware, assets, captures and exact metrics.
`scripts/check_doom.py` validates both logs and captures and rejects stale binaries.
The initial four game images repeat because the demo starts stationary; guest
tics advance, and frames five and six change and match the independent emulator.

Yosys XC7 mapping passed with the dense 16 KiB ROM budget: 11,549 logic LUTs plus
80 nominal LUTRAM LUTs, 2,673 FF, 46 BRAM36 equivalents, 5 DSP and 2 BUFG.
This fits XC7S50 resource counts but does not establish routed timing or pin fit.

GitHub [Verification run 38320691358](https://github.com/s3l1a/chip-soc/actions/runs/38320691358)
passed on Ubuntu 24.04 with Verilator 5.020. It includes the argument-parsing
regression, RTL lint and units, independent arithmetic checks, diagnostic and
boot builds, Doom build-only, and exact graphical diagnostic comparison.
The earlier watchdog failure was testbench argument handling, not a CPU failure.

## Blocked

- Vivado is unavailable: vendor synthesis, placement/routing, WNS, unconstrained
  path signoff, DRC, methodology, clock-interaction and CDC reports are unexecuted.
  Reproduce locally with `scripts/vivado.tcl`; no bitstream is generated.
- No external RAM module or pinout is selected. The Boolean Board's BRAM is not
  sufficient for Doom runtime memory; QSPI is not writable working RAM.
- The tested Freedoom WAD exceeds both 16 MiB QSPI and the 8 MiB RAM asset
  reservation. Simulation expands read-only assets to 64 MiB. Physical operation
  needs a suitable storage expansion or smaller legally supplied asset.
- Hardware RAM initialization, QSPI/UART loading, HDMI/TMDS serialization and
  complete board electrical constraints are not implemented or tested.
- No physical board has been supplied or programmed.
- The legacy architecture `jalr-01` source fails to assemble with binutils 2.45.
  Sources were not patched. Other directed and official JALR tests pass.

## Planned

- Complete 7,117-tic timedemo, extended gameplay and heap/stack profiling.
- Broader trusted-model differential checking beyond arithmetic and the official
  I/M reference signatures; current ACT4 and full privileged conformance.
- Formal cache/refill and video CDC properties, plus FIFO payload ordering and
  broader parameters beyond the existing count/pointer proof. Metastability and
  implementation CDC signoff remain separate work.
- Pipeline/performance improvements after preserving all verification results.
- Hardware loader, selected RAM controller, real storage, Boolean wrapper and
  display output, followed by board bring-up. Audio remains optional.

See `docs/verification.md`, `docs/isa-tests.md`, `formal/README.md`, and
`docs/synthesis.md` for exact commands, assumptions and exclusions.
