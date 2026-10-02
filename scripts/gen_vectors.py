#!/usr/bin/env python3
"""Generates golden vectors for tb/tb_core_vectors.vhd from the reference model.

Each line is one check; fields are hexadecimal:

  D word cause rd_we imm imm_mask    decode(): cause 0 none, 1 ECALL, 2 EBREAK,
                                     3 illegal; rd_we F = don't care
  A op a b y                         rv32i_alu, op = {instr[30], funct3}
  B funct3 a b taken                 branch_taken()
  L funct3 offset word result mis    load_extend(), is_misaligned()
  S funct3 offset data be lanes mis  store_byte_enable(), store_lanes(),
                                     is_misaligned()

The expected values come from scripts/rv32i_iss.py, which was written from
the ISA specification independently of the VHDL. The seed is fixed, so the
file is reproducible.
"""

from __future__ import annotations

import argparse
import random
import sys
from itertools import product
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rv32i_iss as iss  # noqa: E402

MASK32 = 0xFFFF_FFFF

EDGE_VALUES = [
    0x0000_0000, 0x0000_0001, 0x0000_0002, 0x0000_0003, 0x0000_001F,
    0x0000_0020, 0x0000_0021, 0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000,
    0x8000_0001, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x5555_5555, 0xAAAA_AAAA,
    0x1234_5678, 0xFEDC_BA98,
]

# ALU operation codes of rv32i_pkg ({instr[30], funct3}).
ALU_OPS = {"add": 0x0, "sub": 0x8, "sll": 0x1, "slt": 0x2, "sltu": 0x3,
           "xor": 0x4, "srl": 0x5, "sra": 0xD, "or": 0x6, "and": 0x7}

BRANCH_F3 = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
LOAD_F3 = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORE_F3 = {"sb": 0, "sh": 1, "sw": 2}

WRITES_RD = ({"lui", "auipc", "jal", "jalr"} | iss.LOADS | set(iss.ALU)
             | set(iss.IMM_TO_ALU))
SHIFT_IMM = {"slli", "srli", "srai"}
NO_IMM = set(iss.ALU) | {"fence", "ecall", "ebreak", "illegal"}

# SYSTEM, MISC-MEM and extension encodings that must be rejected, plus the
# few that must not.
SPECIAL_WORDS = [
    0x0000_0073,  # ecall
    0x0010_0073,  # ebreak
    0x0000_0000,  # all zero: defined illegal
    0xFFFF_FFFF,  # all ones: defined illegal
    0x0000_00F3,  # ecall with rd != 0
    0x0008_0073,  # ecall with rs1 != 0
    0x0020_0073,  # uret
    0x1020_0073,  # sret
    0x3020_0073,  # mret
    0x1050_0073,  # wfi
    0xB000_22F3,  # csrrs x5, mcycle, x0 (Zicsr)
    0x3400_9073,  # csrrw x0, mscratch, x1
    0x0000_100F,  # fence.i (Zifencei)
    0x0FF0_000F,  # fence iorw, iorw
    0x8330_000F,  # fence.tso
    0x0100_000F,  # pause
    0x0FF0_870F,  # fence with rd and rs1 set (fields ignored)
    0x0220_8733,  # mul (M)
    0x0220_C733,  # div (M)
    0x1000_272F,  # lr.w (A)
    0x0000_4501,  # c.li a0, 0 in the low half (C)
    0x0000_0013,  # nop
]


def cause_code(mnemonic: str) -> int:
    return {"ecall": 1, "ebreak": 2, "illegal": 3}.get(mnemonic, 0)


def decode_line(word: int) -> str:
    d = iss.decode(word)
    m = d.mnemonic
    if m in ("ecall", "ebreak", "illegal"):
        rd_we = "F"
    else:
        rd_we = "1" if m in WRITES_RD and d.rd != 0 else "0"
    if m in NO_IMM:
        imm, mask = 0, 0
    elif m in SHIFT_IMM:
        imm, mask = d.imm, 0x1F
    else:
        imm, mask = d.imm & MASK32, MASK32
    return f"D {word:08X} {cause_code(m):X} {rd_we} {imm:08X} {mask:08X}"


def decode_words(rng: random.Random) -> list[int]:
    words = list(SPECIAL_WORDS)
    # Every major opcode with every funct3 and the interesting funct7s,
    # register fields random.
    for opcode, f3, f7 in product(range(128), range(8), (0x00, 0x20, 0x01, 0x7F)):
        fields = rng.getrandbits(32) & 0x01FF_8F80  # rs2, rs1, rd
        words.append((f7 << 25) | fields | (f3 << 12) | opcode)
    words += [rng.getrandbits(32) for _ in range(20000)]
    return words


def operand_pairs(rng: random.Random, n_random: int) -> list[tuple[int, int]]:
    pairs = list(product(EDGE_VALUES, repeat=2))
    pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(n_random)]
    # Equal operands with random values, for the comparisons.
    pairs += [(v, v) for v in (rng.getrandbits(32) for _ in range(16))]
    return pairs


def generate(seed: int = 2021) -> list[str]:
    rng = random.Random(seed)
    lines = [decode_line(w) for w in decode_words(rng)]

    for name, op in ALU_OPS.items():
        for a, b in operand_pairs(rng, 300):
            lines.append(f"A {op:X} {a:08X} {b:08X} {iss.ALU[name](a, b):08X}")

    for name, f3 in BRANCH_F3.items():
        for a, b in operand_pairs(rng, 200):
            lines.append(f"B {f3:X} {a:08X} {b:08X} {int(iss.BRANCH[name](a, b)):X}")

    data_words = EDGE_VALUES + [rng.getrandbits(32) for _ in range(24)]
    for (name, f3), offset, word in product(LOAD_F3.items(), range(4), data_words):
        mis = iss.is_misaligned(name, offset)
        result = 0 if mis else iss.load_value(name, word, offset)
        lines.append(f"L {f3:X} {offset:X} {word:08X} {result:08X} {int(mis):X}")

    for (name, f3), offset, data in product(STORE_F3.items(), range(4), data_words):
        mis = iss.is_misaligned(name, offset)
        be, lanes = iss.store_lanes(name, data, offset)
        lines.append(f"S {f3:X} {offset:X} {data:08X} {be:X} {lanes:08X} {int(mis):X}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=int, default=2021)
    args = parser.parse_args()
    lines = generate(args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", newline="\n")
    print(f"gen_vectors: {len(lines)} vectors -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
