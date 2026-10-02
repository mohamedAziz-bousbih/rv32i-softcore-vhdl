"""Unit tests of the reference model (scripts/rv32i_iss.py).

The RTL is compared against this model, so the model itself is pinned down
here: decoding against encodings produced by an assembler, the arithmetic
corner cases of the specification, and the cycle model on tiny programs.
"""

import pytest

import rv32i_iss as iss

MMIO = 0x2000_0000
RAM = 0x1000_0000


# Instruction encoders, written from the format tables of the ISA manual.
def enc_r(f7, rs2, rs1, f3, rd, opcode=0x33):
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opcode


def enc_i(imm, rs1, f3, rd, opcode=0x13):
    return (imm & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | opcode


def enc_s(imm, rs2, rs1, f3):
    imm &= 0xFFF
    return (imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 0x1F) << 7 | 0x23


def enc_b(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return ((imm >> 12 & 1) << 31 | (imm >> 5 & 0x3F) << 25 | rs2 << 20 | rs1 << 15
            | f3 << 12 | (imm >> 1 & 0xF) << 8 | (imm >> 11 & 1) << 7 | 0x63)


def enc_u(imm20, rd, opcode=0x37):
    return imm20 << 12 | rd << 7 | opcode


def enc_j(imm, rd):
    imm &= 0x1F_FFFF
    return ((imm >> 20 & 1) << 31 | (imm >> 1 & 0x3FF) << 21 | (imm >> 11 & 1) << 20
            | (imm >> 12 & 0xFF) << 12 | rd << 7 | 0x6F)


def addi(rd, rs1, imm):
    return enc_i(imm, rs1, 0, rd)


def lui(rd, imm20):
    return enc_u(imm20, rd)


def lw(rd, rs1, imm):
    return enc_i(imm, rs1, 2, rd, 0x03)


def sw(rs2, rs1, imm):
    return enc_s(imm, rs2, rs1, 2)


def sub(rd, rs1, rs2):
    return enc_r(0x20, rs2, rs1, 0, rd)


ECALL = 0x0000_0073

# Words produced by the LLVM assembler (zig cc) for the given source lines.
ASSEMBLED = [
    (0x00000013, "addi", 0, 0, 0, 0),           # addi x0, x0, 0
    (0xFFF00093, "addi", 1, 0, 0, -1),          # addi x1, x0, -1
    (0x800000B7, "lui", 1, 0, 0, 0x8000_0000),  # lui x1, 0x80000
    (0x12345297, "auipc", 5, 0, 0, 0x1234_5000),
    (0xFFDFF0EF, "jal", 1, 0, 0, -4),           # jal x1, . - 4
    (0x00B550E3, "bge", 0, 10, 11, 2048),       # bge x10, x11, . + 2048
    (0xFF8280E7, "jalr", 1, 5, 0, -8),          # jalr x1, -8(x5)
    (0xFFF10703, "lb", 14, 2, 0, -1),           # lb x14, -1(x2)
    (0x7FFFD783, "lhu", 15, 31, 0, 2047),       # lhu x15, 2047(x31)
    (0x80742023, "sw", 0, 8, 7, -2048),         # sw x7, -2048(x8)
    (0x41F55493, "srai", 9, 10, 0, 31),         # srai x9, x10, 31
    (0x40E6D633, "sra", 12, 13, 14, 0),         # sra x12, x13, x14
    (0x40E68633, "sub", 12, 13, 14, 0),         # sub x12, x13, x14
    (0xFFF8B813, "sltiu", 16, 17, 0, -1),       # sltiu x16, x17, -1
    (0x0330000F, "fence", 0, 0, 0, 0),          # fence rw, rw
    (0x00000073, "ecall", 0, 0, 0, 0),
    (0x00100073, "ebreak", 0, 0, 0, 0),
]


@pytest.mark.parametrize("word, mnemonic, rd, rs1, rs2, imm", ASSEMBLED)
def test_decode_matches_assembler(word, mnemonic, rd, rs1, rs2, imm):
    assert iss.decode(word) == iss.Decoded(mnemonic, rd, rs1, rs2, imm)


def test_encoders_match_assembler():
    assert addi(1, 0, -1) == 0xFFF00093
    assert lui(1, 0x80000) == 0x800000B7
    assert enc_j(-4, 1) == 0xFFDFF0EF
    assert enc_b(2048, 11, 10, 5) == 0x00B550E3
    assert enc_s(-2048, 7, 8, 2) == 0x80742023
    assert enc_r(0x20, 14, 13, 5, 12) == 0x40E6D633


@pytest.mark.parametrize("word", [
    0x0000_0000,             # defined illegal
    0xFFFF_FFFF,
    0x0220_8733,             # mul (M extension)
    0x0000_100F,             # fence.i (Zifencei)
    0xB000_22F3,             # csrrs (Zicsr)
    0x3020_0073,             # mret
    0x0000_00F3,             # ecall with rd != 0
    0x0000_4501,             # compressed encoding
    enc_r(0x20, 1, 2, 1, 3),  # "sll" with funct7 0100000
    enc_i(0x400 | 3, 2, 1, 3),  # slli with shamt[5] set (RV64 only)
    enc_b(8, 1, 2, 2),       # branch funct3 010 is reserved
    enc_i(0, 1, 3, 2, 0x03),  # load funct3 011 (LD, RV64 only)
    enc_s(0, 1, 2, 3),       # store funct3 011 (SD, RV64 only)
    enc_i(0, 1, 1, 2, 0x67),  # jalr with funct3 != 0
])
def test_decode_rejects_non_rv32i(word):
    assert iss.decode(word).mnemonic == "illegal"


def test_fence_ignores_reserved_fields():
    # rd = x14, rs1 = x1, fm = 1000 (fence.tso): still a FENCE.
    assert iss.decode(0x0FF0870F).mnemonic == "fence"
    assert iss.decode(0x8330000F).mnemonic == "fence"


@pytest.mark.parametrize("op, a, b, expected", [
    ("add", 0x7FFF_FFFF, 1, 0x8000_0000),        # overflow wraps
    ("sub", 0, 1, 0xFFFF_FFFF),
    ("sll", 1, 33, 2),                           # shamt is b[4:0]
    ("srl", 0x8000_0000, 31, 1),
    ("sra", 0x8000_0000, 31, 0xFFFF_FFFF),
    ("sra", 0x7FFF_FFFF, 0xFFFF_FFFF, 0),        # shift by 31
    ("slt", 0xFFFF_FFFF, 1, 1),                  # -1 < 1
    ("sltu", 0xFFFF_FFFF, 1, 0),
    ("slt", 0x8000_0000, 0x7FFF_FFFF, 1),
    ("sltu", 0x8000_0000, 0x7FFF_FFFF, 0),
])
def test_alu_corner_cases(op, a, b, expected):
    assert iss.ALU[op](a, b) == expected


def test_load_extension_and_store_lanes():
    word = 0x8001_7F80
    assert iss.load_value("lb", word, 0) == 0xFFFF_FF80
    assert iss.load_value("lbu", word, 0) == 0x80
    assert iss.load_value("lb", word, 1) == 0x7F
    assert iss.load_value("lh", word, 2) == 0xFFFF_8001
    assert iss.load_value("lhu", word, 2) == 0x8001
    assert iss.store_lanes("sb", 0x1234_56AB, 3) == (0b1000, 0xABAB_ABAB)
    assert iss.store_lanes("sh", 0x1234_56AB, 2) == (0b1100, 0x56AB_56AB)
    assert iss.is_misaligned("lh", 3) and iss.is_misaligned("sw", 2)
    assert not iss.is_misaligned("lbu", 3) and not iss.is_misaligned("sh", 2)


def test_crc32_matches_zlib():
    import zlib
    crc = 0xFFFF_FFFF
    for byte in b"123456789":
        crc = iss.crc32_update_byte(crc, byte)
    assert crc ^ 0xFFFF_FFFF == zlib.crc32(b"123456789") == 0xCBF4_3926


def report_status(value_reg):
    """lui x5, MMIO; sw value_reg, TEST_STATUS(x5)."""
    return [lui(5, MMIO >> 12), sw(value_reg, 5, 0x40)]


def run(program, **kw):
    return iss.Soc(program).run(trace=True, **kw)


def test_straight_line_program_timing():
    # Instruction i is in EX in cycle i + 1; the testbench sees the status
    # write two cycles after the store's EX cycle.
    r = run([addi(6, 0, 1), *report_status(6)])
    assert (r.outcome, r.status, r.instret, r.cycles) == ("pass", 1, 3, 5)


def test_taken_branch_costs_one_bubble():
    program = [enc_b(8, 0, 0, 0), 0, addi(6, 0, 1), *report_status(6)]
    r = run(program)
    assert (r.outcome, r.instret, r.cycles) == ("pass", 4, 7)
    assert [line.split()[0] for line in r.trace] == ["00000000", "00000008",
                                                    "0000000C", "00000010"]


def test_mtime_reads_track_ex_cycles():
    # Two back-to-back MTIME loads differ by exactly one cycle.
    program = [lui(5, MMIO >> 12), lw(6, 5, 0x20), lw(7, 5, 0x20), sub(8, 7, 6),
               sw(8, 5, 0x40)]
    assert run(program).outcome == "pass"


def test_uart_drops_writes_while_busy():
    program = [lui(5, MMIO >> 12), addi(6, 0, ord("A")), sw(6, 5, 0x00),
               addi(6, 0, ord("B")), sw(6, 5, 0x00), lw(7, 5, 0x04), sw(7, 5, 0x40)]
    r = run(program)
    assert r.uart == b"A"
    assert r.status == 1          # busy flag was set when read


def test_ecall_halts_precisely():
    program = [addi(6, 0, 7), ECALL, addi(6, 0, 9)]
    r = run(program)
    assert (r.outcome, r.halt_pc, r.instret, r.cycles) == ("halt_ecall", 4, 1, 4)
    assert len(r.trace) == 1


def test_misaligned_load_halts_without_writing():
    program = [lui(5, RAM >> 12), lw(6, 5, 2)]
    r = run(program)
    assert (r.outcome, r.halt_pc, r.instret) == ("halt_misaligned_load", 4, 1)


def test_taken_jump_to_halfword_address_halts():
    r = run([enc_j(6, 1)])
    assert (r.outcome, r.halt_pc, r.instret) == ("halt_misaligned_fetch", 0, 0)


def test_x0_stays_zero():
    program = [addi(0, 0, 5), lui(5, MMIO >> 12), sw(0, 5, 0x40)]
    r = run(program)
    assert r.outcome == "fail" and r.status == 0


def test_byte_store_merges_into_ram_word():
    program = [lui(5, RAM >> 12), addi(6, 0, -1), sw(6, 5, 0),
               enc_s(1, 0, 5, 0),                     # sb x0, 1(x5)
               lw(7, 5, 0), lui(8, 0xFFFF0), addi(8, 8, 0xFF),  # 0xFFFF00FF
               sub(9, 7, 8), addi(9, 9, 1),           # 1 if equal
               *report_status(9)]
    assert run(program).outcome == "pass"


def test_store_to_rom_is_ignored():
    program = [sw(0, 0, 0), lw(10, 0, 0), ECALL]  # overwrite word 0, read it
    r = run(program)
    pc, word, rd, value = r.trace[1].split()[:4]
    assert (rd, int(value, 16)) == ("0A", program[0])


def test_timeout():
    r = run([enc_j(0, 0)], max_cycles=100)
    assert r.outcome == "timeout"
