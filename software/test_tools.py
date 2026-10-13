#!/usr/bin/env python3
"""Host-only tests. They do not claim RTL, firmware execution, or Doom validation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from assets import CAPACITY, RAM_CAPACITY, pack_wad
from elf_to_mem import elf_image, words


def elf(payload=b"\x13\0\0\0", memory_size=8, address=0x80000000):
    ident = b"\x7fELF\x01\x01\x01" + bytes(9)
    header = struct.pack("<HHIIIIIHHHHHH", 2, 243, 1, address, 52, 0, 0,
                         52, 32, 1, 0, 0, 0)
    program = struct.pack("<IIIIIIII", 1, 84, address, address, len(payload),
                          memory_size, 5, 4)
    return ident + header + program + payload


class ElfTests(unittest.TestCase):
    def test_load_and_bss(self):
        self.assertEqual(elf_image(elf(), 0x80000000, 4096), b"\x13" + bytes(7))

    def test_word_endian_and_offset(self):
        self.assertEqual(words(b"\x01\x02\x03\x04\x05", 0x200000),
                         "@00200000\n04030201\n00000005\n")

    def test_boot_rom_last_word_16k(self):
        image = elf_image(elf(memory_size=4, address=0x3ffc), 0, 0x4000)
        self.assertEqual(len(image), 0x4000)
        self.assertEqual(image[-4:], b"\x13\0\0\0")

    def test_boot_rom_reject_beyond_16k(self):
        with self.assertRaises(ValueError):
            elf_image(elf(memory_size=4, address=0x4000), 0, 0x4000)

    def test_reject_outside_app(self):
        with self.assertRaises(ValueError):
            elf_image(elf(address=0x80800000), 0x80000000, 0x800000)

    def test_reject_short_segment(self):
        with self.assertRaises(ValueError):
            elf_image(elf()[:-1], 0x80000000, 4096)

    def test_reject_filesz_gt_memsz(self):
        with self.assertRaises(ValueError):
            elf_image(elf(memory_size=2), 0x80000000, 4096)

    def test_reject_malformed_empty_load(self):
        data = bytearray(elf())
        struct.pack_into("<H", data, 44, 2)
        struct.pack_into("<I", data, 56, 116)
        data[84:84] = struct.pack("<IIIIIIII", 1, 0xffffffff, 0xffffffff,
                                  0xffffffff, 0xffffffff, 0, 5, 4)
        with self.assertRaisesRegex(ValueError, "invalid PT_LOAD"):
            elf_image(data, 0x80000000, 4096)

    def test_reject_empty_load_offset_past_eof(self):
        data = bytearray(elf())
        struct.pack_into("<H", data, 44, 2)
        struct.pack_into("<I", data, 56, 116)
        data[84:84] = struct.pack("<IIIIIIII", 1, 121, 0, 0, 0, 0, 0, 4)
        self.assertEqual(len(data), 120)
        with self.assertRaisesRegex(ValueError, "invalid PT_LOAD"):
            elf_image(data, 0x80000000, 4096)

    def test_allow_empty_load(self):
        for offset in (0, 120):
            data = bytearray(elf())
            struct.pack_into("<H", data, 44, 2)
            struct.pack_into("<I", data, 56, 116)
            data[84:84] = struct.pack("<IIIIIIII", 1, offset, 0xffffffff, 0,
                                      0, 0, 5, 4)
            with self.subTest(offset=offset):
                self.assertEqual(elf_image(data, 0x80000000, 4096), b"\x13" + bytes(7))

    def test_reject_wrong_machine(self):
        data = bytearray(elf()); struct.pack_into("<H", data, 18, 62)
        with self.assertRaises(ValueError):
            elf_image(data, 0x80000000, 4096)

    def test_reject_nonexecutable_entry(self):
        data = bytearray(elf()); struct.pack_into("<I", data, 52 + 24, 6)
        with self.assertRaises(ValueError):
            elf_image(data, 0x80000000, 4096)

    def test_reject_overlap(self):
        data = bytearray(elf()); struct.pack_into("<H", data, 44, 2)
        program = bytes(data[52:84]); struct.pack_into("<I", data, 56, 116)
        data[84:84] = program; struct.pack_into("<I", data, 88, 116)
        with self.assertRaises(ValueError):
            elf_image(data, 0x80000000, 4096)


class FunctionalResultTests(unittest.TestCase):
    def setUp(self):
        build = Path(__file__).resolve().parents[1] / "build"
        build.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="release_audit_", dir=build)
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "run"
        self.output.mkdir()
        self.result = self.output / "result.json"
        self.capture = self.output / "frame_1.raw"
        self.capture.write_bytes(b"old capture")
        self.result.write_text(json.dumps({"success": True}), encoding="ascii")

    def assert_failed_result(self):
        result = json.loads(self.result.read_text(encoding="ascii"))
        self.assertIs(result["success"], False)
        self.assertIs(result["functional_success"], False)
        self.assertTrue(result["failure"])
        self.assertEqual(result["frames"], [])
        self.assertIsNone(result["binary_sha256"])
        self.assertEqual(self.capture.read_bytes(), b"old capture")
        return result

    def test_prerequisite_and_probe_failures_replace_success(self):
        import functional_soc
        from contextlib import redirect_stdout
        import io

        uc = MagicMock(__version__="2.1.4")
        uc.uc_version.return_value = (2, 1, 0x020104FF)
        uc.UcError = type("ProbeError", (Exception,), {})

        def reject_probe(*args):
            self.assertFalse(self.result.exists())
            raise uc.UcError("probe rejected")

        uc.Uc.side_effect = reject_probe
        wrong_version = MagicMock(__version__="unsupported")
        for module, options, message in (
                (None, [], "import of unicorn halted"),
                (wrong_version, [], "requires unicorn==2.1.4"),
                (uc, ["--frames", "0"], "--frames must be between"),
                (uc, [], "probe rejected")):
            with self.subTest(message=message):
                self.result.write_text(json.dumps({"success": True}), encoding="ascii")
                argv = ["functional_soc.py", "--output", str(self.output), *options]
                with patch.object(sys, "argv", argv), patch.dict(sys.modules, {"unicorn": module}), redirect_stdout(io.StringIO()):
                    self.assertEqual(functional_soc.main(), 1)
                self.assertIn(message, self.assert_failed_result()["failure"])

    @unittest.skipUnless(importlib.util.find_spec("unicorn"), "missing-ELF probe requires Unicorn")
    def test_missing_elf_replaces_success(self):
        script = Path(__file__).resolve().parents[1] / "tools" / "functional_soc.py"
        missing = self.output / "missing.elf"
        result = subprocess.run([sys.executable, "-B", str(script), "--elf", missing.as_posix(),
                                 "--output", str(self.output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(repr(str(missing)), self.assert_failed_result()["failure"])


class AssetTests(unittest.TestCase):
    def setUp(self):
        self.wad = struct.pack("<4sII", b"IWAD", 1, 16) + b"test" + struct.pack(
            "<II8s", 12, 4, b"TEST")
        self.sha = hashlib.sha256(self.wad).hexdigest()

    def test_header_and_payload(self):
        packed = pack_wad(self.wad, self.sha, len(self.wad))
        self.assertEqual(packed[:8], b"CHWAD001")
        self.assertEqual(struct.unpack_from("<II", packed, 8), (32, 64))
        self.assertEqual(packed[16:48], bytes.fromhex(self.sha))
        self.assertEqual(packed[48:64], bytes(16))
        self.assertEqual(packed[64:], self.wad)

    def test_checksum(self):
        with self.assertRaises(ValueError): pack_wad(self.wad, "00" * 32, 32)

    def test_size(self):
        with self.assertRaises(ValueError): pack_wad(self.wad, self.sha, 31)

    def test_digest_format(self):
        with self.assertRaises(ValueError): pack_wad(self.wad, "bad", 32)

    def test_directory_bounds(self):
        data = bytearray(self.wad); struct.pack_into("<I", data, 8, 0xffffffff)
        with self.assertRaises(ValueError):
            pack_wad(data, hashlib.sha256(data).hexdigest(), len(data))

    def test_lump_bounds(self):
        data = bytearray(self.wad); struct.pack_into("<I", data, 20, 0xffffffff)
        with self.assertRaises(ValueError):
            pack_wad(data, hashlib.sha256(data).hexdigest(), len(data))

    def test_capacity(self):
        data = b"IWAD" + bytes(CAPACITY)
        with self.assertRaises(ValueError):
            pack_wad(data, hashlib.sha256(data).hexdigest(), len(data))

    def test_flash_accepts_size_rejected_by_ram(self):
        data = struct.pack("<4sII", b"IWAD", 0, 12) + bytes(RAM_CAPACITY - 12)
        sha = hashlib.sha256(data).hexdigest()
        self.assertEqual(len(pack_wad(data, sha, len(data))), len(data) + 64)
        with self.assertRaises(ValueError): pack_wad(data, sha, len(data), "ram")

    def test_backend_validation(self):
        with self.assertRaises(ValueError): pack_wad(self.wad, self.sha, 32, "unknown")

    def test_cli_backend_offsets(self):
        script = Path(__file__).resolve().parents[1] / "tools" / "assets.py"
        with tempfile.TemporaryDirectory() as temporary:
            wad, output = Path(temporary) / "input.wad", Path(temporary) / "output.mem"
            wad.write_bytes(self.wad)
            for backend in (None, "flash", "ram"):
                command = [sys.executable, str(script), str(wad), str(output),
                           "--sha256", self.sha, "--size", "32", "--format", "mem"]
                if backend: command += ["--backend", backend]
                subprocess.run(command, check=True, capture_output=True, text=True)
                expected = words(pack_wad(self.wad, self.sha, 32),
                                 0x200000 if backend == "ram" else 0)
                self.assertEqual(output.read_text(encoding="ascii"), expected)


if __name__ == "__main__":
    unittest.main()
