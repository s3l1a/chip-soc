"""Compare directed golden traces or independently replay RV32IM arithmetic."""
import argparse
from pathlib import Path

FIELDS = ("order", "pc", "insn", "next_pc", "rd", "result", "trap", "cause", "tval")
UNICORN_VERSION = "2.1.4"


def unicorn_retirements(words):
    """External-model results: no hand golden, DUT results, or operand seeding."""
    try:
        import unicorn
        from unicorn import riscv_const as r
    except ImportError as error:
        raise ValueError(f"install the optional reference with: python -m pip install unicorn=={UNICORN_VERSION}") from error
    if unicorn.__version__ != UNICORN_VERSION:
        raise ValueError(f"expected Unicorn {UNICORN_VERSION}, got {unicorn.__version__}")
    if unicorn.uc_version()[2] != 0x020104FF:
        raise ValueError(f"expected native Unicorn 2.1.4 release, got {unicorn.uc_version()}")
    if not words:
        raise ValueError("empty arithmetic program")
    for index, word in enumerate(words):
        op, f3, f7 = word & 127, (word >> 12) & 7, word >> 25
        valid = 0 <= word <= 0xFFFFFFFF and op in (0x13, 0x17, 0x33, 0x37)
        if op == 0x13 and f3 in (1, 5):
            valid &= f7 == 0 or (f3 == 5 and f7 == 0x20)
        if op == 0x33:
            valid &= f7 in (0, 1) or (f7 == 0x20 and f3 in (0, 5))
        if not valid:
            raise ValueError(f"outside arithmetic reference scope at {index * 4:08x}: {word:x}")
    code = b"".join(word.to_bytes(4, "little") for word in words)
    engine = unicorn.Uc(unicorn.UC_ARCH_RISCV, unicorn.UC_MODE_RISCV32)
    engine.ctl_set_cpu_model(r.UC_CPU_RISCV32_SIFIVE_E31)
    engine.mem_map(0, (len(code) + 4095) & ~4095)
    engine.mem_write(0, code)
    regs = [getattr(r, f"UC_RISCV_REG_X{rd}") for rd in range(32)]
    for register in regs:
        engine.reg_write(register, 0)
    engine.reg_write(r.UC_RISCV_REG_PC, 0)
    for order, word in enumerate(words):
        pc = engine.reg_read(r.UC_RISCV_REG_PC)
        if pc != order * 4:
            raise ValueError(f"unexpected reference PC: {pc:x}")
        try:
            engine.emu_start(pc, len(code), count=1)
        except unicorn.UcError as error:
            raise ValueError(f"Unicorn failed at pc={pc:08x} insn={word:08x}: {error}") from error
        rd = (word >> 7) & 31
        yield (order, pc, word, engine.reg_read(r.UC_RISCV_REG_PC), rd,
               engine.reg_read(regs[rd]) & 0xFFFFFFFF if rd else 0, 0, 0, 0, 0xFFFFFFFF)


def arithmetic_image(path):
    words = [row[0] for row in rows(path, 1)]
    # The generated dense image contains straight-line code followed by zeros.
    end = words.index(0) if 0 in words else len(words)
    if any(words[end:]):
        raise ValueError("arithmetic image has nonzero data after its zero terminator")
    return words[:end]


def rows(path, columns):
    with path.open(encoding="ascii") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip() or line.startswith("#"):
                continue
            values = tuple(int(word, 16) for word in line.split())
            if len(values) != columns:
                raise ValueError(f"{path}:{line_number}: expected {columns} columns, got {len(values)}")
            yield values


def check(golden, actual, unicorn_mode=False):
    from itertools import zip_longest
    count = 0
    reference = unicorn_retirements(arithmetic_image(golden)) if unicorn_mode else rows(golden, 10)
    for index, (expected, observed) in enumerate(zip_longest(reference, rows(actual, 9))):
        if expected is None or observed is None:
            raise ValueError(f"trace length mismatch at entry {index}")
        if expected[0] != index or observed[0] != index:
            raise ValueError(f"non-contiguous retirement order at entry {index}")
        for field, want, got in zip(FIELDS, expected, observed):
            mask = expected[9] if field == "result" else (1 << 64) - 1
            if (want ^ got) & mask:
                raise ValueError(f"entry {index} pc={expected[1]:08x}: {field}: expected {want:x}, got {got:x}, mask={mask:x}")
        count += 1
    if not count:
        raise ValueError("empty trace is not a passing test")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("golden", type=Path, help="golden text, or dense arithmetic hex with --unicorn")
    parser.add_argument("actual", type=Path)
    parser.add_argument("--unicorn", action="store_true", help=f"independent arithmetic replay with pinned Unicorn {UNICORN_VERSION}")
    args = parser.parse_args()
    try:
        count = check(args.golden, args.actual, args.unicorn)
    except (ValueError, OSError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    model = f"Unicorn {UNICORN_VERSION} RISCV32/SIFIVE_E31 arithmetic" if args.unicorn else "directed"
    print(f"PASS: {count} {model} retirement entries")


if __name__ == "__main__":
    main()
