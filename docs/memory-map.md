# Implemented Memory Map

Source of truth: `rtl/soc/soc_top.sv`, `rtl/cache/cache_port.sv`,
`rtl/peripherals/peripherals.sv`, and `rtl/video/video_core.sv`. Addresses below
are inclusive byte ranges. CPU CSRs are not MMIO; their complete implemented
list, reset values, and access rules are in
[Architecture: Machine CSRs](architecture.md#machine-csrs).

## Access Contract

The bus accepts only word-aligned request addresses and returns a full 32-bit
word per read. Single-word requests use `len=0`; only RAM and assets support
eight-word reads (`len=7`). Other burst lengths, burst writes, unaligned bus
requests, region-crossing bursts, unmapped addresses, and invalid register
addresses produce an error response. ROM/assets are read-only: **all writes
fault, including zero-strobe writes**. Errors become CPU instruction/load/store
access faults (causes 1/5/7); architectural load/store misalignment traps before
any bus request. Successful local writes return zero; do not use error data.

The CPU supports naturally aligned byte/halfword/word instructions. It aligns
their bus address down to a word, shifts store data and byte strobes, and selects
and extends load data itself. Peripherals do **not** receive a load-width signal
or suppress read side effects according to byte lane. Each accepted read acts
once, even with response backpressure or destination x0. For example,
`LB`/`LBU` at `0x10000009` reads the RX register at `0x10000008`, pops one
queued byte, and returns zero from lane 1; an empty FIFO still faults.
Use aligned **32-bit MMIO register reads/writes** unless deliberately using the
documented byte-write behavior (notably byte TX at `0x10000004`). Framebuffer
byte stores are supported and used by firmware.

Write strobes select little-endian byte lanes: strobe 0 covers bits 7:0,
strobe 1 bits 15:8, strobe 2 bits 23:16, strobe 3 bits 31:24. Read-only or
write-only restrictions apply regardless of strobes. An ignored write lane
does not bypass address/direction checks. All reserved read bits are zero.

### Local Response Timing

Let E be the rising CPU-clock edge accepting a local request. Side effects occur
once at E, not when the response is consumed. These timings describe the slave
interface, not total CPU instruction latency through caches and arbitration.

| Local Access | Response Valid | Side Effect / Sampling |
| --- | --- | --- |
| Peripheral register read/write | Immediately after E | Register sampled or write applied at E; timer reads precede that edge's increment. |
| Video register read or any valid video/framebuffer write | Immediately after E | Register sampled or strobed write applied at E. |
| Framebuffer or palette read | Immediately after E+1 | Synchronous memory read sampled at E. |
| UART RX read | Immediately after E | Returns and pops the oldest queued byte at E; an empty read faults without popping. |

Every response stays stable until accepted. The earliest response handshake is
the next rising edge after valid is asserted; stalled responses do not repeat
side effects or stop timer/UART operation.

## Regions And Holes

| Byte Range | Size / Target | Access / Cache | Reset / Bounds |
| --- | --- | --- | --- |
| `0x00000000..0x00003FFF` | 16 KiB boot ROM | RO, uncached, single word | Default NOP fill with RAM-jump stub in first three words; optional `ROM_FILE` preload. Reset does not rewrite it. |
| `0x10000000..0x10004FFF` | Peripheral decode window | Uncached, single word | Only the registers listed below exist; video subwindow routed separately. All other aligned words fault. |
| `0x20000000..0x2000F9FF` | Page 0, 64,000 pixel bytes | RW, uncached | Undefined contents on reset. Last valid word starts at `0x2000F9FC`. |
| `0x2000FA00..0x2000FFFF` | Page 0 stride hole, 1,536 bytes | No access | Reads/writes fault. |
| `0x20010000..0x2001F9FF` | Page 1, 64,000 pixel bytes | RW, uncached | Undefined contents on reset. Last valid word starts at `0x2001F9FC`. |
| `0x2001FA00..0x2001FFFF` | Page 1 stride hole, 1,536 bytes | No access | Reads/writes fault. |
| `0x60000000..0x63FFFFFF` | 64 MiB external assets | RO, cached reads | Contents supplied by external implementation/preload; writes fault at SoC decoder. |
| `0x80000000..0x80FFFFFF` | 16 MiB external application RAM | RW, cached | Hardware reset contents unspecified; external controller supplies storage. |

Everything else is unmapped and faults, including `0x00004000`,
`0x10005000`, `0x20020000`, `0x64000000`, and `0x81000000`.
Inside the peripheral window, only the fifteen exact aligned addresses in the
tables below are valid. There are no register mirrors: UART holes start at
`0x10000010`, timer holes at `0x10001010`, GPIO holes at `0x10002008`,
video holes at `0x10003010`, and reserved-status holes at `0x10004004`, continuing
to each subwindow's end. The video subwindow is `0x10003000..0x10003FFF`.

Cached RAM and asset reads use 32-byte lines; the last legal eight-word burst
starts at `0x80FFFFE0` or `0x63FFFFE0`, respectively. The last legal
single-word reads start at `0x80FFFFFC` or `0x63FFFFFC`. RAM writes accept
all four strobes, including a successful zero-strobe no-op. Behavioral
`sim_ram` zero-initializes storage once, then optionally preloads it; reset
only resets protocol state, not stored data. This is not a hardware RAM reset
guarantee. Asset read-only enforcement is in `soc_top`, not `sim_ram` itself.

The 64 MiB asset window is deliberate: the complete Freedoom 0.13.0 Phase 1
WAD is **28,795,076 bytes**, plus 64 bytes of header, exceeding 16 MiB.
Application RAM remains 16 MiB. Simulation allocates a separate 64 MiB asset
model; a 16 MiB physical Boolean-board flash remains insufficient and no
physical flash controller/loader is implemented. See
[Architecture](architecture.md#firmware-and-storage) and [Software](software.md).

## UART

Default UART is 115200 baud, 8 data bits, no parity, one stop bit. Bit time is
`max(2, round(CLK_HZ / BAUD))` CPU clocks (434 at 50 MHz). RX is synchronized
through two stages. TX and RX each have a 16-byte FIFO. FIFO counts exclude the
byte currently being transmitted, so TX can hold 16 queued bytes plus one active
byte. `CLK_HZ` and `BAUD` are elaboration parameters, not writable MMIO registers.
Reset empties both FIFOs, clears errors,
and leaves TX idle high; FIFO array contents themselves need not be reset.

| Address | Register / Width | Access / Reset | Behavior And Errors |
| --- | --- | --- | --- |
| `0x10000000` | UART status, 32 bits | RO / `0x00000010` | Bits detailed below. Any write faults. |
| `0x10000004` | UART TX, low 8 bits | WO / empty FIFO | Strobe 0 enqueues `wdata[7:0]`; other strobes ignored. Any read faults. If no enqueue space, write faults and sets TX-overflow. If strobe 0 is clear, accepted no-op even when full (including zero strobes). |
| `0x10000008` | UART RX, low 8 bits | RO / empty FIFO | Read returns oldest byte in bits 7:0, upper bits zero, and pops once on request acceptance. Empty read faults. Any write faults, without popping. |
| `0x1000000C` | UART errors, 3 bits | RW, write-one-to-clear / 0 | Read returns sticky errors. Strobe 0 clears each bit whose write value is 1; other lanes and bits ignored. Zero-strobe write is a no-op. Concurrent new errors win over clearing. |

| Status Bits | Meaning |
| --- | --- |
| 0 | Busy: TX shift register active or TX FIFO nonempty. |
| 1 | RX ready: RX FIFO nonempty. |
| 2 | RX full: count equals 16. |
| 3 | TX full: queued count equals 16. |
| 4 | TX space: queued count less than 16. |
| 12:8 | RX queued count (5 bits, 0..16). |
| 20:16 | TX queued count (5 bits, 0..16). |

Error bit 0 is RX overflow, bit 1 TX overflow, bit 2 framing error. RX overflow
drops a valid incoming byte when there is no slot; a simultaneous RX pop frees
a slot. An invalid stop bit sets framing error and discards that byte.
A full TX FIFO can still accept a write on a cycle that starts transmitting
its oldest byte; the space/full status describes the pre-acceptance count.
`sim_tx_valid` pulses on successful enqueue, not serial transmission completion.
Firmware currently waits for busy to clear before writing, a conservative
policy rather than FIFO-throughput optimization.

## Timer

`mtime` increments once per non-reset CPU clock, not milliseconds. There is no
atomic 64-bit MMIO transaction or read snapshot. `timer_irq` is continuously
`mtime >= mtimecmp`, feeding CPU `mip.MTIP`; reads do not acknowledge it.

| Address | Register / Width | Access / Reset | Behavior And Errors |
| --- | --- | --- | --- |
| `0x10001000` | `mtime` low, 32 bits | RW / 0 | Byte-merge write to low half, preserving high half. A write with any strobe overrides the entire counter increment on that edge. |
| `0x10001004` | `mtime` high, 32 bits | RW / 0 | Byte-merge write to high half, preserving low half. A write with any strobe overrides the entire counter increment on that edge. |
| `0x10001008` | `mtimecmp` low, 32 bits | RW / `0xFFFFFFFF` | Byte-merge write preserving high half; may assert/deassert IRQ. |
| `0x1000100C` | `mtimecmp` high, 32 bits | RW / `0xFFFFFFFF` | Byte-merge write preserving low half; may assert/deassert IRQ. |

All four registers accept reads and all byte-write strobes without a register
error. A zero-strobe write leaves the selected storage unchanged; `mtime`
still performs its normal increment in that case. Reads return the value before
the acceptance edge's increment. Firmware uses high/low/high with retry for a
consistent `mtime` read and writes compare high=`0xFFFFFFFF`, then low, then
final high to avoid a transient early timer match. Reset compare is all ones;
timer IRQ is initially low. There is no interrupt-clear register.

## GPIO And Reserved Status

| Address | Register / Width | Access / Reset | Behavior And Errors |
| --- | --- | --- | --- |
| `0x10002000` | GPIO input, 32 bits | RO / synchronizer stages 0 | Returns two-stage synchronized `gpio_in`, then follows pins after reset. Any write faults. No debounce or interrupt. |
| `0x10002004` | GPIO output, 32 bits | RW / 0 | Reads output latch; writes byte-merge all strobed lanes. Zero-strobe write is a no-op. |
| `0x10004000` | Reserved storage-status stub, 32 bits | RO / 0 | Always returns zero; no storage-ready/capability state is implemented. Any write faults. |

## Video Registers

All reads return a 32-bit word. Reset values assume both CPU and pixel domains
are reset. Vblank and page status cross clock domains and are not instantaneous
pixel-domain samples.

| Address | Register / Width | Access / Reset | Behavior And Errors |
| --- | --- | --- | --- |
| `0x10003000` | Video control/status, 4 read bits | RW / 0 | Read bit 0 enable, bit 1 flip pending, bit 2 reported displayed page, bit 3 synchronized vblank. Strobe-0 write sets enable from bit 0 only; status bits/other lanes ignored. Zero-strobe write is a no-op. |
| `0x10003004` | Page request, 1 read bit | RW / 0 | Read returns requested page, not necessarily displayed page. Strobe-0 write submits page 0 or 1. If a flip is pending or the **full 32-bit write data is greater than 1**, faults without changing request. Other lanes alone, or zero strobes, are accepted no-ops even while pending. |
| `0x10003008` | Palette index, 8 bits | RW / 0 | Read returns index; strobe-0 write replaces bits 7:0. Other data bits/lanes ignored. No auto-increment. |
| `0x1000300C` | Palette data, 24 bits | RW / undefined | Read returns selected entry as `0x00RRGGBB`. Strobed lanes 0/1/2 update B/G/R independently; strobe 3 is ignored. Zero strobes or strobe 3 alone are accepted no-ops. No auto-increment. |

Status bit 2 retains the last acknowledged page while a flip is pending, and
reports requested page after its acknowledgement has synchronized back. Vblank
means vertical count >=480, not horizontal blank. A page request toggles the
handshake even if requesting the already displayed page. It completes during
vertical blank, including when image output is disabled; enabling output is
independent of flipping. Poll pending before submitting another request.

Page validation compares all write-data bits, not just strobed byte 0; therefore
use a full-word value of 0 or 1 for page requests. Palette accesses do not fault
for any index (all 256 entries exist). Framebuffer and palette reads use a
synchronous memory read before responding; ordinary register reads and writes
also retain their responses under backpressure. Side effects occur only once
on request acceptance, not again when the response is accepted.

## Framebuffer

Each valid page is a row-major 320x200 array of 8-bit palette indices with no
row padding: pixel `(x,y)` is at `base + 320*y + x`. Page bases are
`0x20000000` and `0x20010000`, not 64,000 bytes apart. Reads return four
adjacent pixels in little-endian lane order; writes independently update any
strobed pixel lanes. A zero-strobe write at a valid aligned word succeeds
without modifying pixels. Any access in either stride hole faults even with
zero strobes. Pixels and palette are uncached and have undefined reset contents.

CPU reset clears enable; pixel reset clears the output masks, so RGB is black
without clearing either memory. Software must initialize pixels/palette before
enabling display. Disabling display becomes effective after synchronization
and scanout-mask latency; it does not erase memory or stop raster timing.
There is no hardware protection against writing the displayed page or changing
palette during scanout. See [Architecture: Video And Clocks](architecture.md#video-and-clocks).
