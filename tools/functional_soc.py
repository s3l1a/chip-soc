#!/usr/bin/env python3
"""Run the existing Doom ELF on pinned Unicorn, independently of RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import time

from elf_to_mem import elf_image

ROOT = Path(__file__).resolve().parents[1]
RAM_BASE, RAM_SIZE = 0x80000000, 16 * 1024 * 1024
ASSET_BASE, ASSET_SIZE = 0x60000000, 64 * 1024 * 1024
FB_BASE, FB_STRIDE = 0x20000000, 65536
PIXELS = 320 * 200


def elf_metadata(elf, image):
    """Find gametic and hash the allocated file-backed image (objcopy binary)."""
    shoff = struct.unpack_from("<I", elf, 32)[0]
    shsize, shnum = struct.unpack_from("<HH", elf, 46)
    if shsize != 40 or not shnum or shoff + shnum * shsize > len(elf):
        raise ValueError("expected ELF32 section headers for gametic metadata")
    sections = [struct.unpack_from("<10I", elf, shoff + i * shsize)
                for i in range(shnum)]
    binary_end = 0
    gametic = None
    for section in sections:
        _, kind, flags, address, offset, size, link, _, _, entry_size = section
        if flags & 2 and kind != 8 and size:
            if not RAM_BASE <= address < address + size <= RAM_BASE + len(image):
                raise ValueError("allocated ELF section outside loaded RAM image")
            if (offset + size > len(elf) or
                    image[address - RAM_BASE:address - RAM_BASE + size] != elf[offset:offset + size]):
                raise ValueError("allocated ELF section differs from PT_LOAD image")
            binary_end = max(binary_end, address + size - RAM_BASE)
        if kind != 2:
            continue
        if entry_size != 16 or size % 16 or offset + size > len(elf) or link >= shnum:
            raise ValueError("invalid ELF symbol table")
        strings = sections[link]
        if strings[1] != 3 or strings[4] + strings[5] > len(elf):
            raise ValueError("invalid ELF symbol string table")
        names = elf[strings[4]:strings[4] + strings[5]]
        for pos in range(offset, offset + size, 16):
            name, value, symbol_size, info, other, index = struct.unpack_from("<IIIBBH", elf, pos)
            end = names.find(b"\0", name)
            if name >= len(names) or end < 0:
                raise ValueError("invalid ELF symbol name")
            if names[name:end] == b"gametic" and index:
                if (symbol_size != 4 or (info & 15) != 1 or value % 4 or
                        not RAM_BASE <= value <= RAM_BASE + len(image) - 4):
                    raise ValueError("gametic must be a loaded, aligned 32-bit object")
                if gametic is not None and gametic != value:
                    raise ValueError("conflicting gametic symbols")
                gametic = value
    if gametic is None or not binary_end:
        raise ValueError("ELF must contain a defined gametic symbol and allocated image")
    return gametic, hashlib.sha256(image[:binary_end]).hexdigest()


def rtl_indexed_pixels(data):
    """Recover 320x200 indices from the fixed-palette 640x480 RTL scanout."""
    from verify_frame import parse_ppm
    raster = parse_ppm(data)
    row_bytes = 640 * 3
    if any(raster[:40 * row_bytes]) or any(raster[440 * row_bytes:]):
        raise ValueError("RTL scanout has nonblack letterbox borders")
    inverse = {bytes((((i >> 5) & 7) * 255 // 7,
                      ((i >> 2) & 7) * 255 // 7, (i & 3) * 255 // 3)): i
               for i in range(256)}
    indexed = bytearray()
    for y in range(40, 440, 2):
        for x in range(0, 640, 2):
            offset = y * row_bytes + x * 3
            rgb = raster[offset:offset + 3]
            if any(raster[other:other + 3] != rgb for other in
                   (offset + 3, offset + row_bytes, offset + row_bytes + 3)):
                raise ValueError(f"inconsistent RTL 2x2 group at ({x},{y})")
            if rgb not in inverse:
                raise ValueError(f"non-RGB332 RTL palette color at ({x},{y})")
            indexed.append(inverse[rgb])
    return bytes(indexed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=Path, default=ROOT / "firmware/build/doom.elf")
    parser.add_argument("--assets", type=Path, default=ROOT / "firmware/build/wad.bin")
    parser.add_argument("--wad", type=Path, default=ROOT / "external/assets/freedoom1.wad")
    parser.add_argument("--output", type=Path, default=ROOT / "build/emulator")
    parser.add_argument("--frames", type=int, default=3, help="capture 1 to 100 flips")
    parser.add_argument("--reference", type=Path, default=ROOT / "docs/doom-hashes.json")
    parser.add_argument("--compare-rtl", action="store_true",
                        help="require a firmware-matched reference sequence and exact hashes")
    parser.add_argument("--rtl-prefix", type=Path,
                        help="also compare decoded PREFIX_N.ppm bytes; requires --compare-rtl")
    parser.add_argument("--max-instructions", type=int, default=500_000_000,
                        help="watchdog in approximate block instructions, not retirements")
    parser.add_argument("--timeout", type=float, default=120,
                        help="host execution watchdog in seconds")
    args = parser.parse_args()
    result_path = args.output / "result.json"
    try:
        args.output.mkdir(parents=True, exist_ok=True)
        # Preserve captures, but never let an old success describe this invocation.
        result_path.unlink(missing_ok=True)
    except OSError as error:
        print(f"BLOCKER: cannot invalidate functional result {result_path}: {error}")
        return 1
    try:
        import unicorn as uc
        from unicorn import riscv_const as rv
        if uc.__version__ != "2.1.4":
            raise ValueError(f"requires unicorn==2.1.4, found {uc.__version__}")
        if uc.uc_version()[2] >> 8 != 0x020104:
            raise ValueError("native Unicorn core is not release 2.1.4")
        if args.max_instructions <= 0 or args.timeout <= 0:
            raise ValueError("watchdog limits must be positive")
        if not 1 <= args.frames <= 100:
            raise ValueError("--frames must be between 1 and 100")
        if args.rtl_prefix and not args.compare_rtl:
            raise ValueError("--rtl-prefix requires --compare-rtl")

        # Native machine-mode smoke test. No CSR or opcode emulation fallback.
        probe = uc.Uc(uc.UC_ARCH_RISCV, uc.UC_MODE_RISCV32)
        probe.mem_map(0, 4096)
        probe.mem_write(0, struct.pack("<5I", 0x30401073, 0x30001073,
                                      0x30529073, 0x0000100F, 0x30200073))
        probe.reg_write(rv.UC_RISCV_REG_T0, 0x100)
        probe.reg_write(rv.UC_RISCV_REG_MEPC, 0x100)
        probe.emu_start(0, 16)
        if (probe.reg_read(rv.UC_RISCV_REG_MTVEC) != 0x100 or
                probe.reg_read(rv.UC_RISCV_REG_MIE) != 0 or
                probe.reg_read(rv.UC_RISCV_REG_MSTATUS) != 0):
            raise ValueError("native machine CSR/fence.i probe failed")
        probe.emu_start(16, 0x100, count=1)
        if probe.reg_read(rv.UC_RISCV_REG_PC) != 0x100:
            raise ValueError("native machine CSR/fence.i/mret probe failed")
        print("Native RV32 machine CSR/fence.i/mret probe passed (Unicorn 2.1.4)")

        elf = args.elf.read_bytes()
        image = elf_image(elf, RAM_BASE, RAM_SIZE)
        if struct.unpack_from("<I", elf, 24)[0] != RAM_BASE:
            raise ValueError("reset ROM requires ELF entry 0x80000000")
        if struct.unpack_from("<I", elf, 36)[0] & 1:
            raise ValueError("block instruction estimate requires an ELF without RVC")
        gametic_address, binary_sha256 = elf_metadata(elf, image)
        elf_sha256 = hashlib.sha256(elf).hexdigest()
        packed = args.assets.read_bytes()
        wad = args.wad.read_bytes()
        if len(packed) < 64 or len(packed) > ASSET_SIZE:
            raise ValueError("asset image must contain a header and fit in 64 MiB")
        magic, length, offset, digest = struct.unpack_from("<8sII32s", packed)
        if (magic != b"CHWAD001" or offset != 64 or length != len(wad) or
                packed[64:] != wad or hashlib.sha256(wad).digest() != digest):
            raise ValueError("wad.bin header/payload does not match the external WAD")
        expected = []
        expected_tics = []
        reference = {"path": str(args.reference), "status": "referencePending", "reason": None}
        try:
            manifest_data = args.reference.read_bytes()
            reference["sha256"] = hashlib.sha256(manifest_data).hexdigest()
            manifest = json.loads(manifest_data)
            if not isinstance(manifest, dict) or manifest.get("schema") != 1:
                raise ValueError("expected reference manifest schema 1")
            firmware = manifest["firmware"]
            if not isinstance(firmware, dict):
                raise ValueError("invalid manifest firmware metadata")
            suffix = Path(firmware["path"]).suffix
            current_digest = {".bin": binary_sha256, ".elf": elf_sha256}.get(suffix)
            if current_digest is None or firmware["sha256"] != current_digest:
                reference["reason"] = "manifest firmware digest does not match loaded ELF/image"
            elif firmware.get("elf_sha256", elf_sha256) != elf_sha256:
                reference["reason"] = "manifest ELF digest does not match loaded ELF"
            elif manifest.get("wad_bytes") != len(wad):
                reference["reason"] = "manifest WAD size does not match loaded assets"
            elif manifest.get("wad_sha256", digest.hex()) != digest.hex():
                reference["reason"] = "manifest WAD digest does not match loaded assets"
            elif not isinstance(manifest["fnv1a"], list):
                raise ValueError("manifest FNV-1a sequence must be a list")
            elif len(manifest["fnv1a"]) < args.frames:
                reference["reason"] = "manifest has no complete sequence for requested frame count"
            else:
                expected = manifest["fnv1a"][:args.frames]
                if not all(isinstance(h, str) and len(h) == 8 and
                           all(c in "0123456789abcdef" for c in h) for h in expected):
                    raise ValueError("invalid manifest FNV-1a sequence")
                if "gametics" in manifest:
                    tics = manifest["gametics"]
                    if (not isinstance(tics, list) or len(tics) < args.frames or
                            not all(type(t) is int and 0 <= t < 2**32 for t in tics[:args.frames])):
                        raise ValueError("invalid/incomplete manifest gametic sequence")
                    expected_tics = tics[:args.frames]
                reference["status"] = "ready"
        except (OSError, ValueError, KeyError, TypeError) as error:
            expected = []
            expected_tics = []
            reference["reason"] = f"reference unavailable/invalid: {error}"
        if reference["status"] == "referencePending":
            print(f"WARNING: referencePending: {reference['reason']}")
        print(f"ELF SHA-256 {elf_sha256}; binary SHA-256 {binary_sha256}")
        cpu = uc.Uc(uc.UC_ARCH_RISCV, uc.UC_MODE_RISCV32)
        cpu.mem_map(0, 4096, uc.UC_PROT_READ | uc.UC_PROT_EXEC)
        cpu.mem_write(0, struct.pack("<3I", 0x800002B7, 0x0000100F, 0x00028067))
        cpu.mem_map(RAM_BASE, RAM_SIZE)
        cpu.mem_write(RAM_BASE, bytes(image))
        cpu.mem_map(ASSET_BASE, ASSET_SIZE, uc.UC_PROT_READ)
        cpu.mem_write(ASSET_BASE, packed)
        cpu.mem_map(FB_BASE, 2 * FB_STRIDE, uc.UC_PROT_READ | uc.UC_PROT_WRITE)
        state = {"instructions": 0, "ticks": 0, "compare": 2**64 - 1,
                 "gpio": 0, "enabled": 0, "page": 0, "index": 0,
                 "failure": None}
        palette = [0] * 256
        frames = []
        console = bytearray()
        start = time.perf_counter()

        def fail(message):
            state["failure"] = message
            cpu.emu_stop()

        def block(emu, address, size, user):
            # Blocks are charged on entry, including the not-yet-executed tail.
            # Firmware is RV32 without compressed instructions.
            count = size // 4
            state["instructions"] += count
            state["ticks"] = (state["ticks"] + count) & (2**64 - 1)
            if state["instructions"] > args.max_instructions:
                fail("approximate instruction watchdog exceeded")

        def read(emu, offset, size, user):
            if size != 4 or offset % 4:
                fail(f"unsupported MMIO read offset={offset:#x} size={size}")
                return 0
            values = {0: 0x10, 8: 0, 12: 0,
                      0x1000: state["ticks"] & 0xFFFFFFFF,
                      0x1004: state["ticks"] >> 32,
                      0x1008: state["compare"] & 0xFFFFFFFF,
                      0x100C: state["compare"] >> 32,
                      0x2000: 0, 0x2004: state["gpio"],
                      0x3000: state["enabled"] | (state["page"] << 2),
                      0x3004: state["page"], 0x3008: state["index"],
                      0x300C: palette[state["index"]], 0x4000: 0}
            if offset not in values:
                fail(f"unsupported MMIO read offset={offset:#x}")
            return values.get(offset, 0)

        def write(emu, offset, size, value, user):
            if size != 4 or offset % 4:
                fail(f"unsupported MMIO write offset={offset:#x} size={size}")
                return
            if offset == 4:
                console.append(value & 255)
                sys.stdout.write(chr(value & 255))
                if (value & 255) == 10:
                    sys.stdout.flush()
                if b"FATAL TRAP" in console[-32:]:
                    fail("firmware reported FATAL TRAP")
            elif offset == 12:
                pass
            elif offset in (0x1000, 0x1004, 0x1008, 0x100C):
                key = "ticks" if offset < 0x1008 else "compare"
                shift = 32 if offset & 4 else 0
                mask = 0xFFFFFFFF << shift
                state[key] = (state[key] & ~mask) | ((value & 0xFFFFFFFF) << shift)
            elif offset == 0x2004:
                state["gpio"] = value
            elif offset == 0x3000:
                state["enabled"] = value & 1
            elif offset == 0x3008:
                state["index"] = value & 255
            elif offset == 0x300C:
                palette[state["index"]] = value & 0xFFFFFF
            elif offset == 0x3004:
                if value not in (0, 1) or not state["enabled"]:
                    fail("invalid or disabled video flip")
                    return
                state["page"] = value
                pixels = bytes(emu.mem_read(FB_BASE + value * FB_STRIDE, PIXELS))
                fnv = 2166136261
                for pixel in pixels:
                    fnv = ((fnv ^ pixel) * 16777619) & 0xFFFFFFFF
                number = len(frames) + 1
                name = f"frame_{number}.raw"
                args.output.joinpath(name).write_bytes(pixels)
                rgb = b"".join(palette[p].to_bytes(3, "big") for p in pixels)
                args.output.joinpath(f"frame_{number}.ppm").write_bytes(
                    b"P6\n320 200\n255\n" + rgb)
                frames.append({"frame": number, "page": value, "raw": name,
                               "fnv1a": f"{fnv:08x}",
                               "expected": expected[number - 1] if expected else None,
                                "gametic": struct.unpack("<I", emu.mem_read(gametic_address, 4))[0],
                                "expected_gametic": expected_tics[number - 1] if expected_tics else None,
                               "unique_pixel_values": len(set(pixels)),
                               "approx_instructions": state["instructions"],
                               "timer_ticks": state["ticks"]})
                print(f"\nFUNCTIONAL_FLIP frame={number} fnv1a={fnv:08x} "
                      f"tic={frames[-1]['gametic']}", flush=True)
                if number == args.frames:
                    emu.emu_stop()
            else:
                fail(f"unsupported MMIO write offset={offset:#x}")

        cpu.mmio_map(0x10000000, 0x5000, read, None, write, None)
        cpu.hook_add(uc.UC_HOOK_BLOCK, block)
        print("WARNING: functional only; timer = block instruction estimate at 50 MHz; "
              "no cycle accuracy, interrupts, UART serialization, or physical scanout.")
        try:
            cpu.emu_start(0, 0xFFFFFFFF, timeout=int(args.timeout * 1_000_000))
        except uc.UcError as error:
            state["failure"] = f"Unicorn execution blocker: {error}"
        elapsed = time.perf_counter() - start
        progressing = len(frames) > 1 and all(b["gametic"] > a["gametic"]
                                             for a, b in zip(frames, frames[1:]))
        nonuniform = bool(frames) and all(f["unique_pixel_values"] > 1 for f in frames)
        if state["failure"] is None:
            if len(frames) != args.frames:
                state["failure"] = "execution stopped before requested flips (host timeout or end)"
            elif not nonuniform:
                state["failure"] = "captured a uniform/blank image"
            elif args.frames > 1 and not progressing:
                state["failure"] = "guest gametic did not advance between every captured flip"
        functional_success = state["failure"] is None
        if expected:
            reference["status"] = ("matched" if len(frames) == args.frames and
                                   [f["fnv1a"] for f in frames] == expected and
                                   (not expected_tics or [f["gametic"] for f in frames] == expected_tics)
                                   else "mismatch")
            if reference["status"] == "mismatch":
                reference["reason"] = "captured hashes/tics do not match the complete reference sequence"
        pixel_comparison = {"status": "notRequested", "failure": None}
        if args.rtl_prefix:
            pixel_comparison["status"] = "matched"
            try:
                if not expected or len(frames) != args.frames:
                    raise ValueError("decoded byte comparison requires an applicable complete reference/run")
                for frame in frames:
                    path = Path(f"{args.rtl_prefix}_{frame['frame']}.ppm")
                    ppm = path.read_bytes()
                    ppm_digest = hashlib.sha256(ppm).hexdigest()
                    if manifest.get("hashes", {}).get(path.name) != ppm_digest:
                        raise ValueError(f"{path}: PPM SHA-256 missing from or different to manifest")
                    decoded = rtl_indexed_pixels(ppm)
                    raw = args.output.joinpath(frame["raw"]).read_bytes()
                    if len(raw) != PIXELS:
                        raise ValueError("native raw capture must contain exactly 64,000 bytes")
                    frame["rtl_pixels"] = {"path": str(path), "ppm_sha256": ppm_digest,
                                           "indexed_sha256": hashlib.sha256(decoded).hexdigest(),
                                           "raw_sha256": hashlib.sha256(raw).hexdigest(),
                                           "bytes": len(decoded), "matched": decoded == raw}
                    if decoded != raw:
                        first = next(i for i, (a, b) in enumerate(zip(decoded, raw)) if a != b)
                        raise ValueError(f"{path}: decoded indexed bytes differ at pixel {first}")
                    print(f"PASS RTL_BYTES frame={frame['frame']} bytes={len(decoded)}", flush=True)
            except (OSError, ValueError, AttributeError) as error:
                pixel_comparison["status"] = "mismatch"
                pixel_comparison["failure"] = str(error)
        success = (functional_success and (not args.compare_rtl or reference["status"] == "matched")
                   and pixel_comparison["status"] != "mismatch")
        failure = state["failure"]
        if not success and failure is None:
            failure = (pixel_comparison["failure"] or
                       f"required RTL comparison: {reference['status']}: {reference['reason']}")
        result = {"success": success, "functional_success": functional_success,
                  "failure": failure, "unicorn": uc.__version__, "reference": reference,
                  "rtl_pixel_comparison": pixel_comparison,
                  "requested_frames": args.frames, "gametic_address": f"{gametic_address:08x}",
                  "gametic_progressing": progressing, "images_nonuniform": nonuniform,
                  "elf_sha256": elf_sha256, "binary_sha256": binary_sha256,
                  "wad_sha256": digest.hex(),
                  "asset_sha256": hashlib.sha256(packed).hexdigest(), "frames": frames,
                  "approx_instructions": state["instructions"], "elapsed_seconds": elapsed,
                  "pc": f"{cpu.reg_read(rv.UC_RISCV_REG_PC):08x}"}
        args.output.joinpath("console.txt").write_bytes(console)
        result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="ascii")
        print(f"\n{'PASS' if functional_success else 'FAIL'} functional Doom: {len(frames)} flips, "
              f"{state['instructions']} approximate instructions, {elapsed:.3f}s")
        print(f"RTL reference: {reference['status']}")
        if args.rtl_prefix:
            print(f"RTL indexed bytes: {pixel_comparison['status']}")
        if not success:
            label = "RTL COMPARISON FAILED" if functional_success else "BLOCKER"
            print(f"{label}: {failure}; PC={result['pc']}")
        return 0 if success else 1
    except (ImportError, OSError, ValueError, struct.error) as error:
        failure = f"functional_soc: {error}"
    except uc.UcError as error:
        failure = f"native Unicorn setup/privileged execution: {error}"
    print(f"BLOCKER: {failure}")
    result = {"success": False, "functional_success": False, "failure": failure,
              "unicorn": None, "reference": {"path": str(args.reference), "status": "notStarted", "reason": failure},
              "rtl_pixel_comparison": {"status": "notRequested", "failure": None},
              "requested_frames": args.frames, "gametic_address": None,
              "gametic_progressing": False, "images_nonuniform": False,
              "elf_sha256": None, "binary_sha256": None, "wad_sha256": None,
              "asset_sha256": None, "frames": [], "approx_instructions": 0,
              "elapsed_seconds": None, "pc": None}
    try:
        result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="ascii")
    except OSError as error:
        print(f"BLOCKER: cannot write failed functional result {result_path}: {error}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
