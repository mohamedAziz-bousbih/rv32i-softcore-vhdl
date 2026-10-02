/*
 * load.S - LB, LH, LW, LBU, LHU.
 *
 * The data lives in the ROM (read through its second port). Each byte of
 * the table is distinct, so a load from the wrong lane gives a wrong value,
 * and the signed loads see both a clear and a set sign bit in every lane.
 */

#include "test_macros.h"

TEST_BEGIN

/* LB: every byte lane, sign-extended. */
TEST_LD(1, lb, 0xffffff81, 0, tdat)
TEST_LD(2, lb, 0x00000002, 1, tdat)
TEST_LD(3, lb, 0x0000007f, 2, tdat)
TEST_LD(4, lb, 0xfffffff4, 3, tdat)
TEST_LD(5, lb, 0x00000000, 4, tdat)
TEST_LD(6, lb, 0xffffff80, 5, tdat)
TEST_LD(7, lb, 0xffffffff, 6, tdat)
TEST_LD(8, lb, 0x0000007f, 7, tdat)

/* LBU: zero-extended. */
TEST_LD(9, lbu, 0x00000081, 0, tdat)
TEST_LD(10, lbu, 0x00000002, 1, tdat)
TEST_LD(11, lbu, 0x0000007f, 2, tdat)
TEST_LD(12, lbu, 0x000000f4, 3, tdat)
TEST_LD(13, lbu, 0x00000080, 5, tdat)
TEST_LD(14, lbu, 0x000000ff, 6, tdat)

/* LH: both halfword lanes, sign-extended. */
TEST_LD(15, lh, 0x00000281, 0, tdat)
TEST_LD(16, lh, 0xfffff47f, 2, tdat)
TEST_LD(17, lh, 0xffff8000, 4, tdat)
TEST_LD(18, lh, 0x00007fff, 6, tdat)
TEST_LD(19, lh, 0xffffcdef, 8, tdat)
TEST_LD(20, lh, 0xffff89ab, 10, tdat)

/* LHU: zero-extended. */
TEST_LD(21, lhu, 0x00000281, 0, tdat)
TEST_LD(22, lhu, 0x0000f47f, 2, tdat)
TEST_LD(23, lhu, 0x00008000, 4, tdat)
TEST_LD(24, lhu, 0x00007fff, 6, tdat)
TEST_LD(25, lhu, 0x000089ab, 10, tdat)

/* LW */
TEST_LD(26, lw, 0xf47f0281, 0, tdat)
TEST_LD(27, lw, 0x7fff8000, 4, tdat)
TEST_LD(28, lw, 0x89abcdef, 8, tdat)
TEST_LD(29, lw, 0x01234567, 12, tdat)

/* Negative offsets from a base past the end of the table. */
TEST_LD(30, lw, 0xf47f0281, -12, tdat + 12)
TEST_LD(31, lb, 0xffffff80, -7, tdat + 12)
TEST_LD(32, lhu, 0x000089ab, -2, tdat + 12)
TEST_LD(33, lh, 0xffff8000, -8, tdat + 12)

/* The extremes of the 12-bit offset. */
TEST_LD(34, lw, 0x7fff8000, -2048, tdat + 2052)
TEST_LD(35, lw, 0x89abcdef, 2047, tdat - 2039)

/* A load to x0 is discarded (checked by the very next instruction). */
TEST_CASE(36, x14, 0, la x1, tdat; lw x0, 0(x1); or x14, x0, x0)

/* Destination == base register. */
TEST_CASE(37, x1, 0x01234567, la x1, tdat + 12; lw x1, 0(x1))

/* Load followed directly by a dependent instruction: the value is
 * forwarded from write-back, both into rs1 and into rs2. */
TEST_CASE(38, x14, 0x7fff8001, la x1, tdat; lw x5, 4(x1); addi x14, x5, 1)
TEST_CASE(39, x14, 0x7fff8001, la x1, tdat; li x6, 1; lw x5, 4(x1); add x14, x6, x5)

/* Code is readable as data through the ROM's second port. */
TEST_CASE(40, x14, 0x00000013, la x1, nop_insn; lw x14, 0(x1))
nop_insn:
    nop

TEST_END

    .section .rodata
    .balign 4
tdat:
    .byte 0x81, 0x02, 0x7f, 0xf4    /* 0xf47f0281 */
    .byte 0x00, 0x80, 0xff, 0x7f    /* 0x7fff8000 */
    .word 0x89abcdef
    .word 0x01234567
