/*
 * upper.S - LUI and AUIPC.
 *
 * LUI places a 20-bit immediate in bits [31:12] and clears the rest; it
 * pairs with ADDI, whose sign-extended low part forces the usual "+1 on the
 * upper half" adjustment. AUIPC adds the same shifted immediate to its own
 * PC. The expected AUIPC results come from link-time addresses loaded with
 * LUI/ADDI (LA_ABS), so they do not depend on AUIPC itself.
 */

#include "test_macros.h"

TEST_BEGIN

/* LUI */
TEST_CASE(1, x14, 0x00000000, lui x14, 0)
TEST_CASE(2, x14, 0xfffff000, lui x14, 0xfffff)
TEST_CASE(3, x14, 0x80000000, lui x14, 0x80000)
TEST_CASE(4, x14, 0x7ffff000, lui x14, 0x7ffff)
/* The low 12 bits are cleared, not kept. */
TEST_CASE(5, x14, 0x12345000, li x14, -1; lui x14, 0x12345)
/* li-style pairs: ADDI's negative low part needs upper + 1. */
TEST_CASE(6, x14, 0x12345678, lui x14, 0x12345; addi x14, x14, 0x678)
TEST_CASE(7, x14, 0x12345abc, lui x14, 0x12346; addi x14, x14, -0x544)
TEST_CASE(8, x14, 0x7fffffff, lui x14, 0x80000; addi x14, x14, -1)
/* LUI to x0 is discarded. */
TEST_CASE(9, x14, 0, lui x0, 0x12345; or x14, x0, x0)

/* AUIPC with offset 0 yields its own address. */
test_10:
    li   TESTNUM, 10
auipc_10:
    auipc x14, 0
    LA_ABS(x29, auipc_10)
    bne  x14, x29, fail

/* Positive offset. */
test_11:
    li   TESTNUM, 11
auipc_11:
    auipc x14, 0x12345
    LA_ABS(x29, auipc_11)
    li   x28, 0x12345000
    add  x29, x29, x28
    bne  x14, x29, fail

/* Negative offset: the code sits below 0x1000, so the sum wraps around. */
test_12:
    li   TESTNUM, 12
auipc_12:
    auipc x14, 0xfffff
    LA_ABS(x29, auipc_12)
    li   x28, 0xfffff000
    add  x29, x29, x28
    bne  x14, x29, fail

/* Two AUIPCs one instruction apart differ by exactly 4. */
TEST_CASE(13, x14, 4, auipc x5, 0; auipc x6, 0; sub x14, x6, x5)

/* AUIPC to x0 is discarded. */
TEST_CASE(14, x14, 0, auipc x0, 0x12345; or x14, x0, x0)

TEST_END
