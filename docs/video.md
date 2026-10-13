# Video and Peripheral Interfaces

## Files and Integration

| File | Module / purpose |
| --- | --- |
| `rtl/video/video_core.sv` | `video_core`: local indexed-color framebuffer, palette, VGA timing and blank-only page flip |
| `rtl/peripherals/peripherals.sv` | `peripherals`: polling UART, timer, GPIO and unavailable-storage stub |
| `sim/unit/tb_video.sv` | CPU transactions and independent pixel/raster scoreboard with asynchronous clocks |
| `sim/unit/tb_peripherals.sv` | CPU transactions, timer model, physical UART decoder, loopback and external RX tests |

Both modules use the same flattened, single-outstanding interface:

```systemverilog
input  wire        req_valid;
output wire        req_ready;
input  wire [31:0] req_addr;
input  wire        req_write;
input  wire [3:0]  req_wstrb;
input  wire [31:0] req_wdata;
output wire        rsp_valid;
input  wire        rsp_ready;
output wire [31:0] rsp_rdata;
output wire        rsp_error;
```

Requests are accepted on a rising clock edge with `req_valid && req_ready`.
Every accepted request, including a write or an invalid access, produces exactly
one response. Response valid, data and error are held until `rsp_ready`. No new
request is accepted while a response is held; framebuffer/palette reads also
block requests during their synchronous read stage. There are no burst, length,
last, DMA or external memory signals. Reset cancels outstanding transactions.

Addresses are full 32-bit byte addresses, not register offsets. All transactions
must be word aligned; subword writes use little-endian byte strobes on an aligned
word address. Reads return the entire register/word. Writes return zero data.
Unsupported addresses and wrong-direction register accesses return zero data and
`rsp_error = 1`, without register or memory changes. A zero-strobe write to a
writable register succeeds as a no-op. Read-only registers still reject writes.
Register side effects happen on request acceptance, never on response consumption.
Timer counting and UART serialization/reception continue during response stalls.

### Video Ports

`video_core` has `cpu_clk`, `cpu_rst_n`, `pixel_clk`, `pixel_rst_n`, the bus above,
`vga_r[7:0]`, `vga_g[7:0]`, `vga_b[7:0]`, `vga_hsync`, `vga_vsync` and
`active_video`. The bus belongs to `cpu_clk`; video outputs belong to `pixel_clk`.
Resets are active low, asynchronously asserted and must be synchronously released
by the surrounding clock/reset logic. Assert both resets together for a system
reset; independently resetting a domain during a pending flip is not supported.
There are no vendor primitive instances or memory-reset ports.

### Peripheral Ports

`peripherals` has `clk`, `rst_n`, the bus above, `uart_tx`, `uart_rx`,
`gpio_in[31:0]`, `gpio_out[31:0]`, `timer_irq`, `sim_tx_valid` and
`sim_tx_data[7:0]`. Parameters default to `CLK_HZ = 50000000` and `BAUD = 115200`.
All outputs except the serial pin are in the `clk` domain. UART RX and GPIO
inputs pass through two synchronizer flops; GPIO synchronization is not debouncing
or an atomic snapshot of unrelated changing pins.

`sim_tx_valid` is a one-clock pulse for each successfully enqueued TX byte, with
that byte on `sim_tx_data`. It is not a transmission-completion event. The pins
are ordinary synthesizable outputs and can be left unconnected outside simulation.

## Framebuffer

| Range | Meaning |
| --- | --- |
| `0x20000000..0x2000f9ff` | Page 0: 64,000 bytes, 320 x 200 palette indices |
| `0x2000fa00..0x2000ffff` | Reserved; all accesses error |
| `0x20010000..0x2001f9ff` | Page 1: 64,000 bytes, 320 x 200 palette indices |
| `0x2001fa00..0x2001ffff` | Reserved; all accesses error |

Both pages are implemented. The memory is organized as 32,768 x 32-bit words
(128 KiB physically, including inaccessible padding), with CPU byte-write
enables and a synchronous, read-only pixel-clock port. The last legal aligned
word in each page is at offset `0xf9fc`. Pixel `(x,y)` is the byte at
`page_base + y*320 + x`. Byte lane 0 is the lowest-addressed pixel.

Framebuffer and palette contents are undefined at power-up and are not cleared
by reset. Software must initialize all displayed framebuffer bytes and every
palette entry that they reference before enabling display. Reset selects page 0
and disables color output, so all RGB outputs are black even with undefined RAM.
Sync and visible-region signaling continue while disabled. Memory contents survive
a control reset but software must not assume contents survive power-up.

Writes to the page being scanned may tear. Simultaneous CPU write and pixel read
of the same word or palette entry have device-dependent read-during-write behavior.
For tear-free updates, write the inactive page and request a flip. Palette updates
are not double-buffered or atomic. The pixel port reads the palette on every pixel
clock, even in blanking, with output disabled, or during pixel reset. Disabling
output masks RGB; it does not stop palette reads or prevent same-entry collisions,
whose read result is unspecified by this RTL.

Software should initialize the palette while output is disabled. When disabling
an already enabled display, allow two pixel clocks for enable synchronization and
two more for the output-mask pipeline to drain before updating it; control bit 0
only reports the CPU enable latch, not completion of that drain. After the final
palette write, allow at least two further pixel clocks for the color pipeline to
settle before enabling output. This masks update artifacts, not memory collisions;
it does not provide atomic runtime palette changes or a collision-free blanking
window. These waits describe RTL pipeline latency, not a metastability bound.
Target memory read-during-write behavior still needs implementation review.
Actual BRAM mapping, resource use and timing must be checked in the target FPGA
synthesis flow; `ram_style = "block"` is an inference hint, not a mapped-netlist proof.

## Display Registers

| Address | Access | Description |
| --- | --- | --- |
| `0x10003000` | R/W | Status/control: bit 0 enable; bit 1 flip pending; bit 2 CPU-acknowledged displayed page; bit 3 synchronized vertical blank. Writes update enable only, with byte strobe 0. |
| `0x10003004` | R/W | Write full value 0 or 1 with byte strobe 0 to request that page. Read the requested page. Pending duplicate requests, including requests for the same page, and values greater than 1 error. |
| `0x10003008` | R/W | Palette index, low eight bits, written with byte strobe 0. No automatic increment. |
| `0x1000300c` | R/W | Palette entry at the current index, bits 23:0 = `0xRRGGBB`; byte strobes 0, 1, 2 update B, G, R. Byte strobe 3 is ignored. Reads zero-extend to 32 bits. |

Other status bits are zero. The palette is 256 x 24-bit synchronous dual-clock
memory. CPU framebuffer/palette reads respond one additional CPU edge later than
register accesses, to preserve a synchronous BRAM read port.

### Page Flip CDC

CPU acceptance latches the requested page and toggles a request bit. The page is
held until the pixel domain acknowledges that toggle. Two-flop synchronizers
carry request and page; an additional request staging clock allows the bundled
page data to settle before use. Only while the raw raster has `y >= 480` may the
pixel domain change its displayed page and acknowledge the toggle. This can occur
anywhere in vertical blank, not just on its first pixel. A request that reaches
the synchronizer too late for blank waits through the next visible frame.

The acknowledgment passes back through two CPU-clock synchronizer flops. Status
pending stays set until this acknowledgment returns. The displayed-page status
is coherent when pending clears. Software can poll pending before reusing the
old displayed page or submitting another flip. A page flip can complete while
its bus response is stalled; bus response acceptance and flip acknowledgment are
separate events. Disabled display still accepts and completes blank-only flips.

Status bit 3 uses a separate registered pixel-domain flag: `pixel_vblank` samples
the pre-edge `v_count >= 480` decode on each pixel clock, then crosses through two
CPU-clock synchronizer stages. It therefore changes one pixel clock after the raw
counter enters or leaves vertical blank, followed by two CPU sampling edges: the
first captures the source flag and the second publishes it. Coincident source and
CPU edges sample the pre-edge flag in RTL simulation. A status read snapshots the
synchronized value before its acceptance edge's synchronizer update. Clock phase
affects the elapsed delay; this is not an instantaneous raster sample. Page-flip
eligibility still uses raw pixel-domain `v_count >= 480`, not this delayed flag;
flip acknowledgment, raster timing and RGB pipeline latency are unchanged.

## Raster and Pipeline

Use a nominal 25.175 MHz pixel clock for approximately 59.94 Hz VGA, or 25 MHz
for approximately 59.52 Hz. Timing is fixed in pixel clocks:

| Axis | Visible | Front Porch | Sync | Back Porch | Total |
| --- | --- | --- | --- | --- | --- |
| Horizontal | 640 | 16 | 96 | 48 | 800 |
| Vertical | 480 | 10 | 2 | 33 | 525 |

HSYNC is active low at `x = 656..751`; VSYNC is active low at `y = 490..491`.
`active_video` marks all 640 x 480 visible pixels, including the black bars.
The 320 x 200 image is doubled in both axes: `source_x = x/2`,
`source_y = (y-40)/2`, with visible image at `x = 0..639`, `y = 40..439`.
Lines 0..39 and 440..479 are black. All porches and sync intervals are black.

At one pixel edge the framebuffer word and its byte lane are registered. At the
next edge the palette color for that byte is registered. HSYNC, VSYNC, visible
and image-enable masks pass through the matching two-register pipeline. Output
RGB thus corresponds to the coordinate sampled at the preceding pixel edge,
including at image edges, line ends and frame wrap. The palette color is masked
to black rather than exposing uninitialized or stale pipeline data in blanking.

## Peripheral Registers

### UART

UART is polling-only, 8 data bits, no parity, one stop bit, idle high, LSB first.
The rounded bit divider is `(CLK_HZ + BAUD/2) / BAUD`, clamped to a minimum of two
clocks. Choose a clock/baud ratio comfortably above two for reliable synchronized
RX sampling; the default divider is 434 clocks, giving approximately 115207 baud.
The receiver validates the middle of the start bit, then samples the centers of
eight data bits and the stop bit. There is no flow control or UART interrupt.

| Address | Access | Description |
| --- | --- | --- |
| `0x10000000` | R | Status: bit 0 TX busy (active serializer or queued bytes); bit 1 RX nonempty; bit 2 RX full; bit 3 TX FIFO full; bit 4 TX FIFO has space; bits 12:8 RX count; bits 20:16 TX queued count. |
| `0x10000004` | W | Enqueue low byte with byte strobe 0; other lanes ignored. Full TX FIFO rejects the byte, returns an error and sets sticky TX overflow. |
| `0x10000008` | R | Return and pop the oldest RX byte on acceptance. An empty read returns zero and an error without popping. |
| `0x1000000c` | R/W1C | Sticky errors: bit 0 RX overflow, bit 1 TX overflow, bit 2 bad stop/framing. Write ones in byte lane 0 to clear; a concurrent new error takes precedence over clearing. |

TX and RX FIFOs each hold 16 bytes. TX count excludes the byte actively being
serialized. RX overflow drops the newly arriving byte and preserves queued data.
Malformed stop bits do not enqueue a byte. A simultaneous RX pop and arrival can
replace the head of a full FIFO without overflow. Similarly a simultaneous TX
serializer dequeue permits a CPU enqueue even when the TX FIFO was full. Status
is a snapshot, so polling software should still handle a TX write error.

### Timer

| Address | Access | Description |
| --- | --- | --- |
| `0x10001000` | R/W | `mtime[31:0]` |
| `0x10001004` | R/W | `mtime[63:32]` |
| `0x10001008` | R/W | `mtimecmp[31:0]` |
| `0x1000100c` | R/W | `mtimecmp[63:32]` |

`mtime` resets to zero and increments every CPU clock. `mtimecmp` resets to
`0xffffffffffffffff`. `timer_irq` is the level comparison `mtime >= mtimecmp`;
there is no interrupt acknowledgment register. All writes honor all four byte
strobes. A nonzero-strobe `mtime` write replaces the selected bytes and takes
priority over that edge's increment; counting resumes on the following edge.
A zero-strobe write does not stop counting.

There is no atomic 64-bit read latch. Read time high, low, high and retry if the
high words differ. To avoid transient compare interrupts, write compare high
to `0xffffffff`, then the desired low word, then the desired high word.

### GPIO and Storage

| Address | Access | Description |
| --- | --- | --- |
| `0x10002000` | R | Two-flop synchronized 32-bit GPIO inputs |
| `0x10002004` | R/W | 32-bit GPIO output register, reset zero, byte strobes honored |
| `0x10004000` | R | Storage status is always zero: unavailable/not present/not ready |

All other storage offsets and all storage writes error. This stub cannot claim
successful block transfers. Display addresses belong to `video_core`, not
`peripherals`; framebuffer transactions also route directly to `video_core`.

## Unit Verification

Run from the repository root with Icarus Verilog and its runtime available:

```powershell
iverilog -g2012 -Wall -s tb_peripherals -o tb_peripherals.vvp rtl/peripherals/peripherals.sv sim/unit/tb_peripherals.sv
vvp tb_peripherals.vvp
iverilog -g2012 -Wall -s tb_peripherals "-Ptb_peripherals.CLK_HZ=50000000" -o tb_peripherals_50m.vvp rtl/peripherals/peripherals.sv sim/unit/tb_peripherals.sv
vvp tb_peripherals_50m.vvp
iverilog -g2012 -Wall -s tb_video -o tb_video.vvp rtl/video/video_core.sv sim/unit/tb_video.sv
vvp tb_video.vvp
iverilog -g2012 -Wall -s tb_video "-Ptb_video.PIXEL_HALF=17" "-Ptb_video.PIXEL_PHASE=7" -o tb_video_async.vvp rtl/video/video_core.sv sim/unit/tb_video.sv
vvp tb_video_async.vvp
```

Both benches have bounded global timeouts, accepted-request/consumed-response
accounting, response stability assertions and requests held across response
stalls. Write payloads change after acceptance to catch repeated write side
effects even where an identical repeated write would otherwise be invisible.

The peripheral bench checks timer advancement through stalls, 64-bit carry,
compare IRQ assertion/clear, byte strobes, synchronized GPIO, unavailable storage,
bad addresses/directions, physical UART start/data/stop timing and byte order,
loopback, FIFO fullness, overflow/drop policy, wrapping, sticky W1C errors,
framing rejection, simultaneous full-FIFO arrival/pop and false-start rejection.
It runs at both an accelerated 16-clock baud divider and the actual 50 MHz / 115200
configuration with a 434-clock divider.

The video bench checks black output with undefined memory while disabled,
framebuffer limits/gaps/page isolation, byte strobes, all 256 palette entries,
512 CPU framebuffer readbacks, and every output pixel across four complete frames
plus partial frames. It independently checks RGB mapping, horizontal/vertical
doubling, bars, porches and memory-pipeline alignment. Each full frame must have
307,200 visible clocks, 50,400 HSYNC-low clocks and 1,600 VSYNC-low clocks.
It checks invalid/pending duplicate flips, acknowledgment status and a flip
submitted at the last blank pixel that must wait until the next vertical blank.
It checks the source vblank register against the independent raster model, both
CPU synchronizer stages for vblank and flip acknowledgment, and acceptance-edge
status snapshots near blank entry, frame wrap and page acknowledgments. Four
blank rises/falls, two acknowledgment transitions and ten status reads are required.
Two unequal clock-period/phase configurations exercise the toggle handshake.

These are RTL simulation/elaboration tests, not FPGA synthesis, routed timing,
analog UART tolerance or a formal CDC proof.

### Recorded Results

Recorded with Icarus Verilog 14.0 (development build, Windows x64). The peripheral
rows retain their earlier passing results. Both video configurations were rerun
after registering the vblank source and extending the status/acknowledgment checks;
both `-g2012 -Wall` compilations completed with exit code 0 and no diagnostics,
and both full-pixel simulations completed with exit code 0:

| Configuration | Exact Result |
| --- | --- |
| Peripherals, `CLK_HZ=1843200`, `BAUD=115200` | PASS; `BIT_CLKS=16`, requests=107, responses=107, tx_events=20, serial_bytes=20 |
| Peripherals, `CLK_HZ=50000000`, `BAUD=115200` | PASS; `BIT_CLKS=434`, requests=107, responses=107, tx_events=20, serial_bytes=20 |
| Video, `CPU_HALF=10`, `PIXEL_HALF=19`, `PIXEL_PHASE=3` ns | PASS; requests=33328, responses=33328, checked_pixels=1799998, complete_frames=4, page_changes=2 |
| Video, `CPU_HALF=10`, `PIXEL_HALF=17`, `PIXEL_PHASE=7` ns | PASS; requests=33328, responses=33328, checked_pixels=1799998, complete_frames=4, page_changes=2 |

Both video runs also reported `blank_rises=4`, `blank_falls=4`,
`ack_transitions=2`, and `status_reads=10`. The four added status transactions
do not alter the framebuffer/palette test patterns or expected raster/RGB output.

These standalone results do not imply board timing or CDC signoff. Whole-SoC
checks, including lint and the graphical diagnostic, are recorded in
[Verification](verification.md).
