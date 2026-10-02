#!/usr/bin/env python3
"""Reference model of the RV32I SoC: instruction-set simulator plus cycle model.

The model is written from the RISC-V unprivileged specification and the SoC
memory map (sw/common/soc_map.h), not translated from the VHDL. The test
runner executes every program on both and compares them instruction by
instruction (commit trace), together with the outcome and the cycle count.

Timing model of the pipeline (documented in rtl/core/rv32i_core.vhd):
  * cycle 0 is the first cycle after reset; instruction 0 is in EX in cycle 1;
  * every instruction spends one cycle in EX, a taken branch or jump adds one
    bubble behind it;
  * an MMIO read issued in EX in cycle c returns the register contents of
    cycle c, a write in cycle c takes effect in cycle c + 1.
Because the model knows the EX cycle of every instruction it also predicts
MTIME, INSTRET and the UART busy flag, so programs that print their own cycle
counts still have to match the hardware bit for bit.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

MASK32 = 0xFFFF_FFFF

# Address regions, selected by address bits [31:28].
REGION_ROM = 0x0
REGION_RAM = 0x1
REGION_MMIO = 0x2

# MMIO registers as word indices (address bits [7:2]) from 0x2000_0000.
UART_DATA = 0x00 >> 2
UART_STATUS = 0x04 >> 2
GPIO_OUT = 0x10 >> 2
GPIO_IN = 0x14 >> 2
MTIME = 0x20 >> 2
INSTRET = 0x24 >> 2
CRC_STATE = 0x30 >> 2
CRC_DATA = 0x34 >> 2
TEST_STATUS = 0x40 >> 2

TEST_PASS = 1

ABI_NAMES = (
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
)


class Decoded(NamedTuple):
    mnemonic: str  # lower-case mnemonic, or "illegal"
    rd: int
    rs1: int
    rs2: int
    imm: int       # sign-extended Python int (U-type: the 32-bit value)


ILLEGAL = Decoded("illegal", 0, 0, 0, 0)

_OP = {
    (0x00, 0): "add", (0x20, 0): "sub", (0x00, 1): "sll", (0x00, 2): "slt",
    (0x00, 3): "sltu", (0x00, 4): "xor", (0x00, 5): "srl", (0x20, 5): "sra",
    (0x00, 6): "or", (0x00, 7): "and",
}
_OP_IMM = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
_SHIFT_IMM = {(1, 0x00): "slli", (5, 0x00): "srli", (5, 0x20): "srai"}
_LOAD = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
_STORE = {0: "sb", 1: "sh", 2: "sw"}
_BRANCH = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def to_signed(value: int) -> int:
    return value - (1 << 32) if value & 0x8000_0000 else value


def decode(word: int) -> Decoded:
    """Decodes one 32-bit instruction word; anything outside RV32I is illegal."""
    opcode = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7 = word >> 25
    imm_i = sext(word >> 20, 12)

    if opcode == 0x37:
        return Decoded("lui", rd, 0, 0, word & 0xFFFF_F000)
    if opcode == 0x17:
        return Decoded("auipc", rd, 0, 0, word & 0xFFFF_F000)
    if opcode == 0x6F:
        imm = (((word >> 31) & 1) << 20 | ((word >> 12) & 0xFF) << 12
               | ((word >> 20) & 1) << 11 | ((word >> 21) & 0x3FF) << 1)
        return Decoded("jal", rd, 0, 0, sext(imm, 21))
    if opcode == 0x67:
        return Decoded("jalr", rd, rs1, 0, imm_i) if f3 == 0 else ILLEGAL
    if opcode == 0x63:
        if f3 not in _BRANCH:
            return ILLEGAL
        imm = (((word >> 31) & 1) << 12 | ((word >> 7) & 1) << 11
               | ((word >> 25) & 0x3F) << 5 | ((word >> 8) & 0xF) << 1)
        return Decoded(_BRANCH[f3], 0, rs1, rs2, sext(imm, 13))
    if opcode == 0x03:
        return Decoded(_LOAD[f3], rd, rs1, 0, imm_i) if f3 in _LOAD else ILLEGAL
    if opcode == 0x23:
        if f3 not in _STORE:
            return ILLEGAL
        return Decoded(_STORE[f3], 0, rs1, rs2, sext((f7 << 5) | rd, 12))
    if opcode == 0x13:
        if f3 in _OP_IMM:
            return Decoded(_OP_IMM[f3], rd, rs1, 0, imm_i)
        mnemonic = _SHIFT_IMM.get((f3, f7))
        return Decoded(mnemonic, rd, rs1, 0, rs2) if mnemonic else ILLEGAL
    if opcode == 0x33:
        mnemonic = _OP.get((f7, f3))
        return Decoded(mnemonic, rd, rs1, rs2, 0) if mnemonic else ILLEGAL
    if opcode == 0x0F:
        # FENCE (any predecessor/successor set, also FENCE.TSO and PAUSE);
        # FENCE.I would be Zifencei.
        return Decoded("fence", 0, 0, 0, 0) if f3 == 0 else ILLEGAL
    if opcode == 0x73:
        if word == 0x0000_0073:
            return Decoded("ecall", 0, 0, 0, 0)
        if word == 0x0010_0073:
            return Decoded("ebreak", 0, 0, 0, 0)
    return ILLEGAL


ALU = {
    "add": lambda a, b: (a + b) & MASK32,
    "sub": lambda a, b: (a - b) & MASK32,
    "sll": lambda a, b: (a << (b & 31)) & MASK32,
    "slt": lambda a, b: int(to_signed(a) < to_signed(b)),
    "sltu": lambda a, b: int(a < b),
    "xor": lambda a, b: a ^ b,
    "srl": lambda a, b: a >> (b & 31),
    "sra": lambda a, b: (to_signed(a) >> (b & 31)) & MASK32,
    "or": lambda a, b: a | b,
    "and": lambda a, b: a & b,
}
IMM_TO_ALU = {
    "addi": "add", "slti": "slt", "sltiu": "sltu", "xori": "xor", "ori": "or",
    "andi": "and", "slli": "sll", "srli": "srl", "srai": "sra",
}
BRANCH = {
    "beq": lambda a, b: a == b,
    "bne": lambda a, b: a != b,
    "blt": lambda a, b: to_signed(a) < to_signed(b),
    "bge": lambda a, b: to_signed(a) >= to_signed(b),
    "bltu": lambda a, b: a < b,
    "bgeu": lambda a, b: a >= b,
}
LOADS = frozenset(_LOAD.values())
STORES = frozenset(_STORE.values())


def load_value(mnemonic: str, word: int, offset: int) -> int:
    """Extracts and extends the addressed byte/halfword of an aligned word."""
    shifted = word >> (8 * offset)
    if mnemonic == "lb":
        return sext(shifted & 0xFF, 8) & MASK32
    if mnemonic == "lh":
        return sext(shifted & 0xFFFF, 16) & MASK32
    if mnemonic == "lbu":
        return shifted & 0xFF
    if mnemonic == "lhu":
        return shifted & 0xFFFF
    return word


def is_misaligned(mnemonic: str, address: int) -> bool:
    if mnemonic in ("lh", "lhu", "sh"):
        return bool(address & 1)
    if mnemonic in ("lw", "sw"):
        return bool(address & 3)
    return False


def store_lanes(mnemonic: str, value: int, offset: int) -> tuple[int, int]:
    """Returns (byte enables, bus word). Data is replicated into every lane."""
    if mnemonic == "sb":
        return 1 << offset, (value & 0xFF) * 0x0101_0101
    if mnemonic == "sh":
        return 0b0011 << offset, (value & 0xFFFF) * 0x0001_0001
    return 0b1111, value


def crc32_update_byte(crc: int, byte: int) -> int:
    """Reflected CRC-32 (polynomial 0xEDB88320), one byte, no final XOR."""
    crc ^= byte & 0xFF
    for _ in range(8):
        crc = (crc >> 1) ^ (0xEDB8_8320 if crc & 1 else 0)
    return crc


def disassemble(word: int, pc: int | None = None) -> str:
    """Human-readable form of one instruction, used in mismatch reports."""
    d = decode(word)
    m, r = d.mnemonic, ABI_NAMES
    if m == "illegal":
        return f".word 0x{word:08x}"
    if m in ("ecall", "ebreak", "fence"):
        return m
    if m in ("lui", "auipc"):
        return f"{m} {r[d.rd]}, 0x{d.imm >> 12:05x}"
    if m in ALU:
        return f"{m} {r[d.rd]}, {r[d.rs1]}, {r[d.rs2]}"
    if m in IMM_TO_ALU:
        return f"{m} {r[d.rd]}, {r[d.rs1]}, {d.imm}"
    if m in LOADS:
        return f"{m} {r[d.rd]}, {d.imm}({r[d.rs1]})"
    if m in STORES:
        return f"{m} {r[d.rs2]}, {d.imm}({r[d.rs1]})"
    if m == "jalr":
        return f"jalr {r[d.rd]}, {d.imm}({r[d.rs1]})"
    target = f"0x{(pc + d.imm) & MASK32:x}" if pc is not None else f"pc{d.imm:+d}"
    if m == "jal":
        return f"jal {r[d.rd]}, {target}"
    return f"{m} {r[d.rs1]}, {r[d.rs2]}, {target}"


def trace_line(pc: int, word: int, rd: int, rd_value: int,
               byte_enable: int, address: int, bus_word: int) -> str:
    """One commit-trace record, in exactly the format tb_soc writes."""
    data = 0
    for lane in range(4):
        if byte_enable >> lane & 1:
            data |= bus_word & (0xFF << (8 * lane))
    return (f"{pc:08X} {word:08X} {rd:02X} {rd_value:08X} "
            f"{byte_enable:X} {address:08X} {data:08X}")


@dataclass
class RunResult:
    outcome: str          # "pass", "fail", "timeout" or a halt cause
    cycles: int           # as counted by tb_soc
    instret: int          # instructions retired
    status: int           # last value written to TEST_STATUS
    halt_pc: int          # PC of the instruction that halted the core, else 0
    leds: int
    uart: bytes           # bytes accepted by the UART transmitter
    trace: list[str] = field(default_factory=list)
    regs: list[int] = field(default_factory=list)  # x0..x31 at the end


class Soc:
    """The SoC as seen by software, with the cycle timing of the pipeline."""

    HALT_CAUSES = {"ecall": "halt_ecall", "ebreak": "halt_ebreak",
                   "illegal": "halt_illegal"}

    def __init__(self, image: list[int], *, rom_addr_bits: int = 12,
                 ram_addr_bits: int = 12, clks_per_bit: int = 8,
                 switches: int = 0x2A5, gpio_width: int = 10):
        rom_words = 1 << rom_addr_bits
        if len(image) > rom_words:
            raise ValueError(f"image of {len(image)} words exceeds the ROM")
        self.rom = list(image) + [0] * (rom_words - len(image))
        self.ram = [0] * (1 << ram_addr_bits)
        self.clks_per_bit = clks_per_bit
        self.gpio_mask = (1 << gpio_width) - 1
        self.switches = switches & self.gpio_mask

    def run(self, max_cycles: int = 2_000_000, trace: bool = False) -> RunResult:
        rom, ram = self.rom, self.ram
        rom_mask, ram_mask = len(rom) - 1, len(ram) - 1
        frame_cycles = 10 * self.clks_per_bit
        regs = [0] * 32
        decoded: dict[int, Decoded] = {}
        lines: list[str] = []
        uart = bytearray()

        pc = 0
        cycle = 1   # EX cycle of the current instruction
        count = 0   # instructions retired so far
        leds = 0
        crc = MASK32
        status = 0
        mtime_base, mtime_origin = 0, 0        # MTIME(c) = base + c - origin
        instret_base, instret_origin = 0, 0    # INSTRET(i) = base + i - origin
        uart_busy_until = 0                    # last cycle the UART is busy

        while True:
            if cycle + 2 > max_cycles:
                return RunResult("timeout", max_cycles, count, status, 0,
                                 leds, bytes(uart), lines, regs)

            word = rom[(pc >> 2) & rom_mask]
            d = decoded.get(word)
            if d is None:
                d = decoded[word] = decode(word)
            m = d.mnemonic

            if m in self.HALT_CAUSES:
                return self._halt(self.HALT_CAUSES[m], cycle, count, status,
                                  pc, leds, uart, lines, regs)

            rd_value = None
            next_pc = (pc + 4) & MASK32
            taken = False
            byte_enable = address = bus_word = 0
            report = False

            if m in ALU:
                rd_value = ALU[m](regs[d.rs1], regs[d.rs2])
            elif m in IMM_TO_ALU:
                rd_value = ALU[IMM_TO_ALU[m]](regs[d.rs1], d.imm & MASK32)
            elif m in BRANCH:
                if BRANCH[m](regs[d.rs1], regs[d.rs2]):
                    next_pc = (pc + d.imm) & MASK32
                    taken = True
            elif m in LOADS:
                address = (regs[d.rs1] + d.imm) & MASK32
                if is_misaligned(m, address):
                    return self._halt("halt_misaligned_load", cycle, count,
                                      status, pc, leds, uart, lines, regs)
                region = address >> 28
                index = address >> 2
                if region == REGION_ROM:
                    value = rom[index & rom_mask]
                elif region == REGION_RAM:
                    value = ram[index & ram_mask]
                elif region == REGION_MMIO:
                    index &= 0x3F
                    if index == UART_STATUS:
                        value = int(cycle <= uart_busy_until)
                    elif index == GPIO_OUT:
                        value = leds
                    elif index == GPIO_IN:
                        value = self.switches
                    elif index == MTIME:
                        value = (mtime_base + cycle - mtime_origin) & MASK32
                    elif index == INSTRET:
                        value = (instret_base + count - instret_origin) & MASK32
                    elif index == CRC_STATE:
                        value = crc
                    else:
                        value = 0
                else:
                    value = 0
                rd_value = load_value(m, value, address & 3)
            elif m in STORES:
                address = (regs[d.rs1] + d.imm) & MASK32
                if is_misaligned(m, address):
                    return self._halt("halt_misaligned_store", cycle, count,
                                      status, pc, leds, uart, lines, regs)
                byte_enable, bus_word = store_lanes(m, regs[d.rs2], address & 3)
                region = address >> 28
                if region == REGION_RAM:
                    index = (address >> 2) & ram_mask
                    old = ram[index]
                    for lane in range(4):
                        if byte_enable >> lane & 1:
                            mask = 0xFF << (8 * lane)
                            old = (old & ~mask) | (bus_word & mask)
                    ram[index] = old
                elif region == REGION_MMIO:
                    # Registers take the whole bus word, whatever the width.
                    index = (address >> 2) & 0x3F
                    if index == UART_DATA:
                        if cycle > uart_busy_until:  # writes while busy are dropped
                            uart.append(bus_word & 0xFF)
                            uart_busy_until = cycle + frame_cycles
                    elif index == GPIO_OUT:
                        leds = bus_word & self.gpio_mask
                    elif index == MTIME:
                        mtime_base, mtime_origin = bus_word, cycle + 1
                    elif index == INSTRET:
                        # The store itself is counted on top of the new value.
                        instret_base, instret_origin = bus_word, count
                    elif index == CRC_STATE:
                        crc = bus_word
                    elif index == CRC_DATA:
                        crc = crc32_update_byte(crc, bus_word)
                    elif index == TEST_STATUS:
                        status = bus_word
                        report = True
                # Stores to the ROM or to unmapped space are ignored.
            elif m in ("jal", "jalr"):
                if m == "jal":
                    target = (pc + d.imm) & MASK32
                else:
                    target = (regs[d.rs1] + d.imm) & MASK32 & ~1
                next_pc = target
                taken = True
                rd_value = (pc + 4) & MASK32
            elif m == "lui":
                rd_value = d.imm
            elif m == "auipc":
                rd_value = (pc + d.imm) & MASK32
            # fence: nothing to do, accesses are already in program order

            # Without the C extension, a taken jump or branch to an address
            # that is not word aligned faults; a not-taken one never does.
            if taken and next_pc & 2:
                return self._halt("halt_misaligned_fetch", cycle, count, status,
                                  pc, leds, uart, lines, regs)

            writes_rd = rd_value is not None and d.rd != 0
            if writes_rd:
                regs[d.rd] = rd_value
            if trace:
                lines.append(trace_line(pc, word, d.rd if writes_rd else 0,
                                        rd_value if writes_rd else 0,
                                        byte_enable, address, bus_word))
            count += 1

            if report:
                outcome = "pass" if status == TEST_PASS else "fail"
                return RunResult(outcome, cycle + 2, count, status, 0, leds,
                                 bytes(uart), lines, regs)

            cycle += 2 if taken else 1
            pc = next_pc

    @staticmethod
    def _halt(cause, cycle, count, status, pc, leds, uart, lines, regs) -> RunResult:
        # The halt becomes visible one cycle after the faulting instruction
        # was in EX; tb_soc samples it one edge later.
        return RunResult(cause, cycle + 2, count, status, pc, leds, bytes(uart),
                         lines, regs)


def read_hex(path: str | Path) -> list[int]:
    """Reads a memory image: one 32-bit hex word per line."""
    words = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            words.append(int(line, 16))
    return words


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", help="ROM image (.hex, one word per line)")
    parser.add_argument("--clks-per-bit", type=int, default=8)
    parser.add_argument("--switches", type=lambda s: int(s, 0), default=0x2A5)
    parser.add_argument("--max-cycles", type=int, default=2_000_000)
    parser.add_argument("--trace", metavar="FILE",
                        help="write the commit trace with disassembly to FILE")
    args = parser.parse_args()

    soc = Soc(read_hex(args.image), clks_per_bit=args.clks_per_bit,
              switches=args.switches)
    result = soc.run(args.max_cycles, trace=bool(args.trace))
    sys.stdout.write(result.uart.decode("ascii", errors="replace"))
    if args.trace:
        with open(args.trace, "w") as f:
            for line in result.trace:
                pc, word = int(line[:8], 16), int(line[9:17], 16)
                f.write(f"{line}  {disassemble(word, pc)}\n")
    print(f"result={result.outcome} cycles={result.cycles} "
          f"instret={result.instret} status={result.status:08X} "
          f"halt_pc={result.halt_pc:08X} leds={result.leds:03X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
