# XC7 Resource Feasibility

Yosys synthesis of the generic `rtl/soc/soc_top.sv` snapshot succeeded on
2026-10-13, using the Slang SystemVerilog frontend. These fresh runs include the
machine CSR and registered video-vblank fixes, reset-free synchronous ROM read,
and cached read-only external asset window at `0x60000000..0x63ffffff`. The measured netlist is
below XC7S50 resource capacities, including a dense 16 KiB ROM budgeting case.
These are snapshot measurements; later RTL changes require a new assessment.
**This is resource feasibility, not proof of package fit or timing closure.**
Vivado is not available on PATH; no vendor synthesis, placement, routing,
timing analysis, CDC signoff, or bitstream generation was performed.

## Reproduce

Run from the project root with Python 3.10 or newer:

```powershell
python scripts/synth_yosys.py --out build/synth/release_default
python scripts/synth_yosys.py --rom-budget --out build/synth/release_dense
python scripts/synth_yosys.py --rom-file firmware/build/boot.mem --out build/synth/boot_file
```

The script discovers Yosys on PATH, then checks the portable OSS CAD Suite
destination `%TEMP%\chip-tools\oss-cad-suite` (or `CHIP_TOOL_DIR`). Install the
suite first as described in [tooling.md](tooling.md). To select it explicitly:

```powershell
$suite = Join-Path $env:TEMP 'chip-tools\oss-cad-suite'
python scripts/synth_yosys.py --yosys (Join-Path $suite 'bin\yosys.exe')
```

Only the subprocess PATH is adjusted to find suite binaries/DLLs. Nothing is
downloaded or installed by this script. Source, output, and ROM paths must not
contain whitespace, quotes, semicolons, or `#`; this avoids literal-token path
handling problems in the Slang/Yosys command interface.

The successful toolchain is pinned to OSS CAD Suite `2026-10-11`, whose archive
and SHA-256 are recorded in [tooling.md](tooling.md). Tool identities:

| Tool | Identity |
| --- | --- |
| Yosys | `0.69+274`, Git `7513f8df8` |
| `bin/yosys.exe` SHA-256 | `bafe6f5c0493c29126222a7b5b7818d93c92ef40938c7cfcdb1e36bb67587024` |
| `share/yosys/plugins/slang.so` SHA-256 | `8b9f1c97682ef71024bebdff82abaf01045f9f7c37d03233ab2f0c551bca3306` |

`plugin -i slang` succeeds. The actual frontend command is `read_slang`, not
`read_systemverilog` (the latter is unavailable in this build). The generated
`synth.ys` records the exact absolute source paths and commands. The essential
flow is:

```text
plugin -i slang
read_slang --top soc_top --unroll-limit 65536 --ignore-assertions <sources>
hierarchy -check -top soc_top
proc
opt_clean
memory_collect
synth_xilinx -family xc7 -top soc_top -flatten -noiopad
check -assert -mapped
stat -tech xilinx -top soc_top
```

All canonical `rtl/**/*.sv` sources are read with `soc_pkg.sv` first, excluding
`rtl/memory/sim_ram.sv`. No testbench, simulated external RAM, or board wrapper is
included. The generic external-memory bus and trace outputs remain observable.
The asset window is routed through that external bus and the existing caches;
its 64 MiB address space is not allocated as on-chip storage by this assessment.
I/O pads are omitted for out-of-context assessment; clock buffers, DSP mapping,
and BRAM/LUTRAM inference remain enabled. Memory is not indiscriminately lowered
to flip-flops before `synth_xilinx` can infer BRAM. The increased unroll limit
allows the 4096-word ROM initialization loop.

## Measured Utilization

The assessment target is `xc7s50csga324-1`. Yosys maps the **XC7 family**, not the
part/package/speed grade; XC7S50 capacities are used only for comparison.

| Resource | Default Boot Stub | Dense 16 KiB ROM | XC7S50 Capacity |
| --- | ---: | ---: | ---: |
| Logic LUT primitives | 11,377 | 11,549 | 32,600 LUTs total |
| Distributed RAM | 4 RAM32M + 16 RAM64M | Same | Shares LUT/SLICEM resources |
| Logic LUTs + nominal LUTRAM allocation | 11,457 (35.1%) | 11,629 (35.7%) | 32,600 |
| Flip-flops | 2,673 (4.1%) | 2,673 (4.1%) | 65,200 |
| RAMB36E1 | 41 | 45 | 75 BRAM36 sites |
| RAMB18E1 | 5 | 2 | Two halves per BRAM36 site |
| BRAM36 equivalents | 43.5 (58.0%) | 46 (61.3%) | 75 |
| DSP48E1 | 5 (4.2%) | 5 (4.2%) | 120 |
| BUFG | 2 (6.3%) | 2 (6.3%) | 32 global clock buffers |
| CARRY4 | 276 | 276 | Requires legal slice packing |
| Total mapped cells, all types | 14,601 | 14,775 | Not a device-capacity metric |

Each RAM32M/RAM64M nominally allocates four memory-capable LUTs, hence the
additional 80 LUTs. These are primitive-level accounting estimates, not a
Vivado packed-slice report; unused lanes, LUT combining, local resource mix,
clock regions, and routability require implementation checks. Do not equate
marketing logic cells with LUTs. Yosys also reports estimated LCs of 10,110 and
10,294; those estimates are not the raw LUT totals above. Total mapped cells
include logic, storage, arithmetic, and clock primitives, not just LUTs.

XC7S50 has 2,700 Kibit of BRAM, or 337.5 KiB including parity capacity. The
default 43.5 BRAM36 equivalents reserve 1,566 Kibit / 195.75 KiB of physical
BRAM; the dense-ROM 46 equivalents reserve 1,656 Kibit / 207 KiB.
Usable payload depends on configured widths, byte-write lanes, parity, and
depth rounding; a simple byte sum is not sufficient to predict BRAM use.
Capacity references: [AMD Spartan-7 product table](https://www.amd.com/en/products/adaptive-socs-and-fpgas/fpga/spartan-7.html)
and [7-Series Product Selection Guide](https://docs.amd.com/v/u/en-US/7-series-product-selection-guide).

Both fresh runs returned success and passed `check -assert -mapped` with no
structural problems reported. This check is not simulation equivalence or CDC
verification. Both manifests record `returncode: 0`, `inputs_unchanged: true`,
and identical RTL source SHA-256 values. Their start times are:

| ROM Mode | Manifest | UTC Start |
| --- | --- | --- |
| Default boot stub | `build/synth/release_default/manifest.json` | 2026-10-13 15:18:36.077259 |
| Dense storage budget | `build/synth/release_dense/manifest.json` | 2026-10-13 15:18:36.077290 |

The measured `soc_top.sv` snapshot has SHA-256
`bf57294ced9ada6e893bfa2ee656df4389491ed03ab78f0ee93c6060f3f42b26`.
The `cache_port.sv` snapshot has SHA-256
`491f4c992190cbaf1bd01af2a8dfe846c84090bb834f07a5cd6c05ff4ccb9cef`.
The fixed `rv32im_cpu.sv` snapshot has SHA-256
`3d3ce58051780857c59c550702dd87dd52c585d309508608a301a8694c95c193`.
The fixed `video_core.sv` snapshot has SHA-256
`6e8bc64113f2507171a0b2066793fb759d8e656acf1e7c871b6d70b3de665a8e`.
The optional explicit boot-file run was not refreshed for this assessment;
its older artifacts are not current release measurements. Rerun after RTL
changes instead of treating these numbers as current forever.

## Memory Inference

The logical data allocations are ROM 16 KiB, two caches totaling 32 KiB, and
framebuffer 128 KiB: 176 KiB before 2.25 KiB of cache tags, 128 bytes of valid
bits, 768 bytes of palette, and 32 bytes of UART FIFO storage. The elaborated
snapshot preserves all these arrays before optimization.

| Logical Storage | Shape | Mapped Storage |
| --- | --- | --- |
| I-cache data | 4096 x 32 | 4 RAMB36E1 |
| D-cache data | 4096 x 32 | 4 RAMB36E1 |
| I-cache tags | 512 x 18 | 1 RAMB18E1 |
| D-cache tags | 512 x 18 | 1 RAMB18E1 |
| Cache valid bits | 2 x (512 x 1) | 16 RAM64M total |
| Framebuffer, CPU/pixel clock ports | 32768 x 32 | 32 RAMB36E1 |
| Palette, CPU/pixel clock ports | 256 x 24 | 1 RAMB36E1 |
| UART TX/RX FIFOs | 2 x (16 x 8) | 4 RAM32M total |
| ROM | 4096 x 32 | Default: 3 RAMB18E1; dense image: 4 RAMB36E1 |

There is no reset of cache data/tag, ROM, framebuffer, or palette array contents in
the measured RTL. Cache validity is cleared by a sequential invalidation walk.
`memory_dff` successfully merges the registered read outputs for these large
RAMs, including both clock-domain ports of the video memories. The mapped
netlist audit confirms all 46 default and all 47 dense-ROM RAMB18E1/RAMB36E1 primitives have
`RSTRAMARSTRAM` and `RSTRAMB` tied low with non-inverted reset polarity.
These primitive reset pins affect RAM outputs, not a bulk erase of stored
contents. Control/response registers outside the storage arrays still reset.

## Actionable Findings

**ROM inference fixed:** `rtl/soc/soc_top.sv:101-103` now uses a dedicated,
reset-free synchronous `rom_data` read register. Response selection at
`rtl/soc/soc_top.sv:92-95` is outside the ROM read path. Both final logs report:

```text
Checking read port `\rom'[0] in module `\soc_top':
    merging output FF to cell.
mapping memory soc_top.rom via $__XILINX_BLOCKRAM_TDP_
```

The dense 4096 x 32 ROM now consumes four BRAM36s as measured, rather than a
large combinational LUT-ROM network. Its overall logic LUT count is 172
higher than the default stub's. Constant ROM columns are optimized in the
default image, which maps to three BRAM18s instead; neither image's storage
is erased by reset. The final dense-image total is the measured 46/75 BRAM36
equivalents, not a projection. This synthesis rerun does not verify the
modified bus-response behavior in simulation.

**Multiplier:** `rtl/core/rv32im_cpu.sv:41-56` maps the signed 33 x 33 multiply
to four DSP48E1 primitives; the fifth DSP is video row-address multiplication
at `rtl/video/video_core.sv:142`. All five have `AREG=BREG=MREG=PREG=0`.
DSP mapping succeeds, but the CPU multiply and surrounding register-file,
decode, result-mux, and adder paths are unpipelined. No frequency, WNS, TNS,
50 MHz operation, or XC7S50 timing closure is established by this result.

**Warnings:** the ABC9 `write_xaiger2` path is marked experimental. EDIF writing
warns about X-valued unused DIA/DIB lanes on cache-valid and UART LUTRAM
primitives. Their unused output lanes do not feed the measured logic, but the
EDIF has not been accepted or checked by Vivado; audit or tie unused inputs
when integrating a vendor flow. These warnings remain in the logs rather than
being suppressed.

## Artifacts And Limits

Each output directory contains:

- `manifest.json`: tool version, command, UTC start, source/ROM digests, return code, and input-stability result.
- `synth.ys` and `yosys.log`: exact replay script and full frontend/mapping/check diagnostics.
- `elaborated.json`: word-level memories before technology mapping.
- `utilization.rpt` and `stat.json`: human-readable and machine-readable Yosys statistics.
- `soc_top.json` and `soc_top.edif`: XC7 primitive netlists for further inspection, not a bitstream.
- `resources.json`: LUT/FF/BRAM/DSP/clock-buffer totals, primitive types, logical memory mappings, BRAM reset audit, and DSP register audit.
- `rom_budget.mem`: only for `--rom-budget`, deterministic xorshift data filling all 4096 words. It is not executable firmware and its netlist must not be used as a boot design.

The current release measurements are in `build/synth/release_default` and
`build/synth/release_dense`. The script's default output remains `build/synth`;
the optional file-override command above uses `build/synth/boot_file` and is not
part of these two measured runs. Repeated runs replace
assessment artifacts in their selected output directory; success artifacts
are cleared before synthesis so a failed attempt cannot reuse an old resource
summary. A nonzero exit or changed inputs means the result must not be used.
The root `.gitignore` excludes `build/`, including these generated netlists,
reports, and manifests.

No physical I/O, board clocks/reset generation, external memory controller,
application RAM, pin constraints, electrical standards, vendor timing, or
timing exceptions are supplied by this flow. The extra board wrapper and
memory controller must fit in the remaining resources. Continue with the
vendor assessment described in [boolean-board.md](boolean-board.md) once
Vivado and verified hardware constraints are available. A generic mapped
netlist and two BUFG cells do not establish a working board or safe CDC.
