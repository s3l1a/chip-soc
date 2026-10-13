# Verification

## Status And Scope

Two fresh Verilator RTL Doom runs were recorded, each with
six consecutive game frames and a successful `tb_soc` summary. The saved
logs and all twelve raw captures have now been independently checked with
`scripts/check_doom.py`: corresponding outputs are byte-identical, match the
golden SHA-256 manifest, and recover the software's indexed-frame FNV checksums.
Guest tics progress consecutively from 2 to 7; the first four identical images
are allowed, and frames 5 and 6 change. Every recovered indexed frame also
matches the saved Unicorn 2.1.4 functional run byte-for-byte.
This verifies a **six-frame RTL game segment**, not completion of the 7,117-tic
Freedoom DEMO1, interactive input coverage, audio, or a physical board run.

GitHub [Verification run 38321155415](https://github.com/s3l1a/chip-soc/actions/runs/38321155415)
passed on Ubuntu 24.04 with Verilator 5.020, covering the
argument regression, lint and units, seeded CPU checks, diagnostic/boot builds,
Doom build-only and exact diagnostic scanout. The workflow does not run the full
Doom program, formal proofs, synthesis or hardware.

An earlier diagnostic watchdog failure came from discarded `$value$plusargs`
calls, not a CPU failure: the bench retained its default three-frame limit even
though the diagnostic flips once. Explicit fallback branches and `tb_plusargs`
now check string, integer and 64-bit arguments with both simulators.

Local release checks (Windows, Python 3.14.4) passed all-RTL lint, all nine seeded
CPU simulations and trace comparisons, 25 software host tests, four Doom-log
self-tests, and the frame checker self-tests. Each full CPU run includes 21,726
trace events; the MISA and arithmetic variants retain 15 and 4,196 entries.
Both expanded video configurations passed 33,328 requests/responses per run.
All six scoped formal prove/cover tasks passed. Earlier unit/peripheral and
legal/eight-negative monitor results remain documented in their respective
verification pages. These are scoped checks, not full CPU or CDC proofs.

Artifact-only checks validate the saved six-frame logs and captures; they do not
rerun Doom or establish freshness. A recorded pip binary-only dry run resolved
all pins for Python 3.12 Linux x86-64. RTL changes require fresh verification.

`scripts/run.py` remains the main lint/unit/SoC runner. `scripts/verify_all.py`
delegates to it and adds seeded CPU cases, positive/negative monitor tests,
firmware builds, and exact diagnostic capture checks. It never downloads a WAD,
fetches Doom, runs Doom, or silently skips a missing dependency. All commands
below run from the repository root.

## Dependencies

CI uses Python 3.12 on Ubuntu 24.04 x86-64 and installs
`python -m pip install -r tools/requirements.txt`:

| Tool | Pinned Release | Purpose |
| --- | --- | --- |
| pyslang | 11.0.0 | Parse/elaborate all `rtl/**/*.sv` |
| Unicorn | 2.1.4 | Independent RV32IM arithmetic reference |
| z3-solver | 4.15.4.0 | Formal tooling dependency, not a CI proof claim |
| yowasp-yosys | 0.69.0.0.post1233 | Synthesis/formal tooling, not invoked by this smoke workflow |

The pyslang 11.0.0 PyPI release publishes a CPython 3.12 Linux x86-64 wheel
(`manylinux_2_27_x86_64.manylinux_2_28_x86_64`), so CI does not need to build it
from source. These are direct dependency pins, not a transitive hash-locked
environment. Native Icarus, Verilator, host GCC/G++, and Make are Ubuntu packages
(`iverilog verilator build-essential`); their package versions are not frozen.
Linux uses the standard native `verilator` executable. Windows setup is in
[tooling.md](tooling.md).

Firmware uses **xPack GNU RISC-V Embedded GCC 14.2.0-3**, which includes newlib
headers/libraries and RV32 multilibs. The runner accepts `--cross` or `CROSS`;
CI sets `CROSS=riscv-none-elf-`. Do not substitute Ubuntu's bare
`gcc-riscv64-unknown-elf` package without a working matching libc: even the
freestanding diagnostic includes `<stdlib.h>`, and Doom links `-lc -lm`.

Pinned Linux x64 archive:

- Release: <https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v14.2.0-3>
- Archive: `xpack-riscv-none-elf-gcc-14.2.0-3-linux-x64.tar.gz`
- SHA-256: `f574415b63f12b09bdd3475223ab492a465d23810646c90c13a4c3b676c83503`
- Digest source: the release's matching `.tar.gz.sha` asset, checked before extraction in CI.

The workflow extracts into the runner's user-local temporary directory, rejects
non-x86-64 hosts, adds its `bin` to `GITHUB_PATH`, and preprocesses `<stdlib.h>`
and `<stdio.h>` for RV32IM/ILP32. This direct verified release download avoids
an additional npm/xpm dependency; no unverified `xpm@0.20` version is assumed.

## Commands

```sh
python -m pip install -r tools/requirements.txt
python tools/verify_frame.py --self-test
python scripts/verify_all.py lint unit cpu monitors
python scripts/verify_all.py firmware --cross riscv-none-elf-
python scripts/verify_all.py soc --engine verilator
```

With all tools installed and `CROSS` set, `python scripts/verify_all.py` executes
all six tasks in that order. `--no-build` only reuses the SoC simulator executable;
it does not bypass lint, unit compilation, firmware, CPU cases, or monitor tests.
The `soc` task loads `firmware/build/diagnostic.mem`, requests one frame with a
100,000,000-cycle watchdog, and checks `build/soc/verify_diagnostic_1.ppm`.
It removes the previous capture at that exact path first, so a missing new
capture fails.

The main unit task is followed by an explicit independent arithmetic test, not
merely the unit runner's hand-derived expectations. The `cpu` extension compiles
`tb_cpu` and executes all available generator cases (`arithmetic`, `full`,
`misa`) with `(seed, max_delay)` pairs `(1, 17)`, `(0x1205abcd, 31)`, and
`(0xdeadbeef, 63)`. Traces and vectors live in `build/verification/<case>/`.
For arithmetic, generation and subsequent trace comparison both use pinned
Unicorn; the latter independently replays the image with `--unicorn`:

```sh
python tools/cpu_vectors.py --case arithmetic --out build/verification/arithmetic
vvp build/verification/tb_cpu.vvp +DIR=build/verification/arithmetic +TRACE=build/verification/arithmetic/manual.trace +SEED=1 +MAX_DELAY=17
python tools/check_trace.py build/verification/arithmetic/cpu.hex build/verification/arithmetic/manual.trace --unicorn
```

Run `python scripts/verify_all.py cpu` first to compile that bench. Unicorn is
an independent arithmetic reference only; `full` and `misa` use directed,
hand-derived expectations, not a trusted full ISA model. Monitor cases 1-8 must
exit nonzero **and** report their intended protocol/x0 assertion. A watchdog or
the bench's "was not rejected" fatal is not accepted as a passing negative test.
These monitor simulations are not formal proofs; see [../formal/README.md](../formal/README.md)
for the separate proof flow and its recorded results.

## CI Coverage

The workflow runs frame and Doom-log self-tests, lint, RTL units/software host
tests, the seeded CPU extension,
monitor rejection tests, and `make -C firmware all` (diagnostic and boot artifacts).
It then uses `software/fetch_doomgeneric.py` to fetch only the clean GPL source
commit pinned in `software/doomgeneric.lock`, builds Doom with newlib, and runs
`software/test_artifacts.py` against all three firmware outputs. The graphical
smoke is diagnostic firmware on Verilator, followed by exact pixel verification.
CI retains diagnostic captures/logs and extended CPU traces/vectors/coverage
even after failure. Linked firmware is not uploaded. CI does **not** download
Freedoom or commercial assets, run Doom, prove formal properties, or run synthesis.

## Frame Checks

```sh
python tools/verify_frame.py --diagnostic build/soc/verify_diagnostic_1.ppm
python tools/verify_frame.py --doom build/soc/doom_1.ppm build/soc/doom_2.ppm
python tools/verify_frame.py --diagnostic build/soc/verify_diagnostic_1.ppm --compare path/to/reference.ppm
python tools/verify_frame.py --doom build/soc/doom_1.ppm --expected path/to/hashes.json
```

Only raw P6, 640x480, maxval 255 captures with exactly 921,600 raster bytes are
accepted. Header comments and CRLF are supported without consuming raster bytes
that happen to be whitespace or `#`. Both modes enforce all-black rows 0-39 and
440-479. The diagnostic mode checks **every** displayed pixel, not just samples:
the 320x200 image is expanded 2x in each axis and centered vertically. For
`sx=x//2`, `sy=(y-40)//2`, its page-1 RGB is
`((sx*8//320)*255//7, (sy*8//200)*255//7, 255)`. This uses the firmware's integer
RGB332 expansion, not approximate bit replication; all 64 stripes must match.

Doom mode requires at least 16 distinct image colors and at least 1% nonblack
image pixels, checks every 2x2 scanout group, and accepts only exact integer
RGB332 palette expansion. It recovers all 64,000 row-major source indices and
computes 32-bit FNV-1a (basis 2166136261, prime 16777619, wrapping modulo 2^32).
This checksum can be compared with `DG_FRAME`, connecting software rendering to
hardware scanout. These structural checks alone do not prove correct gameplay,
assets, or freshness. `--compare` compares complete raw PPM bytes with one
reference per input. `--expected` accepts either the original flat basename/hash
object or the `hashes` object in `docs/doom-hashes.json`; missing entries fail:

```json
{
  "doom_1.ppm": "<64 lowercase hex digits from an independently accepted run>"
}
```

The JSON above is schema illustration. The accepted six-frame baseline is in
`docs/doom-hashes.json`. Successful checks print dimensions, image color/nonblack
counts, raw-file SHA-256, and recovered indexed FNV in Doom mode. SHA-256 includes
the header and must not be confused with a raster hash or the source-index FNV.

## Doom Evidence

The final baseline uses the engine commit in `software/doomgeneric.lock`, Freedoom
0.13.0 Phase 1 (28,795,076 WAD bytes), `CHIP_TIMEDEMO=1`, `CHIP_FRAME_LOG=8`, packed
four-pixel framebuffer word stores, and the corrected **post-load wipe callback**.
Unlike the superseded pre-create wipe-state assignment, this prevents startup
melt captures from being mistaken for game frames. `DG_CREATE_RETURN` is present,
and `DG_FRAME` records both the source-index FNV and guest `gametic`.
The raw WAD SHA-256 is
`7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d`.
The root license remains MIT for original contributions; the linked Doom engine
is GPL-2.0-or-later, and Freedoom data has its separate BSD-style license. No WAD
is committed, and these checks perform no downloads.

The tested firmware toolchain is **xPack GCC 15.2.0-1** (npm package
`@xpack-dev-tools/riscv-none-elf-gcc@15.2.0-1.1`), binutils 2.45 and newlib
4.5.0.20241231, targeting RV32IM/Zicsr/Zifencei ILP32. The simulator is Windows
Verilator 5.053 devel with the host compiler described in [tooling.md](tooling.md).
The current `firmware/build/doom.bin` raw SHA-256, independently computed when
recording this baseline, is
`5d44fbc6cf3697f9230acb8de02766317f160c13ed218d43b665249f7421a226`.
The ELF SHA-256 is
`bbe22468427025ce6a79f89eec5bf9b94c751a1d84d9bfc0993a7e8543a11e77`.
This identifies the present artifact, not an assurance that future builds or
CI's GCC 14.2.0-3 produce identical firmware. `check_doom.py` rejects a different
binary or ELF; review a toolchain/source change before establishing a new baseline.

| Frames | Guest Tics | Raw PPM SHA-256 | Recovered/UART FNV-1a | Colors | Nonblack VGA Pixels |
| --- | --- | --- | --- | --- | --- |
| 1-4 | 2-5 | `d4784d6ba6e6b7d497a2f2fa1960a579c17f3d079e38b8b65198d96d28cb0062` | `988d1a84` | 44 | 227,496 |
| 5 | 6 | `e60c7ad972ad71bab7d6fdc7b4fbc7c5b31ea4d0bda1c2fcfe8c1fd7778e58ed` | `1e82d262` | 44 | 227,496 |
| 6 | 7 | `6f66a1388cf502e376cb46f1c7bbb6548efc27b0a1f8eed9e567dd116291d04e` | `6118d8db` | 44 | 227,500 |

The manifest includes basename aliases `doom_1.ppm` through `doom_6.ppm` and
`doom_final_a_1.ppm` through `doom_final_b_6.ppm` for direct
`verify_frame.py --expected` use. The two runs have identical simulation metrics:

| Measurement | Value |
| --- | --- |
| Captured game frames | 6 |
| Final cycles | 626,567,682 |
| Retired instructions | 87,905,457 |
| External response bytes | 83,780,800 |
| Framebuffer write requests | 128,000 |
| IPC | 0.140297 |
| Simulated time at 50 MHz | 12.531354 seconds |
| Average external bandwidth, including startup | 6.685694 MB/s (decimal) |
| CPU / pixel clocks | 50 MHz / 25 MHz |
| Simulated memory MAX_DELAY | 3 |

Framebuffer requests are counted by the harness, not assumed to transfer four
valid pixel bytes each; byte-lane strobes matter. External response bytes are
four times the external response-beat count, not framebuffer payload bytes.

| Flip | Cycle | Cycles Since Previous Flip | External Response Beats |
| --- | --- | --- | --- |
| 1 | 427,515,162 | 427,515,162 | 17,971,454 |
| 2 | 467,808,002 | 40,292,840 | 18,574,557 |
| 3 | 507,288,002 | 39,480,000 | 19,154,071 |
| 4 | 546,768,002 | 39,480,000 | 19,743,761 |
| 5 | 586,248,002 | 39,480,000 | 20,321,480 |
| 6 | 625,728,002 | 39,480,000 | 20,907,966 |

The final capture follows the sixth flip; stopping at a flip is not equivalent
to capturing its full VGA raster. Startup dominates the first interval. The
saved Verilator wall times are 749.417 and 748.260 seconds; these are host-specific
measurements, not FPGA performance predictions.

The final six-frame runs require 626,567,682 cycles; reproduction needs an
explicit larger watchdog. The normal diagnostic smoke's 100,000,000-cycle
default is not sufficient for this Doom segment. Both runs completed the
requested six-frame capture test, **not** the full 7,117-tic demo.

## Superseded Evidence

Earlier `doom_verified_a/b` three-capture runs included timer-driven startup
wipes because setting wipe state before level loading was ineffective. They
lacked consecutive-game-tic evidence and are superseded by the post-load
callback and final six-frame runs. Their hashes must not be reused for the
current firmware. An earlier 500,000,000-cycle attempt failed its watchdog;
the later three-capture completion did not establish the current gameplay result.

## Doom Checks

```sh
python tools/verify_frame.py --self-test
python scripts/check_doom.py --self-test
python scripts/check_doom.py
python scripts/check_doom.py build/soc/doom_final_a build/soc/doom_final_b
python scripts/check_doom.py --functional build/emulator/final_strict_a/result.json
python tools/verify_frame.py --doom build/soc/doom_final_a_1.ppm build/soc/doom_final_a_2.ppm build/soc/doom_final_a_3.ppm build/soc/doom_final_a_4.ppm build/soc/doom_final_a_5.ppm build/soc/doom_final_a_6.ppm --expected docs/doom-hashes.json
```

`check_doom.py` reads `<prefix>.log` and `<prefix>_1.ppm` through
`<prefix>_N.ppm` for each of two distinct prefixes, where N is the manifest's
`summary.frames` (currently six). It checks both current BIN/ELF digests
(`--firmware` and `--elf` can name saved artifacts), initialization/Freedoom/WAD
and `DG_CREATE_RETURN` markers, complete PASS summary, ordered flip/capture
events, baseline timing/retirement/bandwidth counters, consecutive `DG_FRAME`
numbers and guest tics, raw frame hashes, recovered FNV, eventual image change,
and byte identity across both runs. Custom prefix names are mapped to canonical
`doom_N.ppm` manifest entries by frame number. It prints measured IPC, simulated
time, external bandwidth, and per-flip counters. A PASS summary never overrides
an assertion, fatal, error, failure or watchdog marker. The parser also rejects
`FATAL TRAP` in reconstructed UART text, including when harness output splits
it into `FA` and `TAL TRAP`; the log-parser self-tests cover this case.

UART text can be interrupted by harness messages. The log parser strips only
`SOC_*` and `PASS tb_soc` lines. Initialization text uses normalized whitespace;
DG markers are parsed in a whitespace-free stream to rejoin identifiers and hex
values, including `fnv` / `1a=`, `cy` / `cles=`, and interrupted `tic` digits.
Repeated early images do not waive consecutive tic checks. It does not
discard arbitrary error text. The upstream "couldn't open demo1.lmp" message
is expected while the engine falls back to the WAD's embedded DEMO1; the
subsequent Freedoom/game/graphics and frame markers are required.

These are artifact-only commands: they never execute a simulator, fetch assets,
or rebuild Doom. They establish agreement with the measured six-frame
baseline, but they do not prove that any given set of logs was produced freshly.
The exact commands that produced these two runs are in `docs/simulation.md`.
The workflow's intended runtime scope is the diagnostic graphical smoke, not
Doom runtime acceptance. The historical Linux pass does not establish a fresh
CI pass for the current release.

## Functional Comparison

`--functional build/emulator/final_strict_a/result.json` validates a saved successful
Unicorn 2.1.4 functional result's BIN/ELF/WAD identity, six frame numbers,
FNV values and guest tics. It then reads each referenced 64,000-byte indexed
`frame_N.raw` and compares **every byte** with indices recovered from both RTL
scanout sets. This comparison has passed for all six final frames, not merely
their checksums. Truncated or changed raw data is rejected.

Both `final_strict_a` and `final_strict_b` native executions report matched
references and exact RTL indexed-byte comparisons. The older
`build/emulator/final/result.json` recorded `referencePending` against a
superseded manifest; its historical metadata is not the status of these later
strict runs. Artifact-only checks do not rewrite result metadata.
Functional timer ticks are instruction-model measurements, not RTL timing or
external-memory bandwidth. Shared engine/firmware/assets mean this is an
independent execution/scanout cross-check, not an independent Doom engine oracle.
