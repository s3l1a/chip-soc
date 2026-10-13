"""Directed RV32IM/Zicsr programs and hand-derived retirement expectations.

The full/misa cases have hand-derived expectations, not a trusted ISA model.
The optional arithmetic case replaces those expectations with pinned Unicorn
results. No DUT state is read to construct either kind of expectation.
"""
import argparse
import json
from pathlib import Path

MASK = 0xFFFFFFFF
HANDLER = 0x18000
DATA = 0x20000
FAULT = 0x30000
IF_FAULT = 0x40000


def u32(x):
    return x & MASK


def signed(x):
    return (x & 0x7FFFFFFF) - (x & 0x80000000)


def i_type(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def r_type(rd, f3, rs1, rs2, f7=0):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33


def branch(f3, rs1, rs2, offset):
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63


def jal(rd, offset):
    return (((offset >> 20) & 1) << 31) | (((offset >> 1) & 1023) << 21) | (((offset >> 11) & 1) << 20) | (((offset >> 12) & 255) << 12) | (rd << 7) | 0x6F


def divide(a, b, signed_mode, remainder):
    aa, bb = (signed(a), signed(b)) if signed_mode else (a, b)
    if bb == 0:
        return a if remainder else MASK
    q = abs(aa) // abs(bb)
    if (aa < 0) != (bb < 0):
        q = -q
    return u32(aa - q * bb if remainder else q)


class Program:
    def __init__(self):
        self.pc = 0
        self.words = {}
        self.rows = []
        self.bus = []
        self.events = []
        self.regs = [0] * 32
        self.csrs = {0x300: 0x1800, 0x301: 0x40001100, 0x304: 0,
                     0x305: 0, 0x306: 0, 0x310: 0, 0x340: 0, 0x341: 0,
                     0x342: 0, 0x343: 0, 0x344: 0, 0xF15: 0}
        self.instret = 0
        self.mem = {}
        self.initial_overrides = {}
        self.coverage = {}
        self.irq = False

    def put(self, pc, word):
        if pc in self.words and self.words[pc] != word:
            raise ValueError(f"conflicting instruction at {pc:x}")
        self.words[pc] = word

    def emit(self, word, rd=0, result=0, next_pc=None, name="", mask=MASK):
        next_pc = self.pc + 4 if next_pc is None else next_pc
        self.put(self.pc, word)
        self.rows.append((len(self.rows), self.pc, word, next_pc, rd,
                          u32(result) if rd else 0, 0, 0, 0, mask))
        if rd:
            self.regs[rd] = u32(result)
        self.pc = next_pc
        self.instret += 1
        if name:
            self.coverage[name] = self.coverage.get(name, 0) + 1

    def li(self, rd, value):
        value = u32(value)
        hi = ((value + 0x800) >> 12) & 0xFFFFF
        self.emit((hi << 12) | (rd << 7) | 0x37, rd, hi << 12, name="lui")
        self.emit(i_type(0x13, rd, 0, rd, value), rd, value, name="addi")

    def csr(self, address, f3, rd, source):
        src = source if f3 & 4 else self.regs[source]
        write = (f3 & 3) == 1 or source != 0
        if address in (0xB02, 0xC02):
            old = self.instret & MASK
        elif address in (0xB82, 0xC82):
            old = self.instret >> 32
        elif address in (0xB00, 0xC00):
            old = 0  # The bench checks cycle CSRs against elapsed clocks/writes.
        elif address in (0xB80, 0xC80):
            old = self.csrs.get(0xB80, 0)
        elif address == 0x344:
            old = 0x80 if self.irq else 0
        else:
            old = self.csrs.get(address, 0)
        value = src if (f3 & 3) == 1 else old | src if (f3 & 3) == 2 else old & ~src
        self.emit(i_type(0x73, rd, f3, source, address), rd, old,
                  name={1: "csrrw", 2: "csrrs", 3: "csrrc", 5: "csrrwi", 6: "csrrsi", 7: "csrrci"}[f3],
                  mask=0 if address in (0xB00, 0xB80, 0xC00, 0xC80) and rd else MASK)
        if write:
            if address == 0x300:
                value = 0x1800 | (value & 0x88)
            elif address == 0x304:
                value &= 0x80
            elif address == 0x305:
                value = (value & ~3) | (1 if value & 3 == 1 else 0)
            elif address == 0x341:
                value &= ~3
            elif address in (0x301, 0x306, 0x310, 0x344):
                return
            elif address in (0xB02, 0xB82):
                self.instret = ((self.instret & ~MASK) | u32(value)) if address == 0xB02 else ((u32(value) << 32) | (self.instret & MASK))
            self.csrs[address] = u32(value)

    def resume_setup(self, instruction_count=1, resume=None):
        # x19 is reserved as the exception/interrupt return address.
        self.li(19, self.pc + 8 + instruction_count * 4 if resume is None else resume)

    def exception(self, word, cause, tval, fault_insn=None, resume=None):
        fault_pc = self.pc
        if word is not None:
            self.put(self.pc, word)
        insn = word if fault_insn is None else fault_insn
        handler = (self.csrs[0x305] & ~3) + (28 if cause & 0x80000000 and self.csrs[0x305] & 3 == 1 else 0)
        self.rows.append((len(self.rows), fault_pc, insn or 0, handler, 0, 0, 1, cause, u32(tval), MASK))
        self.csrs[0x341] = fault_pc
        self.csrs[0x342] = cause
        self.csrs[0x343] = u32(tval)
        self.csrs[0x300] = 0x1800 | (0x80 if self.csrs[0x300] & 8 else 0)
        self.coverage[f"trap_{cause:08x}"] = self.coverage.get(f"trap_{cause:08x}", 0) + 1
        self.pc = handler
        if handler != HANDLER:
            self.emit(jal(0, HANDLER - handler), next_pc=HANDLER, name="jal")
        if cause & 0x80000000:
            self.events.append((0, handler, 0))
            self.irq = False
        for address, rd in ((0x300, 20), (0x304, 21), (0x341, 22),
                            (0x342, 23), (0x343, 24), (0x344, 25)):
            self.csr(address, 2, rd, 0)
        self.csr(0x341, 1, 0, 19)
        self.csrs[0x300] = 0x1880 | (8 if self.csrs[0x300] & 0x80 else 0)
        self.emit(0x30200073, next_pc=self.regs[19] if resume is None else resume, name="mret")

    def trap_instruction(self, word, cause, tval=None):
        self.resume_setup()
        self.exception(word, cause, word if tval is None else tval)

    def memory(self, store, f3, offset, rd=3, rs1=1, rs2=2):
        ea = u32(self.regs[rs1] + offset)
        if store:
            word = ((offset & 0xFE0) << 20) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((offset & 31) << 7) | 0x23
        else:
            word = i_type(0x03, rd, f3, rs1, offset)
        width = 1 << (f3 & 3)
        if ea % width:
            self.trap_instruction(word, 6 if store else 4, ea)
            return
        strobe = ((1 << width) - 1) << (ea & 3)
        data = u32(self.regs[rs2] << (8 * (ea & 3)))
        self.bus.append((ea & ~3, int(store), strobe if store else 0,
                         data if store else 0, 0, 15 if store else 0, MASK if store else 0))
        if ea >= FAULT:
            self.trap_instruction(word, 7 if store else 5, ea)
            return
        if store:
            for lane in range(width):
                self.mem[ea + lane] = (self.regs[rs2] >> (8 * lane)) & 255
            self.emit(word, name={0: "sb", 1: "sh", 2: "sw"}[f3])
        else:
            value = sum(self.mem.get(ea + lane, 0) << (8 * lane) for lane in range(width))
            if f3 < 4 and value & (1 << (8 * width - 1)):
                value -= 1 << (8 * width)
            self.emit(word, rd, value, name={0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[f3])


def arithmetic(p):
    p.emit(0xFFFFF017, 0, 0, name="auipc")
    p.emit(0x80000197, 3, p.pc + 0x80000000, name="auipc")
    edges = [0, 1, 2, 31, 32, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA]
    for a in edges:
        p.li(1, a)
        for b in edges:
            p.li(2, b)
            results = [a + b, a << (b & 31), int(signed(a) < signed(b)), int(a < b), a ^ b, a >> (b & 31), a | b, a & b]
            for f3, value in enumerate(results):
                p.emit(r_type(3, f3, 1, 2), 3, value, name=["add", "sll", "slt", "sltu", "xor", "srl", "or", "and"][f3])
            p.emit(r_type(3, 0, 1, 2, 0x20), 3, a - b, name="sub")
            p.emit(r_type(3, 5, 1, 2, 0x20), 3, signed(a) >> (b & 31), name="sra")
            products = [a * b, signed(a) * signed(b) >> 32, signed(a) * b >> 32, a * b >> 32]
            for f3, value in enumerate(products):
                p.emit(r_type(3, f3, 1, 2, 1), 3, value, name=["mul", "mulh", "mulhsu", "mulhu"][f3])
            for f3 in range(4, 8):
                p.emit(r_type(3, f3, 1, 2, 1), 3, divide(a, b, not f3 & 1, bool(f3 & 2)), name=["div", "divu", "rem", "remu"][f3 - 4])
        for imm in (-2048, -1, 0, 1, 2047):
            values = {0: a + imm, 2: int(signed(a) < imm), 3: int(a < u32(imm)), 4: a ^ u32(imm), 6: a | u32(imm), 7: a & u32(imm)}
            for f3, value in values.items():
                p.emit(i_type(0x13, 3, f3, 1, imm), 3, value, name={0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}[f3])
        for shamt in range(32):
            for f3, imm, value, name in ((1, shamt, a << shamt, "slli"), (5, shamt, a >> shamt, "srli"), (5, shamt | 0x400, signed(a) >> shamt, "srai")):
                p.emit(i_type(0x13, 3, f3, 1, imm), 3, value, name=name)

    # Destination/source aliases, x0 writes, dependency chains, and divider state reuse.
    p.li(1, 0x80000000)
    p.li(2, MASK)
    for rd, f3 in ((1, 4), (2, 6), (0, 5), (1, 7), (2, 4)):
        p.emit(r_type(rd, f3, 1, 2, 1), rd, divide(p.regs[1], p.regs[2], not f3 & 1, bool(f3 & 2)), name="divide_alias")
    for rd in (0, 1, 2):
        for f7, f3 in [(0, f3) for f3 in range(8)] + [(0x20, 0), (0x20, 5)] + [(1, f3) for f3 in range(8)]:
            a, b = 0x80000001, 0xFFFFFFFF
            p.li(1, a)
            p.li(2, b)
            values = [a + b, a << 31, int(signed(a) < signed(b)), int(a < b), a ^ b, a >> 31, a | b, a & b]
            if f7 == 0x20:
                value = a - b if f3 == 0 else signed(a) >> 31
            elif f7 == 1:
                value = [a * b, signed(a) * signed(b) >> 32, signed(a) * b >> 32, a * b >> 32][f3] if f3 < 4 else divide(a, b, not f3 & 1, bool(f3 & 2))
            else:
                value = values[f3]
            p.emit(r_type(rd, f3, 1, 2, f7), rd, value, name="alu_m_alias")
            p.emit(i_type(0x13, 4, 0, rd, 1), 4, p.regs[rd] + 1, name="alu_m_use")
    for rd in range(32):
        p.emit(i_type(0x13, rd, 0, rd - 1 if rd else 0, 1), rd, p.regs[rd - 1 if rd else 0] + 1, name="register_chain")
    p.emit(r_type(3, 0, 0, 0), 3, 0, name="x0_read")


def generate():
    p = Program()
    p.li(1, HANDLER)
    p.csr(0x305, 1, 0, 1)
    arithmetic(p)

    # All branch comparisons, taken/not taken and backward loops.
    for a, b in ((0, 0), (1, 0), (MASK, 1), (0x80000000, 0x7FFFFFFF)):
        p.li(1, a)
        p.li(2, b)
        conditions = {0: a == b, 1: a != b, 4: signed(a) < signed(b), 5: signed(a) >= signed(b), 6: a < b, 7: a >= b}
        for f3, taken in conditions.items():
            pc = p.pc
            p.put(pc + 4, i_type(0x13, 0, 0, 0, 0))
            p.emit(branch(f3, 1, 2, 8), next_pc=pc + (8 if taken else 4), name={0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}[f3])
            if not taken:
                p.emit(i_type(0x13, 0, 0, 0, 0), name="nop")
            # Misaligned targets must not trap on untaken branches.
            if not taken:
                p.emit(branch(f3, 1, 2, 2), name="untaken_misaligned")
            else:
                p.resume_setup()
                p.exception(branch(f3, 1, 2, 2), 0, p.pc + 2)
    p.li(1, 3)
    loop = p.pc
    for n in (2, 1, 0):
        p.emit(i_type(0x13, 1, 0, 1, -1), 1, n, name="addi")
        p.emit(branch(1, 1, 0, -4), next_pc=loop if n else p.pc + 4, name="bne")
    pc = p.pc
    p.emit(jal(1, 8), 1, pc + 4, pc + 8, "jal")
    p.put(pc + 4, 0xFFFFFFFF)  # Poison skipped instruction.
    target = p.pc + 12
    p.li(1, target | 1)
    p.emit(i_type(0x67, 1, 0, 1, 0), 1, p.pc + 4, target, "jalr")
    target = p.pc + 12
    p.li(1, target + 5)
    p.emit(i_type(0x67, 5, 0, 1, -4), 5, p.pc + 4, target, "jalr")
    # Backward JAL and JALR through small subroutines.
    start = p.pc
    p.put(start + 4, i_type(0x67, 0, 0, 5, 0))
    p.emit(jal(0, 8), next_pc=start + 8, name="jal")
    p.emit(jal(5, -4), 5, start + 12, start + 4, "jal")
    p.emit(i_type(0x67, 0, 0, 5, 0), next_pc=start + 12, name="jalr")
    p.resume_setup()
    p.exception(jal(3, 2), 0, p.pc + 2)
    p.li(1, 2)
    p.trap_instruction(i_type(0x67, 3, 0, 1, 0), 0, 2)

    # Store merging, all byte lanes, both halfword lanes, sign extension, load-use.
    p.li(1, DATA)
    for value in (0x80FF7F01, 0x80017FFF, 0xFFFFFFFF, 0x01234567):
        p.li(2, value)
        p.memory(True, 2, 0)
        for f3 in (0, 4):
            for lane in range(4):
                p.memory(False, f3, lane)
                p.emit(i_type(0x13, 3, 0, 3, -1), 3, p.regs[3] - 1, name="load_use")
        for f3 in (1, 5):
            for lane in (0, 2):
                p.memory(False, f3, lane)
        for lane in range(4):
            p.memory(True, 0, lane)
            p.memory(False, 2, 0)
        for lane in (0, 2):
            p.memory(True, 1, lane)
            p.memory(False, 2, 0)
        p.memory(False, 2, 0, rd=0)
    p.li(1, DATA + 4)
    p.memory(False, 2, -4, rd=1)  # rd aliases the base address.
    p.li(1, DATA)
    for store in (False, True):
        for f3, offsets in ((1, (1, 3)), (2, (1, 2, 3))):
            for offset in offsets:
                p.memory(store, f3, offset)
    p.li(1, FAULT)
    for store in (False, True):
        for f3 in ((0, 1, 2) if store else (0, 1, 2, 4, 5)):
            p.memory(store, f3, 0, rd=0)
    # A failed fetch is precise at the target, not at the preceding jump.
    p.li(1, IF_FAULT)
    resume = p.pc + 12
    p.resume_setup(resume=resume)
    p.emit(i_type(0x67, 0, 0, 1, 0), next_pc=IF_FAULT, name="jalr")
    p.exception(None, 1, IF_FAULT, fault_insn=0)

    # Every unsupported major opcode and reserved subencoding family.
    legal_ops = {0x03, 0x0F, 0x13, 0x17, 0x23, 0x33, 0x37, 0x63, 0x67, 0x6F, 0x73}
    for op in range(128):
        if op not in legal_ops:
            p.trap_instruction(op, 2)
    for f7 in range(128):
        for f3 in range(8):
            if f7 not in (0, 1) and not (f7 == 0x20 and f3 in (0, 5)):
                p.trap_instruction(r_type(3, f3, 1, 2, f7), 2)
        for f3 in (1, 5):
            if f7 != 0 and not (f3 == 5 and f7 == 0x20):
                p.trap_instruction(i_type(0x13, 3, f3, 1, f7 << 5), 2)
    for f3 in range(8):
        if f3 not in (0, 1, 2, 4, 5):
            p.trap_instruction(i_type(0x03, 3, f3, 1, 0), 2)
        if f3 > 2:
            p.trap_instruction((1 << 15) | (f3 << 12) | 0x23, 2)
        if f3 in (2, 3):
            p.trap_instruction(branch(f3, 1, 2, 4), 2)
        if f3:
            p.trap_instruction(i_type(0x67, 3, f3, 1, 0), 2)
        if f3 > 1:
            p.trap_instruction((f3 << 12) | 0x0F, 2)
    for word in (0x00200073, 0x302000F3, 0x10508073, 0x00004073):
        p.trap_instruction(word, 2)
    p.trap_instruction(0x00000073, 11, 0)
    p.resume_setup()
    p.exception(0x00100073, 3, p.pc)
    p.emit(0x10500073, name="wfi")
    p.emit(0x0FF0000F, name="fence")
    p.emit(0x0000100F, name="fence.i")
    p.emit(i_type(0x0F, 3, 0, 1, -1), name="fence_reserved_fields")
    p.emit(i_type(0x0F, 3, 1, 1, -1), name="fence_i_reserved_fields")
    # Self-modifying code: store the new instruction, fence.i, then fetch it.
    target = p.pc + 24
    p.li(1, target)
    p.li(2, i_type(0x13, 3, 0, 0, 123))
    p.memory(True, 2, 0)
    p.emit(0x0000100F, name="fence.i")
    p.emit(i_type(0x13, 3, 0, 0, 123), 3, 123, name="self_modify")
    p.initial_overrides[target] = i_type(0x13, 3, 0, 0, -1)

    # CSR aliases, no-write forms, zero-valued nonzero source, WARL masks.
    for address in (0x300, 0x304, 0x305, 0x310, 0x340, 0x341, 0x342, 0x343):
        for f3 in (1, 2, 3, 5, 6, 7):
            if f3 < 4:
                p.li(1, MASK if address == 0x310 else (0xA5A5FFFF if f3 == 1 else 0x88))
            p.csr(address, f3, 3, 1 if f3 < 4 else 31)
            if address == 0x310:
                p.csr(address, 2, 3, 0)  # Unsupported mstatush bits stay zero after every write.
        p.csr(address, 2, 3, 0)
        p.csr(address, 3, 3, 0)
        p.csr(address, 6, 3, 0)
        p.csr(address, 7, 3, 0)
        p.li(1, 0)
        p.csr(address, 2, 1, 1)
    p.li(1, HANDLER)
    p.csr(0x305, 1, 0, 1)
    p.csr(0x300, 5, 0, 0)
    for address in (0x301, 0x306, 0x344, 0xF11, 0xF12, 0xF13, 0xF14, 0xF15, 0xC00, 0xC80, 0xC02, 0xC82):
        for f3 in (2, 3, 6, 7):
            p.csr(address, f3, 3, 0)
        if address not in (0x301, 0x306, 0x344):
            for f3 in (1, 2, 3, 5, 6, 7):
                p.li(1, 0)  # rs1 != x0 remains a write even when its value is zero.
                p.trap_instruction(i_type(0x73, 3, f3, 1, address), 2)
        if address == 0xF15:
            for f3 in (2, 3, 6, 7):
                p.csr(address, f3, 0, 0)
            for f3 in (1, 5):
                # Suppressing rd and using a zero source does not suppress a write.
                p.trap_instruction(i_type(0x73, 0, f3, 0, address), 2)
    for address in (0x000, 0x100, 0x302, 0xFFF):
        for f3 in (1, 2, 3, 5, 6, 7):
            p.trap_instruction(i_type(0x73, 3, f3, 0, address), 2)
    # Writable counters and read aliases. Cycle low cannot be predetermined.
    p.li(1, 0x1234)
    p.csr(0xB80, 1, 0, 1)
    p.csr(0xC80, 2, 3, 0)
    p.csr(0xB00, 1, 0, 1)
    p.csr(0xC00, 2, 3, 0)
    p.li(1, 0xFFFFFFF0)
    p.csr(0xB00, 1, 0, 1)
    p.csr(0xC00, 2, 3, 0)
    p.csr(0xC80, 2, 3, 0)
    for f3 in (2, 3, 5, 6, 7):
        p.csr(0xB00, f3, 3, 1)
        p.csr(0xB80, f3, 3, 1)
    p.li(1, 0x123)
    p.csr(0xB82, 1, 0, 1)
    p.csr(0xC82, 2, 3, 0)
    p.csr(0xB02, 1, 0, 1)
    p.csr(0xC02, 2, 3, 0)
    p.csr(0xB02, 2, 3, 0)
    p.li(1, 0xFFFFFFFE)
    p.csr(0xB02, 1, 0, 1)
    p.csr(0xC02, 2, 3, 0)
    p.csr(0xC02, 2, 3, 0)
    p.csr(0xC82, 2, 3, 0)
    p.csr(0xC02, 2, 3, 0)

    # Pending timer while either enable is masked, then precise delayed ops.
    p.csr(0x300, 5, 0, 0)
    p.csr(0x304, 5, 0, 0)
    p.events.append((0, p.pc, 1))
    p.irq = True
    p.csr(0x344, 2, 3, 0)
    p.csr(0x300, 6, 0, 8)
    p.emit(i_type(0x13, 3, 0, 0, 8), 3, 8, name="mie_masked")
    p.csr(0x300, 7, 0, 8)
    p.li(1, 0x80)
    p.csr(0x304, 1, 0, 1)
    p.emit(i_type(0x13, 3, 0, 0, 7), 3, 7, name="irq_masked")
    p.resume_setup()
    p.csr(0x300, 6, 0, 8)
    p.exception(None, 0x80000007, 0, fault_insn=0)
    for vectored in (False, True):
        p.li(1, (HANDLER + 0x100 if vectored else HANDLER) | int(vectored))
        p.csr(0x305, 1, 0, 1)
        for kind in range(5):
            p.li(1, DATA)
            p.li(2, 7)
            p.resume_setup()
            trigger = DATA if kind in (1, 4) else p.pc
            p.events.append((1 if kind == 4 else kind, trigger, 1))
            if kind == 0:
                p.emit(i_type(0x13, 3, 0, 0, 42), 3, 42, name="irq_fetch")
            elif kind == 1:
                p.memory(True, 2, 0)
            elif kind == 2:
                p.emit(0x0000100F, name="irq_fence")
            elif kind == 3:
                p.emit(r_type(3, 4, 1, 2, 1), 3, divide(DATA, 7, True, False), name="irq_divide")
            else:
                p.memory(False, 2, 0)
            p.irq = True
            p.exception(None, 0x80000007, 0, fault_insn=0)
    # IRQ during an access fault: synchronous fault wins; MRET re-enables IRQ.
    p.li(1, FAULT)
    p.resume_setup()
    p.events.append((1, FAULT, 1))
    p.irq = True
    p.memory(False, 2, 0)
    # memory() installs its own return address before issuing the faulting load.
    p.exception(None, 0x80000007, 0, fault_insn=0)
    p.emit(i_type(0x13, 3, 0, 0, 99), 3, 99, name="final")
    assert max(pc for pc in p.words if pc < HANDLER) < HANDLER
    mnemonics = "lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl sra or and mul mulh mulhsu mulhu div divu rem remu csrrw csrrs csrrc csrrwi csrrsi csrrci fence fence.i ecall ebreak mret wfi".split()
    # ECALL/EBREAK do not retire normally; their trap causes are the coverage.
    p.coverage["ecall"] = p.coverage["trap_0000000b"]
    p.coverage["ebreak"] = p.coverage["trap_00000003"]
    assert all(p.coverage.get(name, 0) for name in mnemonics)
    return p


def generate_misa():
    """WARL misa writes must not trap, even when all fields are fixed."""
    p = Program()
    p.li(1, 0x40001100)
    for f3 in (1, 2, 3, 5, 6, 7):
        p.csr(0x301, f3, 3, 1)
    p.csr(0x301, 2, 3, 0)
    p.li(1, DATA)
    p.li(2, 42)
    p.memory(True, 2, 0)
    p.emit(0x0000100F, name="fence.i")
    return p


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("sim/generated"))
    parser.add_argument("--case", choices=("full", "misa", "arithmetic"), default="full")
    args = parser.parse_args()
    if args.case == "arithmetic":
        from check_trace import unicorn_retirements
        p = Program()
        arithmetic(p)
        # Only the instruction stream is shared; discard all hand-derived results.
        p.rows = list(unicorn_retirements([p.words[pc] for pc in range(0, p.pc, 4)]))
    else:
        p = generate() if args.case == "full" else generate_misa()
    args.out.mkdir(parents=True, exist_ok=True)
    # Dense image also initializes self-modifying code and unused memory to zero.
    image = [0] * ((DATA + 0x1000) // 4)
    for address, word in p.words.items():
        image[address // 4] = word
    for address, word in p.initial_overrides.items():
        image[address // 4] = word
    (args.out / "cpu.hex").write_text("".join(f"{word:08x}\n" for word in image), encoding="ascii")
    (args.out / "cpu.golden").write_text("".join(" ".join(f"{v:x}" for v in row) + "\n" for row in p.rows), encoding="ascii")
    (args.out / "cpu.bus").write_text("".join(" ".join(f"{v:x}" for v in row) + "\n" for row in p.bus), encoding="ascii")
    (args.out / "cpu.events").write_text("".join(" ".join(f"{v:x}" for v in row) + "\n" for row in p.events), encoding="ascii")
    (args.out / "cpu.coverage.json").write_text(json.dumps(p.coverage, indent=2, sort_keys=True) + "\n", encoding="ascii")
    print(f"generated {len(p.rows)} trace entries, {len(p.bus)} data requests, {len(p.events)} IRQ events")


if __name__ == "__main__":
    main()
