#!/usr/bin/env python3
"""Verify a WAD and pack simulated read-only assets or legacy RAM; never download."""
import argparse
import hashlib
from pathlib import Path
import re
import struct
from elf_to_mem import words

CAPACITY = 64 * 1024 * 1024
RAM_CAPACITY = 8 * 1024 * 1024
HEADER_SIZE = 64


def pack_wad(data, sha256, expected_size, backend="flash"):
    if backend not in ("flash", "ram"):
        raise ValueError("backend must be flash or ram")
    capacity = CAPACITY if backend == "flash" else RAM_CAPACITY
    if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
        raise ValueError("SHA-256 must be exactly 64 hexadecimal digits")
    if len(data) != expected_size:
        raise ValueError(f"size mismatch: got {len(data)}, expected {expected_size}")
    digest = hashlib.sha256(data).digest()
    if digest.hex() != sha256.lower():
        raise ValueError("SHA-256 mismatch")
    if len(data) < 12 or len(data) > capacity - HEADER_SIZE:
        raise ValueError(f"WAD must fit in {capacity} bytes minus the 64-byte header")
    magic, count, directory = struct.unpack_from("<4sII", data)
    if magic not in (b"IWAD", b"PWAD") or directory > len(data) or count > (len(data) - directory) // 16:
        raise ValueError("invalid WAD header/directory")
    for i in range(count):
        offset, size = struct.unpack_from("<II", data, directory + 16 * i)
        if offset > len(data) or size > len(data) - offset:
            raise ValueError(f"lump {i} outside WAD")
    return struct.pack("<8sII32s16x", b"CHWAD001", len(data), HEADER_SIZE, digest) + data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wad", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--size", required=True, type=int, help="exact WAD byte count")
    parser.add_argument("--format", choices=("bin", "mem"), default="bin")
    parser.add_argument("--backend", choices=("flash", "ram"), default="flash",
                        help="flash: separate 64 MiB simulated asset array at 0x60000000; "
                             "ram: legacy top 8 MiB of application RAM at 0x80800000")
    args = parser.parse_args()
    try:
        # Stat before reading to avoid accepting an arbitrarily large input.
        capacity = CAPACITY if args.backend == "flash" else RAM_CAPACITY
        if args.wad.stat().st_size > capacity - HEADER_SIZE:
            raise ValueError(f"WAD exceeds {args.backend} storage capacity; no truncation allowed")
        packed = pack_wad(args.wad.read_bytes(), args.sha256, args.size, args.backend)
        if args.format == "mem":
            offset = 0 if args.backend == "flash" else 0x800000 // 4
            args.output.write_text(words(packed, offset), encoding="ascii")
        else:
            args.output.write_bytes(packed)
        print(f"verified {args.size} WAD bytes; packed {len(packed)} bytes for {args.backend}")
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, f"assets: {error}\n")


if __name__ == "__main__":
    main()
