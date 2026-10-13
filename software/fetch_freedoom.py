#!/usr/bin/env python3
"""Fetch approved official Freedoom 0.13.0, verify ZIP SHA-256, extract Phase 1 only."""
import hashlib
import json
from pathlib import Path
import struct
from urllib.request import urlopen
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "external" / "assets"
URL = "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
ARCHIVE_SHA = "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
ARCHIVE_SIZE = 24143781
WAD_SIZE = 28795076


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    archive = DEST / "freedoom-0.13.0.zip"
    if not archive.exists():
        with urlopen(URL, timeout=60) as response:
            data = response.read(ARCHIVE_SIZE + 1)
    else:
        data = archive.read_bytes()
    if len(data) != ARCHIVE_SIZE or hashlib.sha256(data).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError("official archive size/SHA-256 mismatch; nothing extracted")
    if not archive.exists():
        archive.write_bytes(data)
    extracted = {}
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            basename = Path(name).name
            if basename == "freedoom1.wad" or basename.upper().startswith(("COPYING", "CREDITS", "LICENSE")):
                extracted[basename] = z.read(name)
    if "freedoom1.wad" not in extracted or not any(name.upper().startswith("COPYING") for name in extracted):
        raise RuntimeError("archive missing Phase 1 WAD or license notice")
    wad = extracted["freedoom1.wad"]
    if len(wad) != WAD_SIZE:
        raise RuntimeError("unexpected extracted WAD size")
    magic, count, directory = struct.unpack_from("<4sII", wad)
    if magic != b"IWAD" or directory > len(wad) or count > (len(wad) - directory) // 16:
        raise RuntimeError("invalid IWAD directory")
    demos = []
    for i in range(count):
        offset, size, name = struct.unpack_from("<II8s", wad, directory + 16 * i)
        if offset > len(wad) or size > len(wad) - offset:
            raise RuntimeError("WAD lump outside file")
        if name.rstrip(b"\0").startswith(b"DEMO") and size >= 13:
            demo = wad[offset:offset + size]
            players = list(demo[9:13])
            tic_size = 4 * sum(bool(player) for player in players)
            tic_count = ((size - 14) // tic_size if demo[0] == 109 and tic_size and
                         demo[-1] == 128 and (size - 14) % tic_size == 0 else None)
            demos.append({"name": name.rstrip(b"\0").decode("ascii"), "bytes": size,
                          "version": demo[0], "skill": demo[1], "episode": demo[2],
                          "map": demo[3], "players": players, "end_marker": demo[-1],
                          "tic_count": tic_count,
                          "sha256": hashlib.sha256(demo).hexdigest()})
    if not any(demo["name"] == "DEMO1" and demo["version"] == 109 and
               demo["players"] == [1, 0, 0, 0] and demo["tic_count"] == 7117 for demo in demos):
        raise RuntimeError("expected single-player v1.9 DEMO1 was not found")
    for name, content in extracted.items():
        target = DEST / name
        if target.exists() and target.read_bytes() != content:
            raise RuntimeError(f"refusing to replace modified asset/notice: {target}")
    for name, content in extracted.items():
        (DEST / name).write_bytes(content)
    metadata = {"url": URL, "archive_sha256": ARCHIVE_SHA, "archive_bytes": ARCHIVE_SIZE,
                "wad": "freedoom1.wad", "wad_bytes": WAD_SIZE,
                "wad_sha256": hashlib.sha256(wad).hexdigest(), "demos": demos,
                "notices": sorted(name for name in extracted if name != "freedoom1.wad"),
                "license": "Freedoom BSD-style three-condition license; see extracted COPYING"}
    text = json.dumps(metadata, indent=2) + "\n"
    (DEST / "freedoom-0.13.0.provenance.json").write_text(text, encoding="ascii")
    print(text)
    print("Archive SHA-256 verified against official checksum; PGP signature not authenticated.")


if __name__ == "__main__":
    main()
