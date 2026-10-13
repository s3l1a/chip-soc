#!/usr/bin/env python3
"""Read official Freedoom 0.13.0 ZIP directory metadata, never WAD payloads."""
import struct
from urllib.request import Request, urlopen

RELEASE = "https://github.com/freedoom/freedoom/releases/download/v0.13.0/"


def read_range(url, start, end):
    with urlopen(Request(url, headers={"Range": f"bytes={start}-{end}"}), timeout=30) as response:
        if response.status != 206 or not response.headers.get("Content-Range", "").startswith(
                f"bytes {start}-{end}/"):
            raise RuntimeError("server did not honor Range; refusing full archive download")
        data = response.read(end - start + 2)
    if len(data) != end - start + 1:
        raise RuntimeError("incorrect Range response length")
    return data


def wad_sizes(url, archive_size):
    # The official archives have a plain, non-ZIP64, comment-free EOCD record.
    end = read_range(url, archive_size - 22, archive_size - 1)
    signature, disk, cd_disk, disk_count, count, cd_size, cd_offset, comment = struct.unpack(
        "<4s4H2IH", end)
    if (signature != b"PK\x05\x06" or disk or cd_disk or disk_count != count or comment or
            cd_offset + cd_size != archive_size - 22):
        raise RuntimeError("unexpected ZIP directory layout")
    directory = read_range(url, cd_offset, cd_offset + cd_size - 1)
    position = 0
    result = []
    for _ in range(count):
        if position + 46 > len(directory) or directory[position:position + 4] != b"PK\x01\x02":
            raise RuntimeError("invalid ZIP central directory")
        compressed, size = struct.unpack_from("<II", directory, position + 20)
        name_size, extra_size, comment_size = struct.unpack_from("<HHH", directory, position + 28)
        next_position = position + 46 + name_size + extra_size + comment_size
        if next_position > len(directory):
            raise RuntimeError("truncated ZIP directory entry")
        name = directory[position + 46:position + 46 + name_size].decode("utf-8")
        if name.lower().endswith(".wad"):
            result.append((name, size, compressed))
        position = next_position
    if position != len(directory):
        raise RuntimeError("unexpected trailing ZIP directory bytes")
    return result


def main():
    # Published archive byte counts from the official GitHub release API.
    for archive, size in (("freedoom-0.13.0.zip", 24143781), ("freedm-0.13.0.zip", 11331651)):
        for name, wad_size, compressed in wad_sizes(RELEASE + archive, size):
            print(f"{name}: {wad_size} WAD bytes ({compressed} compressed bytes)")
    print("ZIP directory metadata only; no WAD downloaded or SHA-256 authenticated.")


if __name__ == "__main__":
    main()
