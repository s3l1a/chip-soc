# Bare-Metal Software

This is diagnostic firmware plus a **six-frame simulation-validated DoomGeneric
integration**. Two fresh RTL runs and an independent functional run rendered
Freedoom Phase 1 DEMO1 at game tics 2 through 7. This is not a complete demo or a
working Boolean board implementation. The root license
is MIT for original contributions; `THIRD_PARTY.md` documents the GPL engine
and external libraries/data separately.
The current-RTL two-run baseline is recorded in [Verification](verification.md).

## Memory and Boot

| Region | Start | Size / Meaning |
| --- | --- | --- |
| Reset ROM | `0x00000000` | 16 KiB (`0x00000000..0x00003fff`), simulation-only jump stub |
| Application RAM | `0x80000000` | 8 MiB, code/data/BSS/heap/stack |
| Simulated read-only assets | `0x60000000` | 64 MiB (`0x60000000..0x63ffffff`), default WAD backend |
| Legacy RAM WAD reservation | `0x80800000` | upper 8 MiB of the 16 MiB RAM window; requires a matching preload frontend |
| Framebuffer page 0 | `0x20000000` | 64,000 valid bytes, 320x200 indexed |
| Framebuffer page 1 | `0x20010000` | same; page stride 65,536 bytes |

`linker/app.ld` still reserves the upper 8 MiB of external RAM for legacy storage;
the application remains limited to the lower 8 MiB. The default WAD now lives in
a separate **SIMULATED READ-ONLY ASSET** window, not in RAM and not in physical
flash hardware. A matching simulation frontend must decode it and reject writes;
no FPGA flash controller or usable board storage is implied. The application
stack is 64 KiB at `0x807f0000..0x807fffff`, initial `sp=0x80800000`; the heap
ends at the stack bottom. Link-time assertions reject overlap. No MMU or MPU
protects these boundaries at runtime. Data has identity VMA/LMA in RAM, but
startup still copies the declared data range, then clears BSS. `gp` is initialized
inside `.option norelax`; builds also disable relaxation and compressed code.
Startup disables interrupts, sets direct `mtvec`, calls `main`, and spins if it
returns. Fatal trap assembly saves x0-x31 and `mcause/mepc/mtval/mstatus` into a
144-byte, 16-byte-aligned stack frame before calling UART diagnostics. Traps do
not return or recover; a corrupt/unmapped stack or broken UART can prevent reports.

`firmware/boot.S` emits `lui t0,0x80000; fence.i; jalr zero,0(t0)` at reset 0.
Expected words are `800002b7`, `0000100f`, `00028067`. This **does not load RAM**.
The simulator must preload the application and storage before reset is released.
No flash, SD, UART loader, RAM controller or real board boot path is supplied.
The RTL ROM must use this stub or equivalent encodings; compiling it alone does
not replace a hard-coded RTL ROM.

## MMIO Contract

All registers are 32-bit accesses. Framebuffer pixels are indexed bytes; the
diagnostic writes byte pixels, while Doom packs four pixels into each aligned
32-bit framebuffer store. The full register and subword-access contract is in
[Memory Map](memory-map.md).

| Device | Base | Offsets |
| --- | --- | --- |
| UART | `0x10000000` | status `0`: bit0 TX busy, bit1 RX ready; TX `4`; RX `8` pops |
| Timer | `0x10001000` | 64-bit cycle count low `0`, high `4`; compare low `8`, high `0xc` |
| GPIO | `0x10002000` | input `0`, output `4` |
| Video | `0x10003000` | status `0`, page-flip `4`, palette index `8`, palette data `0xc` |

Software assumes timer frequency 50 MHz, UART 115200 8N1, video status bit0 is
enable, bit1 is flip-pending, bit2 is displayed page and bit3 is vertical blank.
Writing status bit0 enables the display. A page request must use a full-word
value of 0 or 1; larger values fault, even if their low bit names a valid page.
Palette data is `0x00RRGGBB` (RGB888). Framebuffer and MMIO are uncached. The CPU
already completes transactions in order, so `fence` is a no-op, not cache
maintenance. `FENCE.I` invalidates only the I-cache; no software D-cache
invalidation operation exists. After CDC synchronization, flips complete during
vertical blank, not necessarily at its first pixel. The draw routine waits for
pending to clear before reusing the old front page.
The hi/lo/hi timer read handles rollover. Compare updates write high `UINT32_MAX`
first to avoid a transient early match. Diagnostics poll time; no ISR is enabled.

The diagnostic validates initialized data, zero BSS and a small allocation,
prints UART status, initializes the fixed palette, fills both 320x200 pages,
requests page 1, validates optional memory-mapped WAD bounds and emits one-second timer/GPIO
heartbeats. `minilib.c` supplies byte-safe memory/string primitives and a bounded,
16-byte-aligned monotonic arena with overflow-checked `calloc`; `free` does not
reclaim. It is **not** the Doom allocator. Doom uses newlib's `malloc/free` and a
bounded `_sbrk` backend. Neither allocator detects a runtime stack overflow.

## Reproducible GNU Build

Dependencies: Python 3.9+, Git, GNU Make, a POSIX shell with `mkdir/rm`, and GNU
RISC-V bare-metal GCC/binutils supporting `rv32im_zicsr_zifencei` and ILP32. For
Doom, that same toolchain must include matching RV32 soft-float ILP32 **newlib**
headers, `libc`, `libm`, `libgcc` and POSIX-compatible declarations (`unistd.h`,
`sys/stat.h`, `strings.h`). A Linux-only cross compiler or `picolibc` is not a
drop-in validated replacement. A `riscv64-unknown-elf-` multilib toolchain is fine
only if `gcc -print-multi-lib` includes compatible RV32IM/ILP32 libraries. No SDL,
X11, audio library or host filesystem is linked by the bare-metal recipe.

Use MSYS2/WSL or another POSIX make environment on Windows:

```sh
make -C firmware CROSS=riscv32-unknown-elf- PYTHON=python3 all
make -C firmware CROSS=riscv64-unknown-elf- PYTHON=python3 all
python3 software/fetch_doomgeneric.py
make -C firmware CROSS=riscv32-unknown-elf- PYTHON=python3 doom
make -C firmware test
```

The existing build wrapper also locates the installed user-local GNU toolchain
on Windows without installing or downloading anything:

```sh
python3 software/fetch_doomgeneric.py
python3 scripts/build_firmware.py all doom test
python3 software/test_artifacts.py
```

The toolchain actually tested here is user-local xPack GCC 15.2.0-1, binutils
2.45, newlib 4.5.0.20241231 and Windows Build Tools GNU Make 4.4.1. These optional
installs require Node/npm and do not modify the repository or permanent PATH:

```text
npm exec --yes --package xpm -- xpm install --global @xpack-dev-tools/riscv-none-elf-gcc@15.2.0-1.1
npm exec --yes --package xpm -- xpm install --global @xpack-dev-tools/windows-build-tools@4.4.1-3.1
```

On this Windows user account the GCC prefix is
`%APPDATA%/xPacks/@xpack-dev-tools/riscv-none-elf-gcc/15.2.0-1.1/.content/bin/riscv-none-elf-`.
Make and its `sh/mkdir/rm` tools are under
`%APPDATA%/xPacks/@xpack-dev-tools/windows-build-tools/4.4.1-3.1/.content/bin/`.
Put both bin directories on a session-local PATH, or give make the full `CROSS`
prefix and `SHELL` path and include the build-tools directory in make's exported
`PATH` variable. Use `CROSS=riscv-none-elf- PYTHON=python` with those tools.
`-march=rv32im_zicsr_zifencei -mabi=ilp32` selects their RV32IM/ILP32 multilib.

The first two `make ... all` commands are alternatives, not two required
toolchains. Each diagnostic, boot and Doom target emits `.elf`, word-indexed `.mem`,
raw `.bin` (via `objcopy -O binary`) and `.dis` disassembly (via `objdump -d`) under
ignored `firmware/build/`; application targets also emit linker maps. Raw binaries
start at the image's lowest load address and contain initialized load bytes, not
the zero-filled BSS or the entire reserved RAM/ROM capacity. The boot stub remains
12 bytes despite its 16 KiB ROM window. Boot `.mem` conversion uses `--base 0
--size 0x4000`; unmentioned ROM words must be initialized by the simulator.
With the xPack tools on PATH, inspect instructions and load ranges using:

```sh
riscv-none-elf-objdump -dr firmware/build/diagnostic.elf
riscv-none-elf-readelf -lA firmware/build/diagnostic.elf
```

Substitute your toolchain's prefix when using another compiler. No compressed,
atomic or floating-point instructions should appear.

`tools/elf_to_mem.py` has no pyelftools dependency. It validates ELF32 LE RISC-V
executables, bounds-checks identity-mapped PT_LOAD segments, rejects overlapping
segments, validates the entry point and zero-initializes each segment's BSS.
`@` addresses index **32-bit little-endian words relative to `--base`**, not bytes
or absolute CPU addresses. Unmentioned memory must be zeroed by the simulator.
Application images start `@00000000` in a 16 MiB RAM word array based at
`0x80000000`; boot images use a separate ROM word array based at 0. Default flash
asset images start at `@00000000` in a **separate** 64 MiB word array based at
`0x60000000`. Only `--backend ram` starts assets at `@00200000` in the application
RAM array. Do not load either word-indexed image into a byte array.

## Pinned Doom Engine

Repository: <https://github.com/ozkl/doomgeneric>

Exact revision: `e257a09527062bfb986b6e5e0780839b6cbd5b71`, recorded in
`software/doomgeneric.lock`. Fetch keeps the original source/notices intact in
ignored `software/external/doomgeneric`; it verifies a clean checkout, exact
HEAD, GPL v2 text and a version-2-or-later source notice. Existing modified or
wrong-revision checkouts are rejected, never reset. On ownership-less Windows
filesystems, only this checkout is trusted via command-local `safe.directory`,
not a permanent/global Git configuration change. Do not change the lock without
reviewing the new source/license/API. This engine fetch never downloads WAD data;
the optional Freedoom fetch described below is a separate command.

The Makefile uses the pinned upstream's engine source set without its X11
backend, with `DOOMGENERIC_RESX=320`, `DOOMGENERIC_RESY=200`, RGB32 output and the
original `w_file_stdc.c` through newlib stdio. Bindings implement `DG_Init`,
`DG_DrawFrame`, `DG_SleepMs`, `DG_GetKey`, `DG_SetWindowTitle` and `DG_GetTicks`;
the actual pinned API calls `DG_GetTicksMs`, which is also supplied. The pixel
packing matches the upstream RGB32 `0x00RRGGBB` offsets. Index conversion is
deterministic truncation: `(r & 0xe0) | ((g >> 3) & 0x1c) | (b >> 6)`.
Palette expansion is integer `r3*255/7`, `g3*255/7`, `b2*255/3`. This loses color
precision, not an attempt to reproduce Doom's original palette/dithering.

UART inputs `w/s/a/d`, space, `e`, Enter and Escape produce press/release pairs.
GPIO bits 0..7 provide held up/down/left/right/fire/use/enter/escape keys. Board
polarity, input synchronization and debouncing must be implemented externally.
The program passes `-iwad doom1.wad -mb 4 -nosound -nomusic` and, by default,
`-timedemo demo1` (`CHIP_TIMEDEMO=1`). The exposed filename
is an alias for the one user-supplied WAD, not a claim about its game/license.
Upstream game-mode detection still reads the WAD contents.

`make -C firmware ... doom CHIP_TIMEDEMO=1 CHIP_FRAME_LOG=8` builds the simulation
test image; `CHIP_TIMEDEMO=0` restores the interactive title loop. The bindings
are rebuilt when invoking the target so changes to these arguments take effect.
In timedemo mode, `DG_SetWindowTitle` sets `wipegamestate = gamestate` after the
upstream `TryRunTics` level load and before the first draw. This callback
suppresses the timer-paced startup melt without modifying upstream engine files.
The pinned create call itself performs a
tick/draw before returning. The reference manifest matches the current firmware
digest for the recorded baseline.

The first eight draws log `DG_FRAME frame=XXXXXXXX fnv1a=XXXXXXXX
cycles=XXXXXXXXXXXXXXXX tic=XXXXXXXX`: eight-digit hexadecimal frame count,
FNV-1a hash of the converted row-major 64,000 RGB332 bytes and Doom game tic, plus
the sixteen-digit hardware cycle counter sampled before UART logging.
Hashing uses offset basis 2166136261 and
prime 16777619, wrapping at 32 bits. It excludes page padding and ignores elapsed
time. These are **software source-buffer checksums**, not proof of a correct
hardware scanout. The harness must independently observe flips/pixels/framebuffer
contents. `DG_CREATE_RETURN` appears after the first draw has returned; a frame
marker can therefore precede it. Logging consumes UART time, so a harness that
stops immediately on a flip can truncate its corresponding marker. A six-frame
test is not completion of the full timedemo, and no software frame-limit shortcut
or fabricated completion marker is supplied.

`software/newlib_syscalls.c` offers four read-only file handles to that WAD,
bounds-checked reads/seeks, stat and UART stdin/stdout/stderr. Missing config
files return `ENOENT`; writes, savegames, directories and screenshots fail
read-only. No filesystem, audio, network, SD or dynamic loader is implemented.
Other upstream/newlib OS dependencies may require additional syscalls on a
different toolchain. The pinned GNU/newlib Doom build compiles and links with no
unresolved symbols here. The current image reached six RTL scanout captures in
two fresh runs and six matching independent functional-model flips, with game
tics advancing from 2 to 7. Complete gameplay, the full timedemo, interactive
input coverage and hardware RAM/performance remain unproven.
Upstream source produces compiler warnings (including format
type, signedness, fallthrough and dangling-pointer diagnostics); the original
checkout is preserved rather than silently patched or declared warning-free.
The six-frame legal IWAD boot/render smoke test has passed in simulation; input
coverage and on-target heap/stack profiling are still required for a board port.

## User-Supplied Assets

Do not download proprietary Doom data from unofficial sources. Supply a legally
obtained WAD, with your independently verified **exact extracted-WAD SHA-256
and byte count**. The packer makes no network requests and rejects mismatch,
out-of-bounds lump tables and anything larger than `67,108,800` WAD bytes for the
default `--backend flash`. Explicit `--backend ram` retains the old 8 MiB backend
and its `8,388,544`-byte WAD limit.

```sh
python3 tools/assets.py /path/to/user.wad firmware/build/wad.bin --sha256 YOUR_64_HEX_DIGEST --size EXACT_WAD_BYTES --backend flash
python3 tools/assets.py /path/to/user.wad firmware/build/wad.mem --sha256 YOUR_64_HEX_DIGEST --size EXACT_WAD_BYTES --format mem --backend flash
```

To use a small legacy RAM WAD, pack with `--backend ram` and rebuild firmware with
`CPPFLAGS="-DWAD_BASE=0x80800000u -DWAD_CAPACITY=0x00800000u"` after cleaning its
objects. Without overrides, `platform.h` uses base `0x60000000`, capacity 64 MiB.
The stock SoC runner loads `--wad` into the separate asset array, not application
RAM. The legacy backend additionally requires a frontend that loads its
word-indexed image into application RAM at `0x80800000`; `--wad` alone does not
do this. Its `@00200000` offset is relative to the RAM array's `0x80000000` base.
The existing `storage_open_ram` parser handles any contiguous read-only mapped
bytes; its name does not imply that the new asset frontend is physical RAM.

The 64-byte little-endian header at `0x60000000` (or legacy `0x80800000`) is:

| Offset | Bytes | Value |
| --- | --- | --- |
| 0 | 8 | ASCII `CHWAD001` |
| 8 | 4 | WAD byte length (header excluded) |
| 12 | 4 | header length, exactly 64 |
| 16 | 32 | raw SHA-256 of WAD payload |
| 48 | 16 | reserved, all zero |
| 64 | length | original unmodified WAD bytes |

Host packaging verifies SHA-256; the firmware parser validates magic, sizes,
reserved fields and WAD directory/lump bounds but **does not recompute SHA-256**.
The embedded digest is provenance metadata, not runtime authentication. Both
IWAD and PWAD containers parse, but a standalone Doom boot requires an IWAD.

### Freedoom Provenance

The authoritative download page is <https://freedoom.github.io/download.html>.
For version 0.13.0, use release metadata at
<https://github.com/freedoom/freedoom/releases/tag/v0.13.0> and license text at
<https://github.com/freedoom/freedoom/blob/v0.13.0/COPYING.adoc> (BSD-style three
conditions; preserve COPYING/CREDITS). The official archive was downloaded here,
its full SHA-256/size verified, and **only** Phase 1 WAD
plus `COPYING.txt`, `CREDITS.txt` and `CREDITS-MUSIC.txt` extracted to ignored
`external/assets/`. No proprietary Doom data or Phase 2 WAD was extracted.

The official signed checksum file is
<https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0-CHECKSUM>.
It publishes these **ZIP archive**, not WAD, SHA-256 values:

```text
freedoom-0.13.0.zip  3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59
freedm-0.13.0.zip    b420f13508ef745d7b38e83d15e55e0fc0b09d9a503c96741cddd9773d43f7c9
```

Verify your archive against that official file (and its signature using an
independently authenticated publisher key), then extract locally and compute
the selected WAD's digest/size yourself, e.g. `sha256sum` and `wc -c`, or
PowerShell `Get-FileHash -Algorithm SHA256` and `(Get-Item ...).Length`. Never
pass the ZIP digest as the WAD digest. The packer never truncates or removes lumps.
These WADs do not fit the legacy RAM reservation; the new simulated asset window
is deliberately separate from the existing 16 MiB external RAM.

Download the verified official archive and package the default simulated asset backend:

```sh
python3 software/fetch_freedoom.py
python3 tools/assets.py external/assets/freedoom1.wad firmware/build/wad.mem --sha256 7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d --size 28795076 --backend flash --format mem
python3 tools/assets.py external/assets/freedoom1.wad firmware/build/wad.bin --sha256 7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d --size 28795076 --backend flash --format bin
```

Run the firmware build first to create `firmware/build/`. Verilator consumes the
separate word-indexed `wad.mem`; the functional emulator consumes `wad.bin` and
checks its header/payload against the extracted WAD and digest. The fetch emits
the ignored provenance JSON manifest and preserves license/credits; no WAD or
generated asset image should be committed.

The verified ZIP is 24,143,781 bytes with the archive digest above. The extracted
`freedoom1.wad` is **28,795,076 bytes**, SHA-256
`7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d`.
Its packed header plus payload is 28,795,140 bytes. The provenance JSON in
`external/assets/freedoom-0.13.0.provenance.json` records source URL, digests,
notice files and demo headers. The official checksum was compared, but its PGP
signature was **not** authenticated against an independently trusted signer key.

`DEMO1` is present and is a version-109 (Doom v1.9), single-player demo with
skill byte 2, episode 1, map 6 and players `[1,0,0,0]`. It is 28,482 bytes,
SHA-256 `1b2be1878d9eabd866dc2766a63254dcb33020532a8d1dee82de7a01d777e27c`.
The standard 13-byte header and end marker leave 7,117 four-byte tics. This makes
`-timedemo demo1` reproducible. The first six rendered game frames are now
validated in simulation, but a full 7,117-tic run has not been completed.

Official ZIP central-directory metadata reports these exact extracted sizes:

| Version 0.13.0 WAD | Uncompressed Bytes |
| --- | --- |
| `freedoom1.wad` | 28,795,076 |
| `freedoom2.wad` | 28,787,748 |
| `freedm.wad` | 22,218,796 |

The smallest is FreeDM at 22,218,796 bytes (deathmatch data, not the single-player
Phases). The smallest Phase WAD is `freedoom2.wad` at 28,787,748 bytes. Every one
exceeds both the legacy 8,388,544-byte WAD limit and the current 16 MiB external
RAM. Repartitioning RAM alone cannot accommodate them. They fit the separate
64 MiB simulated read-only asset frontend; real board storage remains unresolved.
`python3 software/inspect_freedoom.py` reproduces this metadata inspection using
HTTP Range requests for the end record and directory only. It refuses servers
that ignore Range. No WAD payload is read, and partial directory inspection is
not a full-archive checksum or signature verification.

## Validation Scope

Host tests are `python3 software/test_tools.py` and a native compiler invocation
of `firmware/storage.c` with `software/test_storage.c` and `-Ifirmware`.
They test ELF conversion/rejection and WAD packaging/storage bounds with
synthetic fixtures. All 25 Python host tests passed, including malformed/empty
ELF segments, functional-run failure metadata, 16 KiB ROM bounds, separate flash
offsets, explicit RAM offsets and capacity compatibility. The native C storage
test also has a recorded pass; neither suite executes the RTL Doom workload.
After `make all doom`, run
`python3 software/test_artifacts.py` to compare each `.bin` against initialized
ELF load bytes, each `.mem` against the load/BSS image, and check entry-point
disassembly plus the exact 12-byte boot encoding.
The native C storage test also accepts a packed `.bin` path; running it with
`firmware/build/wad.bin` validated the complete actual Freedoom payload and its
directory/lump bounds, not merely a synthetic fixture. This is a parser test,
not engine execution.
The recorded GNU build produced diagnostic, boot and Doom ELF/mem/bin/dis
outputs and application linker maps. `readelf` reports
RV32I/M/Zicsr/Zifencei (with Zmmul implied by M), soft-float ILP32 and 16-byte
stack alignment; `nm -u` finds no undefined Doom symbols. Boot disassembly
matches the three words documented above. Linker segments separate RX code and
RW data, but there is no hardware access protection implied by those ELF flags.

| GNU Build | Text | Data | BSS |
| --- | --- | --- | --- |
| Diagnostic | 3,960 bytes | 4 bytes | 8 bytes |
| Doom engine + timedemo/log glue + newlib | 449,584 bytes | 61,328 bytes | 240,236 bytes |

These sizes exclude dynamic Doom allocations, reserved stack, framebuffers and
WAD. The recorded six-frame baseline combines callback-based wipe suppression,
packed framebuffer stores and `tic=` logging, built with xPack GCC 15.2.0 and
`CHIP_TIMEDEMO=1 CHIP_FRAME_LOG=8`. The build and artifact checks passed;
`doom.bin` is 510,912 bytes. Baseline identities are:

```text
doom.bin SHA-256  5d44fbc6cf3697f9230acb8de02766317f160c13ed218d43b665249f7421a226
doom.elf SHA-256  bbe22468427025ce6a79f89eec5bf9b94c751a1d84d9bfc0993a7e8543a11e77
```

Two recorded Verilator runs, `build/soc/doom_final_a.log` and
`build/soc/doom_final_b.log`, each completed six scanout captures at game tics
2 through 7. Corresponding captures are byte-identical across runs. The first
four images repeat while tics advance; frames five and six change. The exact
hashes, per-flip counters and reproduction commands are in
[Verification](verification.md#doom-evidence) and [Simulation](simulation.md).

The final strict functional results at
`build/emulator/final_strict_a/result.json` and `final_strict_b/result.json`
report execution success, matched firmware/asset references, and exact indexed
byte agreement with their respective RTL captures. See [Emulator](emulator.md)
for commands and scope. The older `build/emulator/final/result.json` recorded
`referencePending` before the manifest was finalized; that historical metadata
is not the status of the later strict runs.

Each RTL run reports 626,567,682 cycles, 87,905,457 retired instructions and
83,780,800 external bus-beat-equivalent bytes. Packed framebuffer stores account
for 128,000 requests: 32,000 to clear both pages and 96,000 to draw six frames.
These are request counts, not byte-pixel counts. Earlier wipe-era captures are
superseded, as described in [Verification](verification.md#superseded-evidence).

The functional timer charges estimated block instructions, including block
tails; these are **not RTL cycles or exact retired instructions**. Unicorn has
no UART serialization, frame-boundary delay, interrupts or physical scanout.
The RTL and functional observations therefore establish six-frame simulated
boot/render/tic progression, not a complete 7,117-tic timedemo, all-level or
interactive-input coverage, a physical board runtime, a Vivado run or hardware
timing/CDC closure. No claim about a usable bitstream follows from these results.

QEMU's standard RISC-V `virt` machine has different UART/timer interfaces and no
matching indexed-video registers. These images need a matching machine model,
such as the supplied functional emulator, rather than a stock `virt` invocation.
