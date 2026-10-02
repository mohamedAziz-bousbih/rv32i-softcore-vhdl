/*
 * test_macros.h - self-checking test framework for the assembly tests.
 *
 * Every test case first loads its number into TESTNUM (x3). The first
 * failing comparison branches to `fail`, which reports (TESTNUM << 1) | 1 to
 * the TEST_STATUS register; falling off the last case reports 1 (pass).
 * This is the encoding riscv-tests uses for its tohost word, so a failing
 * case can be identified from the status value alone. Test numbers start
 * at 1 so that a failure can never look like a pass.
 *
 * Register conventions: x1/x2 are operands, x14 is the result under test,
 * x29 holds the expected value. Local labels 1..3 are reused by the macros,
 * tests use labels 4 and up.
 *
 * Source annotations read by scripts/run_tests.py (anywhere in a comment):
 *   @expect <outcome>   pass (default), or a halt cause such as halt_ecall
 *   @leds <value>       LED register value required at the end of the run
 */
#ifndef TEST_MACROS_H
#define TEST_MACROS_H

#include "soc_map.h"

#define TESTNUM x3

#define TEST_BEGIN          \
    .section .text.init;    \
    .globl _start;          \
_start:                     \
    li   TESTNUM, 0

#define TEST_END                    \
pass:                               \
    li   t0, TEST_PASS;             \
    j    1f;                        \
fail:                               \
    slli t0, TESTNUM, 1;            \
    ori  t0, t0, 1;                 \
1:  li   t1, MMIO_BASE;             \
    sw   t0, TEST_STATUS_OFF(t1);   \
2:  j    2b

/* Runs `code`, then requires `reg` == expected. */
#define TEST_CASE(n, reg, expected, ...)    \
test_##n:                                   \
    li   TESTNUM, n;                        \
    __VA_ARGS__;                            \
    li   x29, expected;                     \
    bne  reg, x29, fail

/* ---- register-register and register-immediate operations ---- */

#define TEST_RR(n, inst, expected, v1, v2) \
    TEST_CASE(n, x14, expected, li x1, v1; li x2, v2; inst x14, x1, x2)

#define TEST_RR_SRC1_EQ_DEST(n, inst, expected, v1, v2) \
    TEST_CASE(n, x1, expected, li x1, v1; li x2, v2; inst x1, x1, x2)

#define TEST_RR_SRC2_EQ_DEST(n, inst, expected, v1, v2) \
    TEST_CASE(n, x2, expected, li x1, v1; li x2, v2; inst x2, x1, x2)

#define TEST_RR_SRC12_EQ_DEST(n, inst, expected, v1) \
    TEST_CASE(n, x1, expected, li x1, v1; inst x1, x1, x1)

/* A write to x0 must be discarded, and must not be forwarded either: the
 * instruction right behind it reads x0 while the write is in write-back. */
#define TEST_RR_ZERO_DEST(n, inst, v1, v2) \
    TEST_CASE(n, x14, 0, li x1, v1; li x2, v2; inst x0, x1, x2; or x14, x0, x0)

#define TEST_RR_ZERO_SRC1(n, inst, expected, v2) \
    TEST_CASE(n, x14, expected, li x2, v2; inst x14, x0, x2)

#define TEST_RR_ZERO_SRC2(n, inst, expected, v1) \
    TEST_CASE(n, x14, expected, li x1, v1; inst x14, x1, x0)

#define TEST_RI(n, inst, expected, v1, imm) \
    TEST_CASE(n, x14, expected, li x1, v1; inst x14, x1, imm)

#define TEST_RI_SRC1_EQ_DEST(n, inst, expected, v1, imm) \
    TEST_CASE(n, x1, expected, li x1, v1; inst x1, x1, imm)

#define TEST_RI_ZERO_DEST(n, inst, v1, imm) \
    TEST_CASE(n, x14, 0, li x1, v1; inst x0, x1, imm; or x14, x0, x0)

/* ---- loads and stores ---- */

/* `base` is a symbol (data in the ROM). */
#define TEST_LD(n, inst, expected, offset, base) \
    TEST_CASE(n, x14, expected, la x1, base; inst x14, offset(x1))

/* `base` is an address constant (RAM; the tests run without crt0, so
 * they have no initialised .data and address the RAM directly). The load
 * directly follows the store to the same address. */
#define TEST_ST_LD(n, st, ld, expected, value, offset, base) \
    TEST_CASE(n, x14, expected, li x1, base; li x2, value; st x2, offset(x1); ld x14, offset(x1))

/* ---- branches ----
 * A taken case branches forward over a trap, then backward to a second
 * copy of the branch, so both offset signs are exercised. A not-taken case
 * must fall through both a forward and a backward branch. */

#define TEST_BR_TAKEN(n, inst, v1, v2)  \
test_##n:                               \
    li   TESTNUM, n;                    \
    li   x1, v1;                        \
    li   x2, v2;                        \
    inst x1, x2, 2f;                    \
    bne  x0, TESTNUM, fail;             \
1:  bne  x0, TESTNUM, 3f;               \
2:  inst x1, x2, 1b;                    \
    bne  x0, TESTNUM, fail;             \
3:

#define TEST_BR_NOT_TAKEN(n, inst, v1, v2) \
test_##n:                                  \
    li   TESTNUM, n;                       \
    li   x1, v1;                           \
    li   x2, v2;                           \
    inst x1, x2, 1f;                       \
    bne  x0, TESTNUM, 2f;                  \
1:  bne  x0, TESTNUM, fail;                \
2:  inst x1, x2, 1b;                       \
3:

/* Loads the link-time address of `label` without AUIPC, so that AUIPC, JAL
 * and JALR results can be checked against an independent computation. */
#define LA_ABS(reg, label)          \
    lui  reg, %hi(label);           \
    addi reg, reg, %lo(label)

#endif
