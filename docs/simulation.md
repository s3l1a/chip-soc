# Simulation

The real custom CPU executes every instruction. No benchmark changes its PC,
registers, loaded framebuffer or memory responses to substitute software work.
Only firmware and assets are preloaded before reset, just as permitted for the
early simulation boot path.

## Entry And Memory

`sim/soc/tb_soc.sv` instantiates the entire generic `soc_top`, two caches,
interconnect, all implemented peripherals and video, plus separate behavioral
memory arrays. Reset PC is zero. The 16 KiB ROM contains:

```text
800002b7   lui t0,0x80000
0000100f   fence.i
00028067   jalr zero,0(t0)
```

Firmware `.mem` words index RAM relative to `0x80000000`. Assets use another
array based at `0x60000000`, not the same word offsets. Asset writes are faulted
by the SoC. The model has 16 MiB writable RAM and a 64 MiB read-only asset
aperture. The latter is a documented simulation expansion, not physical flash
capacity or a replacement for RAM. See `memory-map.md`.

CPU clock is 50 MHz; pixel clock is 25 MHz (about 59.524 output frames/second).
Behavioral memory deterministically varies the response delay from 0 to 3 extra
clocks per beat. Unit/CPU tests use other seeds and longer delays.

## Diagnostic

```sh
python scripts/build_firmware.py all
python scripts/run.py soc --frames 1 --prefix diagnostic
python tools/verify_frame.py --diagnostic build/soc/diagnostic_1.ppm
```

The firmware validates initialized data, zero BSS and allocation, initializes
both framebuffer pages and the RGB332 palette, then flips to page one. The
checker independently derives every pixel, including centering and scaling.
UART must report `data/bss/heap OK`. A normal missing WAD is not a test failure
for diagnostic firmware.

## Doom Segment

Two fresh six-frame runs on the current RTL passed with identical captures and
are recorded in `docs/doom-hashes.json`; the commands below reproduce them.

First follow `software.md` to fetch the pinned GPL source, build firmware and
verify/package a legally obtained WAD. The tested Freedoom Phase 1 asset uses
the flash backend. No WAD belongs in source control.

```sh
python scripts/run.py soc --firmware firmware/build/doom.mem --wad firmware/build/wad.mem --frames 6 --cycles 950000000 --prefix doom_final_a
python scripts/run.py soc --no-build --firmware firmware/build/doom.mem --wad firmware/build/wad.mem --frames 6 --cycles 950000000 --prefix doom_final_b
python scripts/check_doom.py
python tools/functional_soc.py --frames 6 --compare-rtl --rtl-prefix build/soc/doom_final_a --output build/emulator/final_strict_a
```

`--no-build` reuses compiled RTL only; it does not bypass CPU execution.
The recorded six captures at game tics 2-7 passed twice. Initial stationary
frames legitimately match each other; later movement produces different images. Startup wipe
suppression happens in the post-load graphics callback, avoiding timing-dependent
melt frames in the benchmark. Normal builds can disable `CHIP_TIMEDEMO`.

This is not a complete timedemo result. To request more frames, raise `--frames`
and the watchdog deliberately, and increase `CHIP_FRAME_LOG` if UART checksums
are needed. The full DEMO1 contains 7,117 tics and would take substantially
longer at this correctness-first CPU's observed performance. Do not treat
watchdog termination or emulator-only execution as a passed RTL run.

## Captures And Assertions

PPM files contain the actual 640x480 output, with sync/active metadata aligned to
the two memory stages. Capture begins with the next complete output frame after
an acknowledged page change. It never assembles an image directly from WAD data.
The checker validates black borders, all 2x2 pixel groups, exact palette levels,
recovered indexed FNV, full-file SHA-256, consecutive guest tics and both logs.

The harness checks stable requests/responses and accepted transaction ownership
on CPU I/D, both cache downstream interfaces and external memory. It fails on
traps, modified x0, framebuffer padding writes, asset writes, bad alignment,
unsolicited/duplicate responses, incorrect burst length or watchdog expiry.
Unit tests add dedicated refill/reset/error and CDC/palette/timing checks.

`SOC_FLIP` reports cycle and cumulative external response beats. The PASS summary
reports cycles, retirements, bytes, framebuffer write request count and captures.
Bytes count every external response beat times four, including write acknowledgments:
this is bus-beat-equivalent traffic accounting, not DRAM physical-wire efficiency.
Video scanout never reads the external memory interface.

Logs, frames and compiled simulators remain in ignored `build/soc/`.
Use `python scripts/run.py report` or `scripts/check_doom.py` for hashes and
measured performance. Exact baseline provenance is in `doom-hashes.json`.
