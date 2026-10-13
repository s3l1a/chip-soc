# Functional Doom Emulator

`tools/functional_soc.py` runs the existing RV32 Doom firmware using the native
**Unicorn 2.1.4** CPU, independently of RTL and Verilator. It does not execute
Doom as a host-native engine, substitute frame images, patch firmware, or
interpret guest opcodes in Python. Python supplies memory, MMIO, timer bookkeeping,
and capture.
Existing project helpers supply validated ELF32 RISC-V PT_LOAD loading
(`tools/elf_to_mem.py`, including zero-filled BSS) and optional P6 capture parsing
(`tools/verify_frame.py`). Neither supplies CPU execution or reference pixels to
the guest.

## Run

From the repository root, with the existing firmware and assets already built:

```text
python -m pip install --user unicorn==2.1.4
python tools/functional_soc.py
python tools/functional_soc.py --output build/emulator/repeat
python tools/functional_soc.py --frames 16 --output build/emulator/long
python tools/functional_soc.py --compare-rtl --output build/emulator/rtl_comparison
python tools/functional_soc.py --frames 6 --compare-rtl --rtl-prefix build/soc/doom_final_a --timeout 180 --output build/emulator/final_strict_a
```

The runner checks both the Python package and native core release. It uses
`UC_ARCH_RISCV` and `UC_MODE_RISCV32`. A native smoke test executes writes to
`mie`, `mstatus`, and `mtvec`, followed by `fence.i` and `mret`; it verifies the
written CSR values before returning to the target PC. This passed with the
installed Windows/Python 3.14 wheel. There is no privileged-instruction fallback
or manual CSR execution. Unsupported native execution is reported as a blocker.
This small probe is not privileged-architecture conformance testing.

Defaults are `firmware/build/doom.elf`, `firmware/build/wad.bin`, and
`external/assets/freedoom1.wad`. The extracted Freedoom 0.13.0 asset is a file,
not a directory named `freedoom-0.13.0`; provenance is recorded alongside it in
`external/assets/freedoom-0.13.0.provenance.json`. The packed asset must have the
64-byte `CHWAD001` header, matching size/offset/SHA-256, and a payload identical
to the external WAD. Nothing is downloaded or rebuilt by the runner.

CLI overrides: `--elf`, `--assets`, `--wad`, `--output`, `--frames` (default 3,
range 1 to 100), `--reference` (default `docs/doom-hashes.json`),
`--max-instructions` (default 500,000,000 approximate instructions), and
`--timeout` (default 120 host seconds). `--compare-rtl` requires an applicable
reference and exact hashes in addition to functional execution success.
`--rtl-prefix PREFIX` additionally requires exact indexed-byte comparison against
`PREFIX_1.ppm` through `PREFIX_N.ppm` and requires `--compare-rtl`.
Warnings, UART output, and blocker messages go to stdout.
ELFs advertising compressed instructions are rejected because the timer's block
instruction estimate assumes four-byte instructions.

## Hardware Model

| Region | Functional behavior |
| --- | --- |
| Reset ROM at `0x00000000` | Read/execute mapping; words `800002b7`, `0000100f`, `00028067`: jump through `t0` to `0x80000000`, with `fence.i`. Execution starts at PC zero, not directly at the ELF entry. |
| RAM at `0x80000000` | 16 MiB native Unicorn memory; load the ELF's identity-mapped PT_LOAD segments. Entry must be `0x80000000`. |
| Assets at `0x60000000` | 64 MiB read-only guest mapping; load the complete `wad.bin` header plus payload. Guest stores are rejected by Unicorn memory protection. This is a Unicorn memory mapping, not a host file-backed `mmap`. |
| Framebuffer at `0x20000000` | Two read/write 65,536-byte pages; capture only the first 64,000 bytes of each requested page. |
| UART at `0x10000000` | Status bit 0 is false, RX empty, TX space bit 4 set. TX at offset 4 immediately emits its low byte and records it; no input or serialization delay. |
| Timer at `0x10001000` | Split 64-bit time at offsets 0/4 and compare at 8/12, with read/write state. No interrupt delivery. |
| GPIO at `0x10002000` | Input is zero; output at offset 4 is stored/read back. |
| Video at `0x10003000` | Enable at offset 0; flip at 4 immediately updates current page/status bit 2. Pending/vblank bits stay zero. Palette index/data at 8/12 retain 256 RGB entries. |
| Reserved at `0x10004000` | Reads return zero. |

The custom MMIO mapping uses `Uc.mmio_map`. Only aligned 32-bit MMIO accesses
used by this firmware are supported; unsupported accesses stop with a blocker.
An empty UART RX read returns zero. Invalid or disabled video flips are rejected.
Palette entries are masked to 24 bits. No physical raster, scaling, clock-domain
crossings, bus contention, cache model, or video flip latency is implemented.

The timer advances by `basic_block_size / 4` on every native block entry, treating
one estimated instruction as one 50 MHz timer tick. This assumes the firmware's
uncompressed RV32 instructions. A block is charged before its instructions
execute, so a stopped/faulting block can include an unexecuted tail. These counts
are **not exact retirements or RTL cycles**. Wall-clock runtime does not drive
guest time. Firmware CSR execution remains native; no cycle CSR is intercepted
or synchronized with this MMIO timer.

## Captures And Results

The runner stops on the requested flip count and writes under ignored
`build/emulator/` by default:

- `frame_N.raw`: 320x200 row-major RGB332/palette-index bytes for each flip.
- `frame_N.ppm`: 320x200 RGB captures using the guest palette
  at each flip, not the RTL's scaled 640x480 physical output.
- `console.txt`: actual emitted UART bytes; the final flip stops execution before
  that frame's later `DG_FRAME` UART log.
- `result.json`: observed and applicable expected FNV-1a hashes, guest `gametic`,
  distinct pixel-value counts, pages, approximate counts, timer ticks, input
  SHA-256s, host elapsed time, final PC, reference status, and success/failure.

FNV-1a starts at 2166136261 and applies `(hash XOR pixel) * 16777619` modulo
2^32 to the actual framebuffer bytes. `gametic` is resolved from the loaded ELF32
symbol/string tables and read directly from guest RAM at each flip; no dependency
on `nm` or the later UART log is required. Missing or malformed symbol metadata
is rejected. The runner also hashes the allocated file-backed ELF image,
excluding BSS, to identify the firmware binary represented by that ELF.

Functional success requires the requested number of native-executed flips,
nonuniform images, no execution/MMIO/watchdog failure, and strictly advancing
guest tics between flips when more than one frame is requested. Nonuniformity is
only a basic blank-image check, not proof of rendering correctness. Equal frame
hashes are allowed: stationary scenes can be drawn on successive game tics.
A one-frame run cannot establish tic progression and records that explicitly.
Repeatability is checked externally by comparing separate capture runs.

Reference handling reads schema 1 of `docs/doom-hashes.json`; no hashes are
hard-coded or substituted into guest output. The manifest's firmware SHA-256
must match the loaded ELF (for `.elf`) or its allocated binary image (for `.bin`).
An additional `firmware.elf_sha256`, when present, must match the loaded ELF too.
WAD size and a WAD SHA-256, when present in the manifest, must also match.
The `fnv1a` array must supply the entire requested prefix. Missing, malformed,
stale, or too-short references are reported as `referencePending`, with no
per-frame expected hash. Applicable sequences are compared exactly and reported
as `matched` or `mismatch`. A manifest `gametics` array, when present, must cover
the requested prefix and match the guest tic sequence exactly. Only indexed
images and these tics are compared, not CPU timing or full physical scanout.

Without `--compare-rtl`, reference state does not change execution success or
exit status. With it, exit zero additionally requires `matched`; a pending or
mismatching reference returns one while retaining `functional_success: true`
if execution itself succeeded. This avoids claiming equivalence against another
firmware build without concealing a real hash mismatch against an applicable
baseline. `success` represents the requested mode's overall outcome.
The result records the SHA-256 of the exact manifest read for the run.

With `--rtl-prefix`, comparison happens only after native execution stops. Each
RTL PPM must have a SHA-256 entry matching its basename in the applicable
manifest. The P6 parser requires 640x480 RGB8 input; the decoder checks black
40-row top/bottom borders, validates every active 2x2 group, and inverts the
firmware's fixed 256-entry RGB332 palette to recover 320x200 indexed bytes.
It compares all 64,000 recovered bytes directly with the native raw capture,
not just their hash. Missing/invalid captures or any difference fail the requested
comparison without relabeling successful CPU execution as a CPU failure.
`rtl_pixel_comparison` summarizes the result; each frame records the PPM digest,
decoded/native indexed digests, byte count, and equality result. No RTL data is
written to guest memory or used to seed execution.

Captures and results are retained after execution failure. Existing output files
are overwritten by a run; separate directories preserve comparisons. The runner
does not wait for a concurrent build, so callers should ensure the build has
finished; input digests identify the exact bytes that were executed.
Prerequisite, input-file and native-probe failures also replace `result.json`
with failure metadata (`success: false`, `functional_success: false`, and a
`notStarted` reference). Old captures alone cannot establish success for that
attempt.

## Final Verification

**Two fresh six-frame strict runs passed with exit status zero on 2026-10-13.**
They use the current CSR/video RTL and compare against both saved RTL capture sets.
The final firmware includes packed framebuffer stores, UART tic logging, and
post-load timedemo wipe suppression. Both native runs matched the final
`docs/doom-hashes.json` firmware/ELF/WAD digests, all six FNV-1a hashes, and guest
tics 2 through 7. The corresponding decoded RTL captures were also byte-identical
to the native raw images: 64,000 indexed bytes per frame, 384,000 per run.

```text
python tools/functional_soc.py --frames 6 --compare-rtl --rtl-prefix build/soc/doom_final_a --timeout 180 --output build/emulator/final_strict_a
python tools/functional_soc.py --frames 6 --compare-rtl --rtl-prefix build/soc/doom_final_b --timeout 180 --output build/emulator/final_strict_b
```

Results and captures are in those two output directories. Both report
`success: true`, `functional_success: true`, `reference.status: matched`, and
`rtl_pixel_comparison.status: matched`. Execution times were 11.012 and 10.954
seconds, each with 85,864,093 approximate instructions. Byte comparison is
post-execution and excluded from these execution times. All six native images
have 44 distinct indexed values; guest `gametic` is at `8007d47c`.

| Frame | Guest Tic | Approximate Instructions | Native/RTL FNV-1a | Decoded Bytes |
| --- | ---: | ---: | --- | --- |
| 1 | 2 | 54,072,337 | `988d1a84` | Exact match |
| 2 | 3 | 60,414,377 | `988d1a84` | Exact match |
| 3 | 4 | 66,820,345 | `988d1a84` | Exact match |
| 4 | 5 | 73,187,471 | `988d1a84` | Exact match |
| 5 | 6 | 79,510,629 | `1e82d262` | Exact match |
| 6 | 7 | 85,864,093 | `6118d8db` | Exact match |

```text
doom.elf SHA-256  bbe22468427025ce6a79f89eec5bf9b94c751a1d84d9bfc0993a7e8543a11e77
binary SHA-256    5d44fbc6cf3697f9230acb8de02766317f160c13ed218d43b665249f7421a226
freedoom1.wad    7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d
wad.bin SHA-256  95a4df4c6a1cb9194b31f34daf6c0da9df4b16657dd8d8a4ee10c20937e231da
manifest SHA-256 d12c3f1263897c37e82088dc94941011c37370b589a6f44a3bb4ee5c5a0d4153
```

The first four images are the stationary initial scene, not duplicate-frame
fabrication: guest tics advance, and the image first changes at frame 5/tic 6.
`fc /b` additionally found no differences between the two native runs' changed
frame 5 and frame 6 raw files. The decoder's in-memory checks round-tripped all
256 palette indices and rejected corrupt borders, inconsistent scaling groups,
invalid palette colors, and truncated rasters. These are decoder checks, not CPU
conformance tests.

This establishes exact six-frame indexed-image and tic agreement for this
firmware/WAD and the two named RTL capture sets. It does not establish equal
cycle counts, interrupts, bus behavior, complete scanout timing, full demo
playback, or general RTL/CPU equivalence. The previous wipe-related mismatch and
stale-reference condition are superseded, not open blockers.

## Earlier Verification

Intermediate firmware produced timer-dependent startup wipes and a genuine
three-frame mismatch. Level loading overwrote the pre-create wipe-state setting;
moving suppression to `DG_SetWindowTitle` after loading fixed that behavior.
Later intermediate runs executed successfully but returned `referencePending`
against the old manifest; strict comparison correctly failed until the firmware
and reference identities matched. These observations are superseded by the two
final strict runs above, not relabeled as passing comparisons.

A separate 16-frame intermediate run advanced tics 2 through 17, but it was not
the final firmware baseline and is not extended RTL acceptance evidence. The
recorded watchdog, one-frame and invalid-frame-count checks exercised rejection
and reporting, not CPU conformance or full demo completion.
