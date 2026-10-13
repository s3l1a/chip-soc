# Third-Party Notices

The root MIT license covers original project contributions, not upstream engine
source, third-party libraries, or game data. No WAD is committed or bundled with
the source repository. The optional `software/fetch_freedoom.py` download verifies
the official archive and preserves the extracted license and credits under
ignored `external/assets/`.

## DoomGeneric

- Repository: <https://github.com/ozkl/doomgeneric>
- Pinned revision: `e257a09527062bfb986b6e5e0780839b6cbd5b71`.
- Checkout: `software/external/doomgeneric/`, ignored by `software/.gitignore`.
- Verified at that revision: root `LICENSE` contains GNU GPL version 2, June 1991;
  `doomgeneric/w_file.c` and `doomgeneric/doomkeys.h` contain GPL version 2 or
  later grants, including id Software and Simon Howard copyright notices.
- Use the engine under GPL-2.0-or-later (GPL v2 is an available choice). Preserve
  every upstream copyright/license notice and the complete upstream `LICENSE`.
  The SHA pin is a source identity, not a verified signed authorship claim.

The original bindings and build tooling here are MIT-licensed separately. A
distributed executable linking Doom engine code is a GPL-covered combined work,
not an MIT-only binary. Include the complete corresponding engine/glue/library
source, notices, modifications and build scripts, or otherwise meet GPL v2's
source-distribution requirements. Ignoring an external checkout is a repository
size decision, not a waiver of obligations when distributing binaries.

## Toolchain Libraries

The diagnostic uses compiler runtime helpers (`libgcc` with the GNU build).
The optional Doom build additionally uses newlib `libc` and `libm`. These are
external toolchain dependencies, not vendored source. Check the exact toolchain
distribution's library notices and GCC Runtime Library Exception before
redistribution. Newlib comprises files under multiple permissive licenses;
do not describe it as having a single project MIT license.

Validation used user-local xPack RISC-V GCC 15.2.0-1 (npm package version
15.2.0-1.1), GNU binutils 2.45 and newlib 4.5.0.20241231, as well as a temporary
Zig 0.14.1 package (LLVM/Clang and compiler-rt). None are bundled with the project.
The GNU diagnostic, boot and Doom/newlib builds link successfully; this is not
evidence of execution. Toolchain license texts are in the installed package's
`.content/distro-info/licenses/`, including `newlib-4.5.0.20241231/` and
`gcc-15.2.0/`. Preserve those notices when distributing linked library code.

## Freedoom Data (Not Included)

Freedoom v0.13.0's `COPYING.adoc` was verified from
<https://github.com/freedoom/freedoom/blob/v0.13.0/COPYING.adoc>:
copyright 2001-2024 Contributors to the Freedoom project, with a three-condition
BSD-style redistribution grant (retain notices, reproduce notices in binary
distributions, no endorsement). Preserve its `COPYING` and `CREDITS` if you
redistribute data. See `docs/software.md` for authoritative archive checksums,
the verified extracted-WAD digest, and packaging instructions. The default
simulated asset backend is 64 MiB; the legacy RAM backend is 8 MiB. Neither
backend implies a physical storage controller or permission to redistribute
unrelated game data.
