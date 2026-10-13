# Boolean Board Boundary

There is **no usable board bitstream** in this project. `soc_top` is a generic
SoC boundary with `cpu_clk`, `rst_n`, `pixel_clk`, `pixel_rst_n`, UART, GPIO,
video and a generic external-memory transaction bus. It is not a board wrapper.
The reset inputs must deassert synchronously to their respective clock domains.

The assessment target is `xc7s50csga324-1`. Confirm the actual device/package
and board revision before a physical design. The only provisional package pin
assignments recorded in `boards/boolean/provisional.xdc` are the 100 MHz clock
`F14`, UART TX `U11` and UART RX `V12`. These are provisional and not independently
verified. No reset, GPIO, video, I/O-bank voltage, I/O-standard or memory pinout
has been established. Do not treat that file as sufficient to program hardware.

## Missing Hardware

- A board wrapper with the verified oscillator frequency, legal clock primitive
  configuration, CPU 50 MHz, pixel 25.175 MHz and 5x serializer clocks, and reset synchronization.
- A real memory controller, initialization/calibration and verified RAM pinout
  for the generic bus. The SoC decodes 16 MiB writable RAM, but current firmware
  uses its lower 8 MiB; the upper 8 MiB is reserved for the legacy WAD backend.
  An 8 MiB expansion with separate assets needs adjusted decode/cacheability
  bounds or explicit errors for unbacked addresses, never mirrored RAM aliases.
  Do not assume the board supplies RAM. A ready signal is not a memory controller.
- A real hardware loader for application RAM and optional WAD storage before
  releasing CPU reset. The ROM jump stub assumes RAM is already populated;
  simulation provides that preload, but no hardware loader is supplied.
- Board-appropriate display output circuitry and constraints. The generic video
  interface is not HDMI, TMDS, an HDMI PHY or licensed HDMI IP.
- Debounced/synchronized inputs, complete electrical constraints and measured
  timing/interface budgets for all external signals.

## Vivado Assessment

Run from the project root with Vivado on PATH:

```text
vivado -mode batch -source scripts/vivado.tcl -tclargs synth
vivado -mode batch -source scripts/vivado.tcl -tclargs impl
```

The script targets `xc7s50csga324-1` and performs **out-of-context** synthesis
and optional placement/routing without physical I/O buffers. Only
SystemVerilog `.sv` sources are read; `rtl/soc/soc_pkg.sv` is read first. The packed
`soc_pkg::req_t` external bus remains generic and is not bound to physical pins.
Output defaults to `build/vivado`; an optional second argument chooses a path.
It never calls `write_bitstream` and never applies the provisional Boolean pins.

`boards/generic/timing.xdc` describes independent externally supplied clocks:
20.000 ns CPU and 39.721946 ns pixel. These are provisional timing targets, not
proof that board clocks exist. No blanket asynchronous clock-group or false-path
exception hides cross-domain paths. Audit synchronizer attributes, bundled-data
palette/flip paths and reset CDC before adding narrow exceptions. CDC reports
are structural evidence, not proof of protocol safety.

The board has approximately 337.5 KiB BRAM and 16 MiB QSPI flash, but no external
writable DDR, SDRAM, SRAM or PSRAM. Select an 8-16 MiB RAM expansion (or another
board) before creating a physical wrapper. The tested 28.8 MB Freedoom WAD also
requires larger asset storage, such as a selected SD expansion. No Real Digital
HDMI IP is redistributed here. Use verified licensed IP or a separately verified
redistributable DVI/TMDS implementation; the generic RGB video core stays unchanged.

Reports include synthesis utilization/timing and implementation timing (when
requested), DRC, methodology, clocks, clock interaction and detailed CDC.
Unconstrained external paths are deliberately visible. Inspect every warning,
unconstrained path, setup/hold failure, CDC finding and RAM inference. Generic
OOC timing is not board timing closure; external I/O delays and pin/electrical
constraints cannot be invented. No Vivado run or utilization/timing number is
claimed unless the actual tool reports have been produced and reviewed.
