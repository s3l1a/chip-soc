"""Extend scripts/run.py with seeded CPU cases and checker rejection tests.

Default: lint, unit, cpu, monitors, firmware, soc. Never fetch assets or run Doom.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

import run

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "verification"
TASKS = ("lint", "unit", "cpu", "monitors", "firmware", "soc")


def cpu():
    output = BUILD / "tb_cpu.vvp"
    run.command([run.find("iverilog"), "-g2012", "-s", "tb_cpu", "-o", output,
                 "rtl/soc/soc_pkg.sv", "rtl/core/divider.sv",
                 "rtl/core/rv32im_cpu.sv", "sim/unit/tb_cpu.sv"])
    for case in ("arithmetic", "full", "misa"):
        directory = BUILD / case
        run.command([sys.executable, "tools/cpu_vectors.py", "--case", case,
                     "--out", directory])
        for seed, delay in ((1, 17), (0x1205ABCD, 31), (0xDEADBEEF, 63)):
            trace = directory / f"seed_{seed:08x}.trace"
            run.command([run.find("vvp"), output, f"+DIR={directory.as_posix()}",
                         f"+TRACE={trace.as_posix()}", f"+SEED={seed}", f"+MAX_DELAY={delay}"])
            reference = directory / ("cpu.hex" if case == "arithmetic" else "cpu.golden")
            run.command([sys.executable, "tools/check_trace.py", reference, trace,
                         *(["--unicorn"] if case == "arithmetic" else [])])


def monitors():
    output = BUILD / "tb_monitors.vvp"
    run.command([run.find("iverilog"), "-g2012", "-s", "tb_monitors", "-o", output,
                 "formal/protocol_monitor.sv", "formal/x0_monitor.sv", "formal/tb_monitors.sv"])
    run.command([run.find("vvp"), output, "+FAIL_CASE=0"])
    messages = (
        "duplicate/overlapping accepted request", "unsolicited/duplicate response",
        "incorrect response beat count/last", "request changed under backpressure",
        "response changed under backpressure", "x0 storage changed",
        "nonzero rs1 x0 read", "nonzero x0 retirement result",
    )
    for case, message in enumerate(messages, 1):
        args = [run.find("vvp"), str(output), f"+FAIL_CASE={case}"]
        print("+", " ".join(args), flush=True)
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=30)
        print(result.stdout + result.stderr, end="", flush=True)
        if result.returncode == 0 or message not in result.stdout + result.stderr:
            raise RuntimeError(f"monitor case {case} did not reject with '{message}'")
        print(f"PASS monitor negative case {case}: expected rejection", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tasks", nargs="*", metavar="TASK", help=", ".join(TASKS))
    parser.add_argument("--cross", default=os.environ.get("CROSS"), help="newlib toolchain prefix")
    parser.add_argument("--make", default=os.environ.get("MAKE", "make"))
    parser.add_argument("--engine", choices=("iverilog", "verilator"), default="verilator")
    parser.add_argument("--no-build", action="store_true", help="reuse the SoC executable only")
    args = parser.parse_args()
    tasks = args.tasks or TASKS
    if any(task not in TASKS for task in tasks):
        parser.error(f"tasks must be selected from {', '.join(TASKS)}")
    BUILD.mkdir(parents=True, exist_ok=True)
    for task in tasks:
        if task in ("lint", "unit"):
            run.command([sys.executable, "scripts/run.py", task])
        elif task == "cpu":
            cpu()
        elif task == "monitors":
            monitors()
        elif task == "firmware":
            cross = args.cross or next((prefix for prefix in ("riscv-none-elf-", "riscv32-unknown-elf-")
                                       if shutil.which(prefix + "gcc")), None)
            if not cross:
                parser.error("firmware needs a newlib toolchain; set CROSS or --cross (see docs/verification.md)")
            run.command([run.find(args.make), "-C", "firmware", "all", f"CROSS={cross}",
                          f"PYTHON={Path(sys.executable).as_posix()}"])
        elif task == "soc":
            # Remove only this runner's prior capture, so a missing new frame cannot pass.
            frame = ROOT / "build/soc/verify_diagnostic_1.ppm"
            frame.unlink(missing_ok=True)
            run.command([sys.executable, "scripts/run.py", "soc", "--engine", args.engine,
                         "--firmware", "firmware/build/diagnostic.mem", "--frames", "1",
                         "--cycles", "100000000", "--prefix", "verify_diagnostic",
                         *(["--no-build"] if args.no_build else [])])
            run.command([sys.executable, "tools/verify_frame.py", "--diagnostic", frame])
    print("PASS verification tasks: " + ", ".join(tasks), flush=True)


if __name__ == "__main__":
    main()
