# Prototype Audit

All eight original root Verilog files were inspected before replacement. Their
interfaces conflated acceptance with completion and were not retained as an
alternate implementation. References below refer to the original files/line
numbers, not to files still present in the canonical SystemVerilog build.

| Original module | Independently observed issue |
| --- | --- |
| CPU, lines 334-344 | `stall` depends on `ibus_req`, while `ibus_req` depends on `!stall`: combinational loop when instruction ready is low. |
| CPU, lines 393-407 | JAL/JALR assert `flush`; `!flush` suppresses both write enable and valid, losing the link result. |
| CPU, lines 417-457 | Load writeback uses live decode `funct3` and effective address rather than the load's saved metadata. |
| CPU, lines 186-209, 236-240 | Divide-by-zero shortcut does not clear signed-result flags left by previous divisions. Procedural `wire` declarations at 217-218 are not portable legal procedural locals. |
| Cache, lines 106-114, 146-154, 195 onward | Valid bits are initialized, but control reset does not invalidate them. Data reads stop during refill, while newly valid tags can expose the old registered word. |
| Video, lines 197, 225-237 | DMA starts at address zero and waits for the same ready/completion a second time after dropping request, so a normal one-cycle completion can deadlock. |
| Video, line 66 / ROM jump stub | Default framebuffer and program both start at external RAM `0x80000000`, creating code/pixel overlap. |
| Interconnect, lines 169-210 | VGA request combinationally changes external-memory ownership, including during an accepted CPU transaction. |
| UART/video/SPI register loops | `request && !ready`, with ready clearing on alternate cycles, permits repeated side effects while a held request waits elsewhere. |
| SPI, lines 108-134 | Four-bit address decode includes `4'h10`, which cannot represent offset 0x10 and aliases another register. |
| SPI, lines 188-253 | The token/byte-zero override interferes with data progress, token storage and CRC sequencing. No trustworthy completed sector sequence exists. |
| Top/video domains | Pixel logic receives the CPU-domain reset despite a separate pixel reset synchronizer. Output masks/syncs do not track palette/line-memory latency. |

These are source-analysis findings, not a claim that the removed prototypes
passed or failed a compiled simulation. New directed tests explicitly exercise
jump links, load metadata, divider adjacency, backpressure, cache reset/refill,
locked ownership, one-time MMIO side effects and video alignment. Storage/SD
acceleration is not part of the canonical implementation: unavailable physical
storage reports explicit status/errors, and Doom uses the simulated asset backend.
