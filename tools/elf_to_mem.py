#!/usr/bin/env python3
"""ELF32 LE RISC-V PT_LOAD to word-indexed Verilog $readmemh, no dependencies."""
import argparse
from pathlib import Path
import struct


def elf_image(data, base, size):
    if base < 0 or size <= 0 or base + size > 2**32 or base % 4 or size % 4:
        raise ValueError("memory window must be word aligned and inside RV32")
    if len(data) < 52 or data[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("expected ELF32 little-endian version 1")
    fields = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
    kind, machine, version, entry, phoff = fields[:5]
    ehsize, phsize, phnum = fields[7:10]
    if kind != 2 or machine != 243 or version != 1 or ehsize != 52 or phsize != 32:
        raise ValueError("expected executable RISC-V ELF with ELF32 headers")
    if phoff + phnum * phsize > len(data):
        raise ValueError("truncated program headers")
    image = bytearray(size)
    ranges = []
    entry_ok = False
    high = 0
    for i in range(phnum):
        ptype, offset, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from(
            "<IIIIIIII", data, phoff + i * phsize)
        if ptype != 1:
            continue
        if filesz > memsz or offset + filesz > len(data):
            raise ValueError("truncated/invalid PT_LOAD")
        if memsz == 0:
            continue
        if paddr < base or paddr + memsz > base + size or vaddr != paddr:
            raise ValueError("PT_LOAD outside window or non-identity mapping")
        start, end = paddr - base, paddr - base + memsz
        if any(start < b and a < end for a, b in ranges):
            raise ValueError("overlapping PT_LOAD segments")
        ranges.append((start, end))
        image[start:start + filesz] = data[offset:offset + filesz]
        high = max(high, end)
        entry_ok |= bool(flags & 1 and paddr <= entry < paddr + filesz)
    if not ranges or not entry_ok:
        raise ValueError("entry is not in a loaded executable segment")
    return image[:(high + 3) & ~3]


def words(data, word_offset=0):
    padded = data + bytes((-len(data)) % 4)
    return f"@{word_offset:08x}\n" + "".join(
        f"{word[0]:08x}\n" for word in struct.iter_unpack("<I", padded))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base", type=lambda s: int(s, 0), default=0x80000000)
    parser.add_argument("--size", type=lambda s: int(s, 0), default=0x800000)
    args = parser.parse_args()
    try:
        image = elf_image(args.elf.read_bytes(), args.base, args.size)
        args.output.write_text(words(image), encoding="ascii")
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, f"elf_to_mem: {error}\n")


if __name__ == "__main__":
    main()
