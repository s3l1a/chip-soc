# Portable Windows RTL Toolchain

Verified on Windows x64 on 2026-10-11. All downloads/extractions are user-local;
no installer, registry change, persistent PATH change, WSL, or administrator
access is required. RTL/testbench files are not modified by this setup.

## Pinned Downloads

| Component | Release / archive | SHA-256 |
| --- | --- | --- |
| OSS CAD Suite | `2026-10-11` / `oss-cad-suite-windows-x64-20261011.tgz` | `947643577937c89226b0bc02d2ac9643f0906c4ad4e1da2da46d49d88196fb0b` |
| WinLibs GNU C++ | `15.2.0posix-14.0.0-ucrt-r7` / `winlibs-x86_64-posix-seh-gcc-15.2.0-mingw-w64ucrt-14.0.0-r7.zip` | `cb2fbad6162540cdf5e1facdce08d4dac359e8cf64f7f696a99274291763b815` |

Both digests were checked against GitHub release asset metadata and against the
downloaded bytes before extraction. Release pages:

- <https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-10-11>
- <https://github.com/brechtsanders/winlibs_mingw/releases/tag/15.2.0posix-14.0.0-ucrt-r7>

Example installation destinations for the commands below:

- Verilator suite: `%TEMP%\chip-tools\oss-cad-suite`
- GNU C++ and Make: `%TEMP%\chip-tools\winlibs-gcc15\mingw64`
- Git shell/utilities: `C:\Program Files\Git\usr\bin` (adjust for your Git installation)
- Optional separate Icarus installation: `%TEMP%\chip-tools\iverilog-v14`

These are suggested destinations, not a claim that the tools are already
installed. The examples require an existing Git installation; Icarus is needed
for the unit runner and must also be available on PATH or at its portable path.

These temporary-directory tools can be deleted by Windows cleanup. Use a
user-owned, space-free persistent directory instead when reproducing the setup
for longer-term use. OSS CAD Suite does not include a host C++ compiler or Make;
the RISC-V cross compiler is not a substitute for the Windows host compiler.

## Download And Extract

The following PowerShell commands download and verify the pinned archives.
Choose a directory without spaces. Extraction overwrites files at the indicated
destinations, so use empty destinations for a fresh install.

```powershell
$base = Join-Path $env:TEMP 'chip-tools'
if (!(Test-Path -LiteralPath $env:TEMP -PathType Container)) { throw 'Missing temporary directory' }
New-Item -ItemType Directory -Force -Path $base | Out-Null

$cadArchive = Join-Path $base 'oss-cad-suite-windows-x64-20261011.tgz'
curl.exe --fail --location --retry 3 --output $cadArchive 'https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-10-11/oss-cad-suite-windows-x64-20261011.tgz'
if ($LASTEXITCODE -ne 0) { throw 'OSS CAD Suite download failed' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $cadArchive).Hash.ToLowerInvariant() -ne '947643577937c89226b0bc02d2ac9643f0906c4ad4e1da2da46d49d88196fb0b') { throw 'OSS CAD Suite SHA-256 mismatch' }
tar.exe -xzf $cadArchive -C $base
if ($LASTEXITCODE -ne 0) { throw 'OSS CAD Suite extraction failed' }

$gccArchive = Join-Path $base 'winlibs-x86_64-posix-seh-gcc-15.2.0-mingw-w64ucrt-14.0.0-r7.zip'
curl.exe --fail --location --retry 3 --output $gccArchive 'https://github.com/brechtsanders/winlibs_mingw/releases/download/15.2.0posix-14.0.0-ucrt-r7/winlibs-x86_64-posix-seh-gcc-15.2.0-mingw-w64ucrt-14.0.0-r7.zip'
if ($LASTEXITCODE -ne 0) { throw 'WinLibs download failed' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $gccArchive).Hash.ToLowerInvariant() -ne 'cb2fbad6162540cdf5e1facdce08d4dac359e8cf64f7f696a99274291763b815') { throw 'WinLibs SHA-256 mismatch' }
$gccDest = Join-Path $base 'winlibs-gcc15'
New-Item -ItemType Directory -Force -Path $gccDest | Out-Null
tar.exe -xf $gccArchive -C $gccDest
if ($LASTEXITCODE -ne 0) { throw 'WinLibs extraction failed' }
```

## Process-Local Environment

Run this in each PowerShell process that builds or runs a simulation:

```powershell
$base = Join-Path $env:TEMP 'chip-tools'
$cad = Join-Path $base 'oss-cad-suite'
$gcc = Join-Path $base 'winlibs-gcc15\mingw64\bin'
$gitTools = 'C:\Program Files\Git\usr\bin'
$env:PATH = "$gcc;$cad\bin;$cad\lib;$gitTools;" + $env:PATH
$env:VERILATOR_ROOT = ($cad + '\share\verilator').Replace('\', '/')
$env:MAKE = 'mingw32-make'
$verilator = Join-Path $cad 'bin\verilator_bin.exe'

& $verilator --version
g++.exe --version
mingw32-make.exe --version
```

Verified versions:

```text
Verilator 5.053 devel rev v5.052-362-ge9f8cb2d9 (mod)
g++.exe (MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r7) 15.2.0
GNU Make 4.4.1
```

Use `verilator_bin.exe` directly. The suite's `bin/verilator` is a Perl script,
not a Windows executable; the tested Git Perl lacked `Pod::Usage`, preventing
that wrapper from running. Setting `VERILATOR_ROOT` lets the native executable
find its runtime headers and generated makefile support. No Perl installation is
needed for the tested binary/timing/assertion flow.

Keep WinLibs before OSS CAD Suite and Git in PATH so the matching GNU compiler,
binutils, and runtime DLLs are selected. Git supplies `sh`, `uname`, `cat`,
`xargs`, and other POSIX utilities used by Verilator's generated Make rules.
`python3` comes from the suite's `lib` directory.

## Toolchain Smoke Test

From the repository root, after the process-local setup above, build and run the
tracked argument-parsing regression. This exercises the host C++ build, Verilator
assertions, and string, integer and 64-bit command-line arguments without
requiring firmware or external smoke source files:

```powershell
if (!(Test-Path -LiteralPath 'sim/unit/tb_plusargs.sv')) { throw 'Run from the repository root' }
New-Item -ItemType Directory -Force -Path 'build/plusargs' | Out-Null
$out = (Resolve-Path -LiteralPath 'build/plusargs').Path.Replace('\', '/')
& $verilator --binary --timing --assert --top-module tb_plusargs --Mdir $out -j 2 -CFLAGS '-std=c++20' -MAKEFLAGS 'SHELL=sh PYTHON3=python3' 'sim/unit/tb_plusargs.sv'
if ($LASTEXITCODE -ne 0) { throw 'Verilator build failed' }
& "$out/Vtb_plusargs.exe" '+PREFIX=regression' '+FRAMES=1' '+CYCLES=12345678901'
if ($LASTEXITCODE -ne 0) { throw 'Argument regression failed' }
```

Expected output includes `PASS tb_plusargs`. The packaged Verilator runtime can
emit nonfatal `STDOUT_FILENO`/`STDERR_FILENO` redefinition warnings. A passing
toolchain smoke is not a SoC result; use `python scripts/run.py soc` with built
diagnostic firmware for the integration test described in [simulation.md](simulation.md).

## Rejected Compiler

WinLibs `16.2.0posix-14.0.0-ucrt-r2` was also downloaded and tested. Its simple
C++ smoke passed, but linking the generated Verilator runtime failed with
undefined references to the `std::__cxx11::basic_string` move constructor, even
with static C++ runtime linking and explicit C++20. Do not select that compiler
for this flow; use the pinned GCC 15.2.0 archive above.

Rejected archive: `winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r2.zip`.
Verified SHA-256: `d5dbafc4a170e762ca6143151ec918fb9e2c72736fb14cd704abebc6bdd5276a`.
