# Cache and Memory Bus

These board-independent blocks are part of the canonical SystemVerilog SoC;
the unverified root Verilog prototypes were removed. The cache and arbiter are synthesizable SystemVerilog; `sim_ram`
is a behavioral simulation model. Address decoding, uncached/MMIO bypass, and
physical memory controllers belong outside these blocks.

## Transaction Contract

All channels use `clk` and active-low asynchronous control reset `rst_n`.
A transfer occurs on a rising edge with both `valid` and `ready` high. A producer
must hold `valid` and its payload stable until transfer. A request is issued once,
not repeated for every burst beat. There is at most one outstanding transaction
per port, including the entire response burst. Reset must be applied coherently
to connected blocks; resetting one participant alone cannot cancel an accepted
transaction in another participant.

| Signal | Width | Requester Direction | Meaning |
| --- | --- | --- | --- |
| `req_valid` | 1 | output | Request payload valid |
| `req_ready` | 1 | input | Request accepted when valid |
| `req_addr` | 32 | output | Byte address, word aligned |
| `req_write` | 1 | output | 0: read; 1: write |
| `req_wstrb` | 4 | output | Write byte enables; bit 0 selects bits 7:0 |
| `req_wdata` | 32 | output | Write data; ignored on reads |
| `req_len` | 3 | output | Beats minus one; reads support 0 or 7; writes require 0 |
| `rsp_valid` | 1 | input | Response payload valid |
| `rsp_ready` | 1 | output | Response consumed when valid |
| `rsp_rdata` | 32 | input | Read data; zero for write acknowledgment |
| `rsp_error` | 1 | input | This beat reports an error |
| `rsp_last` | 1 | input | Final beat or single write acknowledgment |

Read bursts increment the address by four bytes per beat, without wrap. Any
word-aligned burst address is legal on the bus; cache refill requests are also
32-byte aligned. Writes have one request and one acknowledgment, including
zero-strobe writes. A failed request may terminate early with an error and
`rsp_last=1`. Otherwise an eight-beat read ends on beat seven. No timeout in these
blocks fabricates a response or drops an accepted transaction. An unresponsive
downstream remains locked until a real final response is consumed or coherent
system reset occurs. Fault decoding and any system recovery policy are external.

## `direct_mapped_cache`

Source: `rtl/cache/direct_mapped_cache.sv`. No parameters.

Exact ports:

| Direction | Names | Width |
| --- | --- | --- |
| input | `clk`, `rst_n` | 1 each |
| input | `req_valid`, `req_write`, `rsp_ready` | 1 each |
| input | `req_addr`, `req_wdata` | 32 each |
| input | `req_wstrb` | 4 |
| output | `req_ready`, `rsp_valid`, `rsp_error`, `rsp_last` | 1 each |
| output | `rsp_rdata` | 32 |
| input | `fence_valid` | 1 |
| output | `fence_ready`, `fence_done` | 1 each |
| output | `mem_req_valid`, `mem_req_write`, `mem_rsp_ready` | 1 each |
| output | `mem_req_addr`, `mem_req_wdata` | 32 each |
| output | `mem_req_wstrb` | 4 |
| output | `mem_req_len` | 3 |
| input | `mem_req_ready`, `mem_rsp_valid`, `mem_rsp_error`, `mem_rsp_last` | 1 each |
| input | `mem_rsp_rdata` | 32 |

The unprefixed CPU side is single-beat and has no `req_len`; its `rsp_last` is
always one. All downstream protocol ports carry the `mem_` prefix. Only aligned,
cacheable memory requests should reach this module. There is no internal memory
map, bypass bit, alignment fault decoder, or DMA snooping.

The cache holds 16 KiB: 512 direct-mapped lines of 32 bytes (eight words).
Address bits 31:14 are the 18-bit tag, 13:5 select the line, and 4:2 select
the word. Data, tag, and valid lookups are registered synchronous reads. Data and
tag arrays are not reset. Reset starts a 512-clock valid-bit sweep; no requests
are accepted before it finishes. A read hit produces a registered response on
the rising edge after request acceptance. That response remains held until the
CPU consumes it; a new request cannot overlap it.

Read misses issue one aligned `mem_req_len=7` transaction and consume the entire
refill before replying to the CPU. A line becomes valid only after a complete,
error-free eight-beat refill. Errors on any beat are accumulated; early final
responses or extra beats also fail the refill. Failure returns zero and an error
without allocating the line. A burst missing its final marker is drained until
a real `rsp_last`, never timed out or abandoned.

Writes are write-through and write-no-allocate. Every write is forwarded as a
single transaction with its original strobes. A successful acknowledgment updates
enabled bytes on a cached hit. A miss does not allocate or evict another tag.
A failed write invalidates a cached hit because memory may have partially changed.

`fence_valid && fence_ready` accepts whole-cache invalidation. Fence acceptance
has priority over a simultaneous CPU request. `fence_ready` is high only when the
cache has no outstanding CPU transaction; callers hold `fence_valid` until it is
accepted. A fence sweeps all 512 valid entries, blocks CPU requests, and pulses
`fence_done` for one clock on completion. Reset invalidation does not pulse
`fence_done`. External writers require hardware invalidation before cached data
is reused.

This is the standalone cache's hardware interface, not a software maintenance
instruction. In `soc_top`, `FENCE.I` invalidates only the I-cache, and the D-cache
invalidation input is tied low. Ordinary `FENCE` is a no-op because the CPU
already completes transactions in order; it invalidates neither cache. There is
no software D-cache maintenance operation or external-master snooping. Runtime
external writers therefore require additional integration to avoid stale data.

## `bus_arbiter`

Source: `rtl/interconnect/bus_arbiter.sv`. No parameters.

Exact ports are `clk`, `rst_n` (inputs, one bit) and three complete protocol
bundles from the contract table: `m0_`, `m1_`, and `s_`. For example,
`m0_req_addr[31:0]`, `m1_req_len[2:0]`, and `s_rsp_last`. Each bundle contains
every signal in the table, with the listed width. On `m0_` and `m1_`, requester
outputs are module inputs and requester inputs are module outputs. On `s_`, the
directions are exactly the requester directions in the table.

This is a two-master, one-slave arbiter, not an address decoder. When both masters
are requesting, master 0 wins the first competition after reset. Following each
final response consumption, the other master receives next priority. A lone
requester is not delayed for an absent peer. A grant presented to a stalled slave
is held even if a new competitor arrives. The accepting master retains exclusive
ownership from request handshake through `s_rsp_valid && s_rsp_ready && s_rsp_last`.
Request payloads may change after acceptance without affecting response routing.
Only the owner sees response valid; only its ready reaches the slave. Even a final
response stalled by the owner cannot unlock arbitration. Arbitration resumes in
the cycle after final consumption; there is no response buffering.

## `sim_ram`

Source: `rtl/memory/sim_ram.sv`. Exact ports are `clk`, `rst_n` (one-bit inputs)
and the full **unprefixed** protocol bundle in the contract table, with slave
directions (requester outputs are module inputs).

| Parameter | Default | Meaning |
| --- | --- | --- |
| `BASE` | `32'h80000000` | First byte address |
| `MEM_BYTES` | `16*1024*1024` | Size, positive multiple of four |
| `MAX_DELAY` | `7` | Maximum additional waiting clocks before each response beat |
| `SEED` | `32'h1badf00d` | Nonzero deterministic 32-bit latency LFSR seed |
| `INIT_FILE` | `""` | Optional `$readmemh` file, 32-bit words starting at BASE |

The default range is `0x80000000` through `0x80ffffff`. Memory starts at zero,
then optionally loads `INIT_FILE`. Reset preserves contents, drops model control
state, and restarts the latency generator. Accepted legal writes commit enabled
bytes once; their acknowledgments are delayed like reads. Request acceptance is
disabled while any response transaction is outstanding. Read beats are generated
with deterministic pseudo-random gaps and stay stable under backpressure. Latency
is repeatable for the same reset seed and cycle-level stimulus; it is not independent
of request timing. This is not a synthesizable external memory implementation.

Misalignment, out-of-range accesses (including a burst crossing the end), illegal
read lengths, and nonzero write lengths yield one zero-data error response with
`rsp_last=1`, without modifying memory. This local model validation is not a
replacement for the system memory-map fault decoder.

## Standalone Tests

Run from `F:\chip` with Icarus Verilog:

```text
iverilog -g2012 -s tb_cache -o tb_cache.vvp rtl/cache/direct_mapped_cache.sv rtl/memory/sim_ram.sv sim/unit/tb_cache.sv
vvp tb_cache.vvp
iverilog -g2012 -s tb_bus -o tb_bus.vvp rtl/interconnect/bus_arbiter.sv rtl/memory/sim_ram.sv sim/unit/tb_bus.sv
vvp tb_bus.vvp
```

Alternatively, on a platform with Verilator and its C++ toolchain:

```text
verilator --binary --timing --assert -Wno-fatal --top-module tb_cache --Mdir obj_cache rtl/cache/direct_mapped_cache.sv rtl/memory/sim_ram.sv sim/unit/tb_cache.sv
obj_cache/Vtb_cache
verilator --binary --timing --assert -Wno-fatal --top-module tb_bus --Mdir obj_bus rtl/interconnect/bus_arbiter.sv rtl/memory/sim_ram.sv sim/unit/tb_bus.sv
obj_bus/Vtb_bus
```

The tests use deterministic pseudo-random slave latency, request stalls, and
response backpressure. Immediate assertions and scoreboards check payload
stability, ownership, read/write data, byte strobes, line conflicts, write policy,
isolated first/middle/last-beat refill errors and early fault termination,
reset/fence sweeps over all 512 entries, pending fences, round-robin
contention, final-beat stalls, and model faults. Long directed stalls check that
no synthetic timeout response appears, including after downstream acceptance.
Test-only watchdogs fail stalled tests;
they do not implement protocol timeout behavior. A successful test prints
`PASS tb_cache` or `PASS tb_bus`; assertion failures terminate with `$fatal`.
