"""Validate raw P6 VGA captures, optional exact comparisons, and raw SHA-256.

Diagnostic pixels are independently derived from firmware/main.c and the RGB332
palette. Doom checks include RGB332 scanout/FNV recovery, not an ISA model.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

WIDTH, HEIGHT = 640, 480
WHITESPACE = b" \t\r\n\v\f"


def parse_ppm(data):
    """Consume header tokens, but never skip binary raster whitespace or '#'."""
    offset = 0
    tokens = []
    for _ in range(4):
        while offset < len(data):
            if data[offset] in WHITESPACE:
                offset += 1
            elif data[offset] == ord("#"):
                end = data.find(b"\n", offset)
                if end < 0:
                    raise ValueError("unterminated PPM header comment")
                offset = end + 1
            else:
                break
        start = offset
        while offset < len(data) and data[offset] not in WHITESPACE + b"#":
            offset += 1
        tokens.append(data[start:offset])
    if tokens != [b"P6", b"640", b"480", b"255"]:
        raise ValueError(f"expected P6 640x480 maxval 255, got {tokens!r}")
    if offset >= len(data) or data[offset] not in WHITESPACE:
        raise ValueError("missing raster delimiter")
    # Treat CRLF as one header line ending; otherwise consume exactly one byte.
    offset += 2 if (data[offset:offset + 2] == b"\r\n"
                    and len(data) - offset == WIDTH * HEIGHT * 3 + 2) else 1
    pixels = data[offset:]
    if len(pixels) != WIDTH * HEIGHT * 3:
        raise ValueError(f"expected {WIDTH * HEIGHT * 3} raster bytes, got {len(pixels)}")
    return pixels


def verify(data, diagnostic=False, indexed=None):
    pixels = parse_ppm(data)
    colors = set()
    nonblack = 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            offset = (y * WIDTH + x) * 3
            pixel = pixels[offset:offset + 3]
            if y < 40 or y >= 440:
                expected = b"\0\0\0"
            elif diagnostic:
                sx, sy = x // 2, (y - 40) // 2
                expected = bytes(((sx * 8 // 320) * 255 // 7,
                                  (sy * 8 // 200) * 255 // 7, 255))
            else:
                colors.add(pixel)
                nonblack += pixel != b"\0\0\0"
                continue
            if pixel != expected:
                raise ValueError(f"pixel ({x},{y}): expected {tuple(expected)}, got {tuple(pixel)}")
            if 40 <= y < 440:
                colors.add(pixel)
                nonblack += pixel != b"\0\0\0"
    if not diagnostic and (len(colors) < 16 or nonblack < WIDTH * 400 // 100):
        raise ValueError(f"Doom graphical sanity failed: {len(colors)} colors, {nonblack} nonblack pixels")
    result = {"width": WIDTH, "height": HEIGHT, "colors": len(colors), "nonblack": nonblack,
              "sha256": hashlib.sha256(data).hexdigest()}
    if not diagnostic:
        red_green = {i * 255 // 7: i for i in range(8)}
        blue = {i * 255 // 3: i for i in range(4)}
        fnv = 2166136261
        recovered = bytearray() if indexed is not None else None
        for y in range(40, 440, 2):
            for x in range(0, WIDTH, 2):
                offset = (y * WIDTH + x) * 3
                pixel = pixels[offset:offset + 3]
                for other in (offset + 3, offset + WIDTH * 3, offset + WIDTH * 3 + 3):
                    if pixels[other:other + 3] != pixel:
                        raise ValueError(f"inconsistent 2x2 scanout group at ({x},{y})")
                r, g, b = pixel
                if r not in red_green or g not in red_green or b not in blue:
                    raise ValueError(f"non-RGB332 palette color at ({x},{y}): {tuple(pixel)}")
                index = (red_green[r] << 5) | (red_green[g] << 2) | blue[b]
                fnv = ((fnv ^ index) * 16777619) & 0xFFFFFFFF
                if recovered is not None:
                    recovered.append(index)
        result["fnv1a"] = f"{fnv:08x}"
        if recovered is not None and recovered != indexed:
            raise ValueError("recovered 64000 indexed pixels differ from functional raw frame")
    return result


def self_test():
    from contextlib import redirect_stdout, redirect_stderr
    import io
    import unittest
    from unittest.mock import patch

    class FrameTests(unittest.TestCase):
        def setUp(self):
            levels = (0, 36, 72, 109, 145, 182, 218, 255)
            bars = bytes(WIDTH * 40 * 3)
            image = b"".join(b"".join(bytes((r, g, 255)) * 80 for r in levels) * 50 for g in levels)
            self.frame = b"P6\n640 480\n255\n" + bars + image + bars

        def test_diagnostic(self):
            result = verify(self.frame, True)
            self.assertEqual((result["colors"], result["nonblack"]), (64, 256000))

        def test_bad_pixel_and_bars(self):
            for offset in (0, WIDTH * 40 * 3 + 2, WIDTH * 440 * 3):
                bad = bytearray(self.frame)
                bad[15 + offset] ^= 1
                with self.assertRaises(ValueError):
                    verify(bytes(bad), True)

        def test_header_and_binary_boundary(self):
            raster = bytes((10, 32, 35)) + bytes(WIDTH * HEIGHT * 3 - 3)
            self.assertEqual(parse_ppm(b"P6\n# comment\n640 480\n255\n" + raster), raster)
            self.assertEqual(parse_ppm(b"P6\r\n640 480\r\n255\r\n" + raster), raster)
            self.assertEqual(parse_ppm(b"P6\n640 480\n255\r" + raster), raster)
            for bad in (self.frame[:-1], self.frame + b"\0", self.frame.replace(b"640", b"320", 1),
                        self.frame.replace(b"P6", b"P3", 1), b"P6\n# no newline"):
                with self.assertRaises(ValueError):
                    parse_ppm(bad)

        def test_doom_sanity(self):
            result = verify(self.frame)
            fnv = 2166136261
            for g in range(8):
                for _ in range(25):
                    for r in range(8):
                        for _ in range(40):
                            fnv = ((fnv ^ ((r << 5) | (g << 2) | 3)) * 16777619) & 0xFFFFFFFF
            self.assertEqual(result["fnv1a"], f"{fnv:08x}")
            header = b"P6\n640 480\n255\n"
            for raster in (bytes(WIDTH * HEIGHT * 3),
                           bytes(WIDTH * 40 * 3) + b"\xff\xff\xff" * (WIDTH * 400) + bytes(WIDTH * 40 * 3)):
                with self.assertRaises(ValueError):
                    verify(header + raster)

        def test_doom_scanout_and_palette(self):
            for offsets in ((WIDTH * 40 * 3,), (WIDTH * 40 * 3, WIDTH * 40 * 3 + 3,
                                                WIDTH * 41 * 3, WIDTH * 41 * 3 + 3)):
                bad = bytearray(self.frame)
                for offset in offsets:
                    bad[15 + offset] = 1
                with self.assertRaises(ValueError):
                    verify(bytes(bad))

        def test_functional_raw_comparison(self):
            indexed = b"".join(bytes((r << 5) | (g << 2) | 3 for r in range(8) for _ in range(40)) * 25
                               for g in range(8))
            verify(self.frame, indexed=indexed)
            for bad in (indexed[:-1], indexed + b"\0", bytes([indexed[0] ^ 1]) + indexed[1:]):
                with self.assertRaises(ValueError):
                    verify(self.frame, indexed=bad)

        def test_cli_comparisons(self):
            digest = hashlib.sha256(self.frame).hexdigest()
            for reference, hashes, code in (
                (self.frame, {"frame.ppm": digest}, 0),
                (self.frame[:-1], {"frame.ppm": digest}, 1),
                (self.frame, {"frame.ppm": "0" * 64}, 1),
                (self.frame, {}, 1),
                (self.frame, [], 1),
                (self.frame, None, 1),
                (self.frame, {"hashes": None}, 1),
                (self.frame, {"hashes": {"frame.ppm": digest}}, 0),
            ):
                with self.subTest(hashes=hashes, code=code), \
                        patch.object(sys, "argv", ["verify_frame.py", "--diagnostic", "frame.ppm",
                                                  "--compare", "ref.ppm", "--expected", "hashes.json"]), \
                        patch.object(Path, "read_bytes", side_effect=[self.frame, reference]), \
                        patch.object(Path, "read_text", return_value=json.dumps(hashes)), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    if code:
                        with self.assertRaises(SystemExit) as error:
                            main()
                        self.assertEqual(error.exception.code, code)
                    else:
                        main()

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FrameTests))
    return result.wasSuccessful()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames", type=Path, nargs="*")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--diagnostic", action="store_true", help="check every page-1 diagnostic pixel")
    modes.add_argument("--doom", action="store_true", help="check RGB332, 2x scanout, diversity, and recover FNV (default)")
    parser.add_argument("--compare", type=Path, nargs="+", help="corresponding byte-identical reference PPMs")
    parser.add_argument("--expected", type=Path, help="basename/SHA-256 object or manifest containing a 'hashes' object")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    if not args.frames:
        parser.error("provide at least one PPM capture")
    if args.compare and len(args.compare) != len(args.frames):
        parser.error("--compare needs one reference per capture")
    try:
        expected = json.loads(args.expected.read_text(encoding="utf-8")) if args.expected else None
        if isinstance(expected, dict) and "hashes" in expected:
            expected = expected["hashes"]
        if args.expected and not isinstance(expected, dict):
            raise ValueError("expected hashes must be a JSON object")
        for index, path in enumerate(args.frames):
            data = path.read_bytes()
            result = verify(data, args.diagnostic)
            if args.compare and data != args.compare[index].read_bytes():
                raise ValueError(f"{path}: raw PPM differs from {args.compare[index]}")
            if expected is not None and expected.get(path.name) != result["sha256"]:
                raise ValueError(f"{path}: raw SHA-256 differs from expected JSON (or entry missing)")
            print(f"PASS {path}: " + json.dumps(result, sort_keys=True))
    except (OSError, ValueError) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
