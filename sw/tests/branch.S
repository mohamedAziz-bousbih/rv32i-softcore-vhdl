/*
 * branch.S - BEQ, BNE, BLT, BGE, BLTU, BGEU.
 *
 * Every condition is checked taken and not taken, forward and backward,
 * with operand pairs on both sides of the signed/unsigned boundary.
 */

#include "test_macros.h"

TEST_BEGIN

/* Extreme offsets: +4092 forward and -4096 backward (the most negative
 * B-type offset). This case comes first because it spans 4 KiB and the
 * `bne ..., fail` of every later case must stay within branch reach of
 * `fail` at the end. The gap is zero-filled: zero is an illegal
 * instruction, so landing anywhere but on the target halts the core. */
test_1:
    li   TESTNUM, 1
    j    4f
5:  j    6f                 /* backward target, address B           */
4:  beq  x0, x0, 7f         /* at B + 4: offset +4092               */
    j    fail
    .skip 4084
7:  beq  x0, x0, 5b         /* at B + 4096: offset -4096            */
    j    fail
6:

/* BEQ */
TEST_BR_TAKEN(2, beq, 0, 0)
TEST_BR_TAKEN(3, beq, 1, 1)
TEST_BR_TAKEN(4, beq, -1, -1)
TEST_BR_TAKEN(5, beq, 0x80000000, 0x80000000)
TEST_BR_NOT_TAKEN(6, beq, 0, 1)
TEST_BR_NOT_TAKEN(7, beq, 1, 0)
TEST_BR_NOT_TAKEN(8, beq, -1, 1)
TEST_BR_NOT_TAKEN(9, beq, 0x80000000, 0)

/* BNE */
TEST_BR_TAKEN(10, bne, 0, 1)
TEST_BR_TAKEN(11, bne, 1, 0)
TEST_BR_TAKEN(12, bne, -1, 1)
TEST_BR_TAKEN(13, bne, 0x80000000, 0)
TEST_BR_NOT_TAKEN(14, bne, 0, 0)
TEST_BR_NOT_TAKEN(15, bne, 1, 1)
TEST_BR_NOT_TAKEN(16, bne, -1, -1)

/* BLT (signed) */
TEST_BR_TAKEN(17, blt, 0, 1)
TEST_BR_TAKEN(18, blt, -1, 1)
TEST_BR_TAKEN(19, blt, -2, -1)
TEST_BR_TAKEN(20, blt, 0x80000000, 0x7fffffff)
TEST_BR_NOT_TAKEN(21, blt, 1, 0)
TEST_BR_NOT_TAKEN(22, blt, 1, -1)
TEST_BR_NOT_TAKEN(23, blt, -1, -2)
TEST_BR_NOT_TAKEN(24, blt, 0x7fffffff, 0x80000000)
TEST_BR_NOT_TAKEN(25, blt, 5, 5)

/* BGE (signed) */
TEST_BR_TAKEN(26, bge, 0, 0)
TEST_BR_TAKEN(27, bge, 1, 0)
TEST_BR_TAKEN(28, bge, -1, -2)
TEST_BR_TAKEN(29, bge, 1, -1)
TEST_BR_TAKEN(30, bge, 0x7fffffff, 0x80000000)
TEST_BR_NOT_TAKEN(31, bge, 0, 1)
TEST_BR_NOT_TAKEN(32, bge, -1, 1)
TEST_BR_NOT_TAKEN(33, bge, -2, -1)
TEST_BR_NOT_TAKEN(34, bge, 0x80000000, 0x7fffffff)

/* BLTU (unsigned): -1 is the largest value */
TEST_BR_TAKEN(35, bltu, 0, 1)
TEST_BR_TAKEN(36, bltu, 0xfffffffe, 0xffffffff)
TEST_BR_TAKEN(37, bltu, 0, 0xffffffff)
TEST_BR_TAKEN(38, bltu, 0x7fffffff, 0x80000000)
TEST_BR_NOT_TAKEN(39, bltu, 1, 0)
TEST_BR_NOT_TAKEN(40, bltu, 0xffffffff, 0xfffffffe)
TEST_BR_NOT_TAKEN(41, bltu, 0xffffffff, 0)
TEST_BR_NOT_TAKEN(42, bltu, 0x80000000, 0x7fffffff)
TEST_BR_NOT_TAKEN(43, bltu, 5, 5)

/* BGEU (unsigned) */
TEST_BR_TAKEN(44, bgeu, 0, 0)
TEST_BR_TAKEN(45, bgeu, 1, 0)
TEST_BR_TAKEN(46, bgeu, 0xffffffff, 0xfffffffe)
TEST_BR_TAKEN(47, bgeu, 0xffffffff, 0)
TEST_BR_TAKEN(48, bgeu, 0x80000000, 0x7fffffff)
TEST_BR_NOT_TAKEN(49, bgeu, 0, 1)
TEST_BR_NOT_TAKEN(50, bgeu, 0xfffffffe, 0xffffffff)
TEST_BR_NOT_TAKEN(51, bgeu, 0, 0xffffffff)
TEST_BR_NOT_TAKEN(52, bgeu, 0x7fffffff, 0x80000000)

/* Both operands the same register. */
test_53:
    li   TESTNUM, 53
    li   x1, -5
    blt  x1, x1, fail
    bltu x1, x1, fail
    bne  x1, x1, fail
    bge  x1, x1, 4f
    j    fail
4:  bgeu x1, x1, 5f
    j    fail
5:  beq  x1, x1, 6f
    j    fail
6:

/* x0 as an operand: 0 > -1 signed, 0 < 0xFFFFFFFF unsigned. */
test_54:
    li   TESTNUM, 54
    li   x1, -1
    blt  x0, x1, fail
    bgeu x0, x1, fail
    bge  x0, x1, 4f
    j    fail
4:  bltu x0, x1, 5f
    j    fail
5:  bltu x1, x0, fail
    blt  x1, x0, 6f
    j    fail
6:

/* A branch whose target is only halfword aligned faults only if taken.
 * Encoded by hand: bne x0, x0, .+6 (never taken). */
test_55:
    li   TESTNUM, 55
    .word 0x00001363
    nop
    nop

TEST_END
