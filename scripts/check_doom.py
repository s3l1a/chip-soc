"""Check two saved Doom RTL runs against a manifest. Never build, fetch, or simulate."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from verify_frame import verify


def parse_log(text, prefix, manifest):
    count = manifest["summary"]["frames"]
    if re.search(r"(?<![A-Za-z0-9])(?:FATAL|FAIL(?:ED|URE)?|ERROR|watchdog|assertion)(?![A-Za-z0-9])", text, re.IGNORECASE):
        raise ValueError("log contains an assertion/error/failure marker")
    # Harness lines can interrupt an in-flight UART message. Remove those lines
    # only. Compact DG parsing also rejoins interrupted identifiers/hex digits.
    uart = re.sub(r"(?m)^[ \t]*(?:SOC_[^\r\n]*|PASS tb_soc[^\r\n]*)\r?$", "", text)
    uart = re.sub(r"\s+", " ", uart)
    compact = re.sub(r"\s+", "", uart)
    if "FATALTRAP" in compact.upper():
        raise ValueError("log contains a reconstructed FATAL TRAP marker")
    for marker in ("DoomGeneric platform initialized (no audio)", "Freedoom: Phase 1",
                   "Playing demo demo1.lmp.", "I_InitGraphics: DOOM screen size: w x h: 320 x 200"):
        if marker not in uart:
            raise ValueError(f"missing initialization marker: {marker}")
    wad = re.findall(r"DG_WAD bytes=([0-9a-fA-F]{8}) base=([0-9a-fA-F]{8})\b", uart)
    if len(wad) != 1 or (int(wad[0][0], 16), int(wad[0][1], 16)) != (manifest["wad_bytes"], 0x60000000):
        raise ValueError("missing/incorrect WAD size or asset base")
    if compact.count("DG_CREATE_RETURN") != 1:
        raise ValueError("expected exactly one DG_CREATE_RETURN marker")
    frames = re.findall(r"DG_FRAMEframe=([0-9a-fA-F]{8})fnv1a=([0-9a-fA-F]{8})cycles=([0-9a-fA-F]{16})tic=([0-9a-fA-F]{8})(?=DG_|[^0-9a-fA-F]|$)", compact)
    if len(frames) != count or compact.count("DG_FRAME") != count:
        raise ValueError(f"expected exactly {count} complete DG_FRAME markers with tics")
    summaries = re.findall(r"(?m)^PASS tb_soc cycles=(\d+) retired=(\d+) memory_bytes=(\d+) framebuffer_writes=(\d+) frames=(\d+)\s*$", text)
    if len(summaries) != 1:
        raise ValueError("expected exactly one complete tb_soc PASS summary")
    summary = dict(zip(("cycles", "retired", "memory_bytes", "framebuffer_writes", "frames"),
                       map(int, summaries[0])))
    if summary != manifest["summary"]:
        raise ValueError(f"PASS summary differs from baseline: {summary}")
    flips = [dict(zip(("frame", "cycle", "cycles_per_frame", "memory_beats"), map(int, values)))
             for values in re.findall(r"(?m)^SOC_FLIP frame=(\d+) cycle=(\d+) cycles_per_frame=(\d+) memory_beats=(\d+)\s*$", text)]
    if flips != manifest["flips"]:
        raise ValueError("flip sequence/timing/bandwidth differs from baseline")
    captures = re.findall(r"(?m)^SOC_CAPTURE frame=(\d+) path=([^\r\n]+)\s*$", text)
    if [(int(frame), Path(path.strip().replace("\\", "/")).name) for frame, path in captures] != [
            (i, f"{prefix.name}_{i}.ppm") for i in range(1, count + 1)]:
        raise ValueError(f"expected {count} consecutive capture paths matching the prefix")
    events = re.findall(r"(?m)^(SOC_FLIP|SOC_CAPTURE|PASS tb_soc)\b[^\r\n]*", text)
    if events != ["SOC_FLIP", "SOC_CAPTURE"] * count + ["PASS tb_soc"]:
        raise ValueError("out-of-order or extra harness events")
    previous_cycle = previous_beats = previous_dg = 0
    previous_tic = None
    for i, (flip, (frame, fnv, cycles, tic)) in enumerate(zip(flips, frames), 1):
        dg_cycle = int(cycles, 16)
        if int(frame, 16) != i or fnv.lower() != manifest["fnv1a"][i - 1]:
            raise ValueError(f"DG_FRAME {i} sequence/checksum mismatch")
        gametic = int(tic, 16)
        if gametic != manifest["gametics"][i - 1] or (previous_tic is not None and gametic != previous_tic + 1):
            raise ValueError(f"DG_FRAME {i} guest tic mismatch/nonconsecutive progression")
        previous_tic = gametic
        if not previous_dg < dg_cycle <= summary["cycles"]:
            raise ValueError("invalid DG_FRAME cycle sequence")
        if flip["cycle"] - previous_cycle != flip["cycles_per_frame"] or flip["memory_beats"] <= previous_beats:
            raise ValueError("inconsistent flip cycle/beat accounting")
        previous_cycle, previous_beats, previous_dg = flip["cycle"], flip["memory_beats"], dg_cycle
    if not (previous_cycle < summary["cycles"] and 0 < summary["retired"] <= summary["cycles"]
            and previous_beats * 4 <= summary["memory_bytes"] <= summary["cycles"] * 4
            and summary["memory_bytes"] % 4 == 0 and 0 < summary["framebuffer_writes"] <= summary["cycles"]):
        raise ValueError("invalid final cycle/retirement/bandwidth accounting")
    return {"summary": summary, "flips": flips, "dg_frames": frames}


def self_test(manifest):
    import unittest

    prefix = Path("test")
    lines = ["DoomGeneric platform initialized (no audio)", "Freedoom: Phase 1",
             "Playing demo demo1.lmp.", "I_InitGraphics: DOOM screen size: w x h: 320 x 200",
             f"DG_WAD bytes={manifest['wad_bytes']:08x} base=60000000"]
    for i, flip in enumerate(manifest["flips"], 1):
        marker = (f"DG_FRAME frame={i:08x} fnv1a={manifest['fnv1a'][i - 1]} "
                  f"cycles={flip['cycle']:016x} tic={manifest['gametics'][i - 1]:08x}")
        # Interrupt identifiers and numeric fields, not only token boundaries.
        split = (marker.index("fnv") + 3, marker.index("tic=") + 5,
                 marker.index("cycles=") + 12, marker.index("frame=") + 9)[(i - 1) % 4]
        lines.extend([marker[:split],
                      "SOC_FLIP " + " ".join(f"{key}={value}" for key, value in flip.items()),
                      marker[split:],
                      f"SOC_CAPTURE frame={i} path=build/soc/test_{i}.ppm"])
        if i == 1:
            lines.append("DG_CREATE_RETURN")
    lines.append("PASS tb_soc " + " ".join(f"{key}={value}" for key, value in manifest["summary"].items()))
    text = "\n".join(lines) + "\n"

    class LogTests(unittest.TestCase):
        def test_interleaved_uart(self):
            parse_log(text.replace("\n", "\r\n\r\n"), prefix, manifest)

        def test_reject_interleaved_fatal_trap(self):
            flip = "SOC_FLIP " + " ".join(f"{key}={value}" for key, value in manifest["flips"][0].items())
            for split in range(1, len("FATAL TRAP")):
                for marker in ("FATAL TRAP", "fatal trap"):
                    interrupted = marker[:split] + "\n" + flip + "\n" + marker[split:] + " mcause=00000002\n"
                    bad = interrupted + text.replace(flip + "\n", "", 1)
                    for log in (bad, bad.replace("\n", "\r\n\r\n")):
                        with self.subTest(split=split, log=log[:100]), self.assertRaisesRegex(ValueError, "FATAL TRAP|failure marker"):
                            parse_log(log, prefix, manifest)

        def test_corrupted_guest_tics(self):
            for old, new in (("tic=00000002", "tic=00000003"),
                             ("tic=00000004", "tic=00000003"),
                             ("tic=00000005", "tic=00000008")):
                with self.subTest(old=old, new=new), self.assertRaisesRegex(ValueError, "guest tic"):
                    parse_log(text.replace(old, new), prefix, manifest)

        def test_reject_corrupt_incomplete_or_failed_logs(self):
            for bad in (text + "FATAL: assertion failed\n", text.replace("PASS tb_soc", "INCOMPLETE tb_soc"),
                        text + "SOC_ERROR: rejected\n", text + "FAILED\n",
                        text.replace(f"frames={manifest['summary']['frames']}", "frames=1"),
                        text.replace("frame=00000002", "frame=00000001"),
                        text.replace(manifest["fnv1a"][1], "00000000"), text.replace("base=60000000", "base=80800000"),
                        text.replace("Freedoom: Phase 1", "Other game"), text.replace("test_2.ppm", "test_1.ppm"),
                        text.replace(f"memory_bytes={manifest['summary']['memory_bytes']}", "memory_bytes=1"),
                        text.replace("SOC_CAPTURE frame=2 path=build/soc/test_2.ppm\n", ""),
                        text.replace("DG_CREATE_RETURN", ""),
                        text + "SOC_FLIP malformed\n", text + "DG_FRAME truncated\n"):
                with self.subTest(bad=bad[-150:]), self.assertRaises(ValueError):
                    parse_log(bad, prefix, manifest)

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LogTests))
    return result.wasSuccessful()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefixes", type=Path, nargs="*", help="two capture prefixes, with adjacent .log files")
    parser.add_argument("--manifest", type=Path, default=ROOT / "docs/doom-hashes.json")
    parser.add_argument("--firmware", type=Path, default=ROOT / "firmware/build/doom.bin")
    parser.add_argument("--elf", type=Path, default=ROOT / "firmware/build/doom.elf")
    parser.add_argument("--functional", type=Path, help="optional saved functional result.json; compare indexed raw files")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    prefixes = args.prefixes or [ROOT / "build/soc/doom_final_a", ROOT / "build/soc/doom_final_b"]
    if len(prefixes) != 2 or prefixes[0].resolve() == prefixes[1].resolve():
        parser.error("provide two distinct capture prefixes")
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        if manifest["schema"] != 1:
            raise ValueError("unsupported manifest schema")
        count = manifest["summary"]["frames"]
        if count < 2 or len(manifest["fnv1a"]) != count or len(manifest["gametics"]) != count or len(manifest["flips"]) != count:
            raise ValueError("manifest frame sequences do not match summary frame count")
        if args.self_test:
            parser.exit(0 if self_test(manifest) else 1)
        firmware_hash = hashlib.sha256(args.firmware.read_bytes()).hexdigest()
        if firmware_hash != manifest["firmware"]["sha256"]:
            raise ValueError("firmware SHA-256 differs from the recorded GCC 15.2 baseline; do not silently rebaseline")
        elf_hash = hashlib.sha256(args.elf.read_bytes()).hexdigest()
        if elf_hash != manifest["firmware"]["elf_sha256"]:
            raise ValueError("firmware ELF SHA-256 differs from baseline")
        functional_frames = None
        if args.functional:
            functional = json.loads(args.functional.read_text(encoding="utf-8"))
            if (functional["success"] is not True or functional["functional_success"] is not True
                    or functional["failure"] is not None or functional["unicorn"] != "2.1.4"
                    or functional["binary_sha256"] != firmware_hash or functional["elf_sha256"] != elf_hash
                    or functional["wad_sha256"] != manifest["wad_sha256"]
                    or functional["requested_frames"] != count or len(functional["frames"]) != count):
                raise ValueError("functional result is incomplete or identifies a different firmware/WAD")
            functional_frames = []
            for i, frame in enumerate(functional["frames"], 1):
                if (frame["frame"] != i or frame["gametic"] != manifest["gametics"][i - 1]
                        or frame["fnv1a"] != manifest["fnv1a"][i - 1]):
                    raise ValueError(f"functional frame {i} sequence/tic/FNV mismatch")
                functional_frames.append((args.functional.parent / frame["raw"]).read_bytes())
        runs = []
        baseline_frames = None
        for prefix in prefixes:
            log = Path(f"{prefix}.log").read_text(encoding="utf-8")
            measured = parse_log(log, prefix, manifest)
            raw_frames = []
            for i in range(1, count + 1):
                path = Path(f"{prefix}_{i}.ppm")
                raw = path.read_bytes()
                result = verify(raw, indexed=functional_frames[i - 1] if functional_frames is not None else None)
                if result["sha256"] != manifest["hashes"][f"doom_{i}.ppm"] or result["fnv1a"] != manifest["fnv1a"][i - 1]:
                    raise ValueError(f"{path}: raw PPM or recovered indexed FNV differs from baseline/UART")
                raw_frames.append(raw)
                print(f"PASS {path}: " + json.dumps(result, sort_keys=True))
            if len(set(raw_frames)) < 2:
                raise ValueError("consecutive game tics must eventually produce changed images")
            if baseline_frames is not None and raw_frames != baseline_frames:
                raise ValueError("two runs are not byte-identical")
            baseline_frames = raw_frames
            runs.append(measured)
        if runs[0] != runs[1]:
            raise ValueError("two runs have different simulation metrics/UART frame markers")
        summary = runs[0]["summary"]
        seconds = summary["cycles"] / manifest["cpu_hz"]
        print(f"PASS two saved runs: {count} consecutive game frames with image change, byte-identical across runs")
        print("gametics=" + ",".join(map(str, manifest["gametics"])))
        if functional_frames is not None:
            print(f"PASS functional raw comparison: all {count} indexed 64000-byte frames match both RTL runs")
        print(f"firmware_sha256={firmware_hash} elf_sha256={elf_hash} cycles={summary['cycles']} retired={summary['retired']} "
              f"IPC={summary['retired'] / summary['cycles']:.6f} simulated_seconds={seconds:.6f} "
              f"external_bytes={summary['memory_bytes']} external_MB_per_s={summary['memory_bytes'] / seconds / 1e6:.6f} "
              f"framebuffer_write_requests={summary['framebuffer_writes']}")
        for flip in runs[0]["flips"]:
            print(f"frame={flip['frame']} flip_cycle={flip['cycle']} cycles_since_previous_flip={flip['cycles_per_frame']} "
                  f"external_beats={flip['memory_beats']}")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
