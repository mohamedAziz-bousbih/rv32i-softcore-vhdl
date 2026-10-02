/*
 * arith.S - ADD, SUB, ADDI.
 *
 * Signed overflow must wrap silently (RV32I has no overflow trap), the
 * 12-bit immediate is sign-extended (-2048 .. 2047), and every operand
 * position is checked with x0 and with source == destination.
 */

#include "test_macros.h"

TEST_BEGIN

/* ADD */
TEST_RR(1, add, 0x00000000, 0x00000000, 0x00000000)
TEST_RR(2, add, 0x00000002, 0x00000001, 0x00000001)
TEST_RR(3, add, 0x0000000a, 0x00000003, 0x00000007)
TEST_RR(4, add, 0xffff8000, 0x00000000, 0xffff8000)
TEST_RR(5, add, 0x80000000, 0x80000000, 0x00000000)
TEST_RR(6, add, 0x7fff8000, 0x80000000, 0xffff8000)
TEST_RR(7, add, 0x00007fff, 0x00000000, 0x00007fff)
TEST_RR(8, add, 0x7fffffff, 0x7fffffff, 0x00000000)
TEST_RR(9, add, 0x80007ffe, 0x7fffffff, 0x00007fff)
TEST_RR(10, add, 0x80007fff, 0x80000000, 0x00007fff)
TEST_RR(11, add, 0x7fff7fff, 0x7fffffff, 0xffff8000)
TEST_RR(12, add, 0xffffffff, 0x00000000, 0xffffffff)
TEST_RR(13, add, 0x00000000, 0xffffffff, 0x00000001)
TEST_RR(14, add, 0xfffffffe, 0xffffffff, 0xffffffff)
TEST_RR(15, add, 0x80000000, 0x7fffffff, 0x00000001)
TEST_RR_SRC1_EQ_DEST(16, add, 0x00000018, 0x0000000d, 0x0000000b)
TEST_RR_SRC2_EQ_DEST(17, add, 0x00000018, 0x0000000d, 0x0000000b)
TEST_RR_SRC12_EQ_DEST(18, add, 0x0000001a, 0x0000000d)
TEST_RR_ZERO_SRC1(19, add, 0x0000000b, 0x0000000b)
TEST_RR_ZERO_SRC2(20, add, 0x0000000d, 0x0000000d)
TEST_RR_ZERO_DEST(21, add, 0x0000000d, 0x0000000b)
/* SUB */
TEST_RR(22, sub, 0x00000000, 0x00000000, 0x00000000)
TEST_RR(23, sub, 0x00000000, 0x00000001, 0x00000001)
TEST_RR(24, sub, 0xfffffffc, 0x00000003, 0x00000007)
TEST_RR(25, sub, 0x00008000, 0x00000000, 0xffff8000)
TEST_RR(26, sub, 0x80000000, 0x80000000, 0x00000000)
TEST_RR(27, sub, 0x80008000, 0x80000000, 0xffff8000)
TEST_RR(28, sub, 0xffff8001, 0x00000000, 0x00007fff)
TEST_RR(29, sub, 0x7fffffff, 0x7fffffff, 0x00000000)
TEST_RR(30, sub, 0x7fff8000, 0x7fffffff, 0x00007fff)
TEST_RR(31, sub, 0x7fff8001, 0x80000000, 0x00007fff)
TEST_RR(32, sub, 0x80007fff, 0x7fffffff, 0xffff8000)
TEST_RR(33, sub, 0x00000001, 0x00000000, 0xffffffff)
TEST_RR(34, sub, 0xfffffffe, 0xffffffff, 0x00000001)
TEST_RR(35, sub, 0x00000000, 0xffffffff, 0xffffffff)
TEST_RR(36, sub, 0x7ffffffe, 0x7fffffff, 0x00000001)
TEST_RR_SRC1_EQ_DEST(37, sub, 0x00000002, 0x0000000d, 0x0000000b)
TEST_RR_SRC2_EQ_DEST(38, sub, 0x00000002, 0x0000000d, 0x0000000b)
TEST_RR_SRC12_EQ_DEST(39, sub, 0x00000000, 0x0000000d)
TEST_RR_ZERO_SRC1(40, sub, 0xfffffff5, 0x0000000b)
TEST_RR_ZERO_SRC2(41, sub, 0x0000000d, 0x0000000d)
TEST_RR_ZERO_DEST(42, sub, 0x0000000d, 0x0000000b)
/* ADDI */
TEST_RI(43, addi, 0x00000000, 0x00000000, 0)
TEST_RI(44, addi, 0x00000002, 0x00000001, 1)
TEST_RI(45, addi, 0x0000000a, 0x00000003, 7)
TEST_RI(46, addi, 0xfffff800, 0x00000000, -2048)
TEST_RI(47, addi, 0x80000000, 0x80000000, 0)
TEST_RI(48, addi, 0x7ffff800, 0x80000000, -2048)
TEST_RI(49, addi, 0x000007ff, 0x00000000, 2047)
TEST_RI(50, addi, 0x7fffffff, 0x7fffffff, 0)
TEST_RI(51, addi, 0x800007fe, 0x7fffffff, 2047)
TEST_RI(52, addi, 0x800007ff, 0x80000000, 2047)
TEST_RI(53, addi, 0x7ffff7ff, 0x7fffffff, -2048)
TEST_RI(54, addi, 0xffffffff, 0x00000000, -1)
TEST_RI(55, addi, 0x00000000, 0xffffffff, 1)
TEST_RI(56, addi, 0xfffffffe, 0xffffffff, -1)
TEST_RI(57, addi, 0x80000000, 0x7fffffff, 1)
TEST_RI_SRC1_EQ_DEST(58, addi, 0x00000018, 0x0000000d, 11)
TEST_RI_ZERO_DEST(59, addi, 0x0000000d, 11)

TEST_END
