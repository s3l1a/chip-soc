"""Pinned official RISC-V ISA tests on the RTL CPU, without architectural bypass."""
import argparse
import hashlib
import json
import fnmatch
import os
import re
import shutil
import struct
from pathlib import Path
import subprocess
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from elf_to_mem import elf_image, words

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / "external/isa"
BASE, RAM_BYTES = 0x80000000, 4194304
_XPACK_DEFAULT = (Path(os.environ.get("APPDATA", Path.home())) / "xPacks" / "@xpack-dev-tools" /
                  "riscv-none-elf-gcc" / "15.2.0-1.1" / ".content" / "bin" / "riscv-none-elf-")
XPACK = os.environ.get("CHIP_RISCV_PREFIX") or str(_XPACK_DEFAULT).replace("\\", "/")
_TOOLS_DEFAULT = Path(os.environ.get("TEMP", "/tmp")) / "chip-tools"
PORTABLE = (os.environ.get("CHIP_TOOL_DIR") and
            (Path(os.environ["CHIP_TOOL_DIR"]) / "iverilog-v14" / "bin").as_posix() + "/") or \
           (_TOOLS_DEFAULT / "iverilog-v14" / "bin").as_posix() + "/"
SOURCES = {
    "riscv-tests": ("riscv-software-src/riscv-tests", "7b68f7b91f827f8d94cc1c57ff123752c5c8f704", {"LICENSE": "Redistribution"}),
    "riscv-test-env": ("riscv/riscv-test-env", "6de71edb142be36319e380ce782c3d1830c65d68", {"LICENSE": "Redistribution"}),
    "riscv-arch-test": ("riscv-non-isa/riscv-arch-test", "96e3589a867955e94c95ba098822da54d3ae39c0", {"COPYING.BSD": "Redistribution", "COPYING.APACHE": "Apache License", "COPYING.CC": "Attribution 4.0"}),
}


def run(command, cwd=ROOT, timeout=120):
    result = subprocess.run([str(arg) for arg in command], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {command}\n{result.stdout}")
    return result.stdout


def git(path, *args):
    return run(["git", "-c", f"safe.directory={path.resolve().as_posix()}", "-c", "core.autocrlf=false", "-C", path, *args]).strip()


def fetch():
    DEPS.mkdir(parents=True, exist_ok=True)
    provenance = {}
    for name, (repo, sha, notices) in SOURCES.items():
        path = DEPS / name
        # Check permission/notices at the exact revision before downloading sources.
        licensed = {}
        for filename, marker in notices.items():
            url = f"https://raw.githubusercontent.com/{repo}/{sha}/{filename}"
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            if marker.encode() not in data:
                raise ValueError(f"unexpected license at {url}")
            licensed[filename] = data
        if not (path / ".git").exists():
            if path.exists() and any(path.iterdir()):
                raise ValueError(f"refusing nonempty non-checkout: {path}")
            path.mkdir(exist_ok=True)
            git(path, "init")
            git(path, "remote", "add", "origin", f"https://github.com/{repo}.git")
            git(path, "fetch", "--depth", "1", "origin", sha)
            git(path, "checkout", "--detach", "FETCH_HEAD")
        if git(path, "rev-parse", "HEAD") != sha or git(path, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError(f"refusing wrong-revision/modified checkout: {path}")
        for filename, data in licensed.items():
            if (path / filename).read_bytes() != data:
                raise ValueError(f"license differs from upstream: {path / filename}")
        provenance[name] = {"repository": f"https://github.com/{repo}", "sha": sha,
                            "licenses": {f: hashlib.sha256(data).hexdigest() for f, data in licensed.items()}}
        print(f"verified {name} {sha}")
    env_pin = git(DEPS / "riscv-tests", "ls-tree", "HEAD", "env").split()[2]
    if env_pin != SOURCES["riscv-test-env"][1]:
        raise ValueError("riscv-tests environment pin mismatch")
    (DEPS / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="ascii")


def verify_sources():
    for name, (_, sha, _) in SOURCES.items():
        path = DEPS / name
        if not (path / ".git").exists() or git(path, "rev-parse", "HEAD") != sha or git(path, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError(f"run fetch first; checkout absent, modified, or wrong revision: {path}")


def selections(suite, pattern):
    selected, skipped = [], []
    if suite in ("tests", "all"):
        for group in ("rv32ui", "rv32um"):
            for source in sorted((DEPS / "riscv-tests/isa" / group).glob("*.S")):
                name = f"{group}-p-{source.stem}"
                if source.stem == "ma_data":
                    skipped.append({"name": name, "status": "INAPPLICABLE", "reason": "requires successful unaligned loads/stores; DUT traps"})
                elif fnmatch.fnmatchcase(name, pattern):
                    selected.append({"name": name, "suite": "tests", "source": str(source)})
    if suite in ("arch", "all"):
        for group in ("I", "M"):
            for source in sorted((DEPS / "riscv-arch-test/riscv-test-suite/rv32i_m" / group / "src").glob("*.S")):
                name = f"arch-rv32-{group}-{source.stem}"
                if fnmatch.fnmatchcase(name, pattern):
                    reference = source.parent.parent / "references" / f"{source.stem}.reference_output"
                    if not reference.is_file():
                        raise ValueError(f"no official reference for {source}")
                    text = source.read_text(encoding="utf-8")
                    if "SPDX-License-Identifier: BSD-3-Clause" not in text and "SPDX-License-Identifier: Apache-2.0" not in text:
                        raise ValueError(f"source license not recognized: {source}")
                    selected.append({"name": name, "suite": "arch", "source": str(source), "reference": str(reference)})
    if not selected:
        raise ValueError("no tests selected")
    return selected, skipped


def compiler_prefix(value):
    if value:
        return value
    compiler = shutil.which("riscv-none-elf-gcc")
    return compiler.rsplit("gcc", 1)[0] if compiler else XPACK


def symbols(elf, cross):
    output = run([cross + "nm", "--defined-only", elf])
    return {fields[2]: int(fields[0], 16) for line in output.splitlines()
            if len(fields := line.split()) == 3 and re.fullmatch("[0-9a-fA-F]+", fields[0])}


def build(args):
    verify_sources()
    selected, skipped = selections(args.suite, args.filter)
    args.out.mkdir(parents=True, exist_ok=True)
    cross = compiler_prefix(args.cross)
    common = [cross + "gcc", "-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-mcmodel=medany", "-mno-relax",
              "-nostdlib", "-nostartfiles", "-static", "-Wl,--no-relax", "-Wl,--build-id=none"]
    built = []
    for test in selected:
        folder = args.out / test["name"]
        folder.mkdir(exist_ok=True)
        source = Path(test["source"])
        elf = folder / "test.elf"
        if test["suite"] == "tests":
            options = ["-I", DEPS / "riscv-test-env/p", "-I", DEPS / "riscv-tests/isa/macros/scalar",
                       "-T", DEPS / "riscv-test-env/p/link.ld"]
        else:
            cases = sorted(set(re.findall(r"#ifdef\s+(TEST_CASE_\d+)", source.read_text(encoding="utf-8"))))
            options = ["-DXLEN=32", "-DFLEN=0", "-I", ROOT / "sim/isa", "-I", DEPS / "riscv-arch-test/riscv-test-suite/env",
                       "-T", ROOT / "sim/isa/arch.ld"] + [f"-D{case}" for case in cases if case != "TEST_CASE_1"]
        command = common + options + ["-Wl,-Map," + str(folder / "test.map"), source, "-o", elf]
        try:
            output = run(command)
        except RuntimeError as error:
            (folder / "build.log").write_text(str(error) + "\n", encoding="utf-8")
            if test["name"] == "arch-rv32-I-jalr-01" and "la x0,5b" in str(error):
                skipped.append({"name": test["name"], "status": "BUILD_BLOCKED", "command": [str(c) for c in command],
                                "reason": "legacy TEST_JALR_OP expands LA(x0, 5b); GNU binutils 2.45 rejects la x0,5b"})
                print(f"BUILD_BLOCKED {test['name']}; see {folder / 'build.log'}")
                continue
            raise
        (folder / "build.log").write_text(output, encoding="utf-8")
        data = elf.read_bytes()
        image = elf_image(data, BASE, RAM_BYTES)
        if struct.unpack_from("<I", data, 36)[0] & 7:
            raise ValueError(f"compressed or floating-point ABI ELF flags: {elf}")
        entry = struct.unpack_from("<I", data, 24)[0]
        if entry != BASE:
            raise ValueError(f"entry does not equal RESET_PC: {elf}: {entry:x}")
        (folder / "test.mem").write_text(words(image), encoding="ascii")
        sym = symbols(elf, cross)
        test.update({"tohost": sym["tohost"], "entry": entry, "bytes": len(image),
                     "elf_sha256": hashlib.sha256(data).hexdigest(), "command": [str(c) for c in command]})
        if test["suite"] == "arch":
            test.update({"sig_begin": sym["begin_signature"], "sig_end": sym["end_signature"]})
            reference = Path(test["reference"])
            test["reference_sha256"] = hashlib.sha256(reference.read_bytes()).hexdigest()
            if (test["sig_end"] - test["sig_begin"]) // 4 != len(signature(reference)):
                raise ValueError(f"signature length differs from upstream before execution: {test['name']}")
        print(f"built {test['name']}")
        built.append(test)
    export_notices(args.out, built)
    manifest = {"sources": {name: value[1] for name, value in SOURCES.items()}, "compiler": run([cross + "gcc", "--version"]),
                "assembler": run([cross + "as", "--version"]),
                "selected": built, "skipped": skipped, "filter": args.filter, "ram_base": BASE, "ram_bytes": RAM_BYTES}
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"built {len(built)} binaries; {len(skipped)} skipped (inapplicable/build-blocked, separately recorded)")
    if not built:
        raise RuntimeError("no buildable tests; blocked tests are not passes")


def export_notices(output, tests):
    notice_dir = output / "NOTICES"
    notice_dir.mkdir(exist_ok=True)
    attribution = ["Original chip adapter/harness: MIT; see CHIP-MIT.\nExternal trees are unmodified and separately licensed.\n"]
    shutil.copyfile(ROOT / "LICENSE", notice_dir / "CHIP-MIT")
    for name, (repo, sha, notices) in SOURCES.items():
        attribution.append(f"{name}: https://github.com/{repo}/tree/{sha}\n")
        for filename in notices:
            shutil.copyfile(DEPS / name / filename, notice_dir / f"{name}-{filename}")
    # COPYING.BSD is a template; retain actual per-file copyrights as well.
    for test in tests:
        source = Path(test["source"])
        header = source.read_text(encoding="utf-8").split("#include", 1)[0]
        if "Copyright" in header:
            attribution.append(f"\n{source.relative_to(DEPS).as_posix()}\n{header}\n")
    (notice_dir / "ATTRIBUTION.txt").write_text("\n".join(attribution), encoding="utf-8")


def signature(path):
    result = []
    for line in path.read_text(encoding="ascii").splitlines():
        if line.strip():
            if not re.fullmatch(r"[0-9a-fA-F]{8}", line.strip()):
                raise ValueError(f"invalid signature word: {path}: {line!r}")
            result.append(int(line, 16))
    if not result:
        raise ValueError(f"empty signature: {path}")
    return result


def compare_signature(reference, actual):
    expected, observed = signature(reference), signature(actual)
    if len(expected) != len(observed):
        raise ValueError(f"signature length mismatch: {len(observed)} != {len(expected)}")
    for index, (want, got) in enumerate(zip(expected, observed)):
        if want != got:
            raise ValueError(f"signature word {index}: expected {want:08x}, got {got:08x}")
    return len(expected)


def simulate(args):
    verify_sources()
    manifest = json.loads((args.out / "manifest.json").read_text(encoding="utf-8"))
    if manifest["sources"] != {name: value[1] for name, value in SOURCES.items()}:
        raise ValueError("build manifest source pins differ")
    if manifest["ram_base"] != BASE or manifest["ram_bytes"] != RAM_BYTES:
        raise ValueError("build manifest memory profile differs; rebuild")
    if not manifest["selected"]:
        raise ValueError("empty test manifest is not a passing suite")
    iverilog = args.iverilog or shutil.which("iverilog") or PORTABLE + "iverilog.exe"
    vvp = args.vvp or shutil.which("vvp") or PORTABLE + "vvp.exe"
    bench = args.out / "tb_isa.vvp"
    command = [iverilog, "-g2012", "-s", "tb_isa", "-o", bench, ROOT / "rtl/soc/soc_pkg.sv",
               ROOT / "rtl/core/divider.sv", ROOT / "rtl/core/rv32im_cpu.sv", ROOT / "sim/isa/tb_isa.sv"]
    (args.out / "elaborate.log").write_text(run(command), encoding="utf-8")

    def execute(test):
        folder = args.out / test["name"]
        log = folder / f"run-{args.seed}.log"
        sig = folder / f"signature-{args.seed}.txt"
        result = {"name": test["name"], "suite": test["suite"], "seed": args.seed, "max_delay": args.max_delay}
        try:
            if hashlib.sha256((folder / "test.elf").read_bytes()).hexdigest() != test["elf_sha256"]:
                raise ValueError("ELF differs from build manifest")
            # Revalidate/reconvert the actual ELF before execution, not a stale mem file.
            image = elf_image((folder / "test.elf").read_bytes(), BASE, RAM_BYTES)
            (folder / "test.mem").write_text(words(image), encoding="ascii")
            command = [vvp, bench, f"+NAME={test['name']}", f"+MEM={folder / 'test.mem'}", f"+TOHOST={test['tohost']:x}",
                       f"+SEED={args.seed}", f"+MAX_DELAY={args.max_delay}", f"+LIMIT={args.limit}",
                       f"+ALLOW_TRAPS={int(test['suite'] == 'tests')}", f"+TRACE={folder / f'trace-{args.seed}.txt'}"]
            if test["suite"] == "arch":
                command += [f"+SIGNATURE={sig}", f"+SIG_BEGIN={test['sig_begin']:x}", f"+SIG_END={test['sig_end']:x}"]
            result["command"] = [str(c) for c in command]
            output = run(command, timeout=args.timeout)
            log.write_text(output, encoding="utf-8")
            if f"DONE ISA {test['name']} tohost=1 " not in output:
                raise ValueError("no retired tohost success marker")
            if test["suite"] == "arch":
                reference = Path(test["reference"])
                if hashlib.sha256(reference.read_bytes()).hexdigest() != test["reference_sha256"]:
                    raise ValueError("upstream reference differs from manifest")
                result["signature_words"] = compare_signature(reference, sig)
            result.update({"status": "PASS", "completion": output.strip()})
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            result.update({"status": "FAIL", "error": str(error)})
            log.write_text(str(error) + "\n", encoding="utf-8")
        print(f"{result['status']} {test['name']}" + (f": {result['error']}" if result["status"] == "FAIL" else ""))
        return result

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(execute, manifest["selected"]))
    report = {"sources": manifest["sources"], "seed": args.seed, "max_delay": args.max_delay,
              "results": results, "skipped": manifest["skipped"],
              "rtl_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in (ROOT / "rtl/core/rv32im_cpu.sv", ROOT / "rtl/core/divider.sv")}}
    (args.out / f"results-{args.seed}.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    passed = sum(result["status"] == "PASS" for result in results)
    inapplicable = sum(item["status"] == "INAPPLICABLE" for item in manifest["skipped"])
    blocked = sum(item["status"] == "BUILD_BLOCKED" for item in manifest["skipped"])
    print(f"ISA TOTAL: {passed} PASS, {len(results) - passed} FAIL, {inapplicable} inapplicable, {blocked} build-blocked")
    for prefix in ("rv32ui-p-", "rv32um-p-", "arch-rv32-I-", "arch-rv32-M-"):
        subset = [result for result in results if result["name"].startswith(prefix)]
        print(f"  {prefix}: {sum(result['status'] == 'PASS' for result in subset)} PASS / {len(subset)} executed")
    if passed != len(results):
        raise RuntimeError("one or more official tests failed; see per-test logs/results")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("fetch", "build", "run", "notices", "all"))
    parser.add_argument("--suite", choices=("tests", "arch", "all"), default="all")
    parser.add_argument("--filter", default="*")
    parser.add_argument("--out", type=Path, default=DEPS / "build")
    parser.add_argument("--cross", help="GCC/binutils prefix, optionally an absolute path")
    parser.add_argument("--iverilog")
    parser.add_argument("--vvp")
    parser.add_argument("--seed", type=int, default=427296003)
    parser.add_argument("--max-delay", type=int, default=11)
    parser.add_argument("--limit", type=int, default=2000000)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    args.out = args.out.resolve()
    if not 1 <= args.seed <= 0xFFFFFFFF or not 1 <= args.max_delay <= 1000 or not 1 <= args.jobs <= 8:
        parser.error("invalid seed, delay, or jobs")
    try:
        if args.action in ("fetch", "all"):
            fetch()
        if args.action in ("build", "all"):
            build(args)
        if args.action in ("run", "all"):
            simulate(args)
        if args.action == "notices":
            verify_sources()
            manifest = json.loads((args.out / "manifest.json").read_text(encoding="utf-8"))
            export_notices(args.out, manifest["selected"])
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"isa_tests: {error}\n")


if __name__ == "__main__":
    main()
