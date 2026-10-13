#!/usr/bin/env python3
"""Check generated firmware artifacts after `make all doom`; no runtime claim."""
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from elf_to_mem import elf_image, words


def main():
    build = ROOT / "firmware" / "build"
    for name, base, size, entry in (("diagnostic", 0x80000000, 0x800000, "_start"),
                                    ("boot", 0, 0x4000, "_reset"),
                                    ("doom", 0x80000000, 0x800000, "_start")):
        data = (build / f"{name}.elf").read_bytes()
        image = elf_image(data, base, size)
        phoff = struct.unpack_from("<I", data, 28)[0]
        phsize, phnum = struct.unpack_from("<HH", data, 42)
        end = base
        for i in range(phnum):
            ptype, _, _, address, filesz, _, _, _ = struct.unpack_from(
                "<IIIIIIII", data, phoff + i * phsize)
            if ptype == 1 and filesz:
                end = max(end, address + filesz)
        binary = (build / f"{name}.bin").read_bytes()
        if binary != image[:end - base]:
            raise AssertionError(f"{name}.bin differs from initialized ELF load bytes")
        if (build / f"{name}.mem").read_text(encoding="ascii") != words(image):
            raise AssertionError(f"{name}.mem differs from ELF load/BSS image")
        disassembly = (build / f"{name}.dis").read_text(encoding="ascii")
        if f"<{entry}>:" not in disassembly:
            raise AssertionError(f"{name}.dis missing entry-point disassembly")
        if name == "boot" and binary != struct.pack("<III", 0x800002b7, 0x0000100f, 0x00028067):
            raise AssertionError("boot instruction encodings changed")
        print(f"{name}: bin={len(binary)} bytes, mem/dis verified")


if __name__ == "__main__":
    main()
