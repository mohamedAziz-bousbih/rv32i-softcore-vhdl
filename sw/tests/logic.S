/*
 * logic.S - AND, OR, XOR, ANDI, ORI, XORI.
 *
 * Negative immediates are sign-extended before the operation, so
 * "xori rd, rs, -1" is the NOT idiom and "andi rd, rs, -241" keeps the
 * upper 24 bits.
 */

#include "test_macros.h"

TEST_BEGIN

/* AND */
TEST_RR(1, and, 0x0f000f00, 0xff00ff00, 0x0f0f0f0f)
TEST_RR(2, and, 0x00f000f0, 0x0ff00ff0, 0xf0f0f0f0)
TEST_RR(3, and, 0x000f000f, 0x00ff00ff, 0x0f0f0f0f)
TEST_RR(4, and, 0xf000f000, 0xf00ff00f, 0xf0f0f0f0)
TEST_RR(5, and, 0x12345678, 0x12345678, 0xffffffff)
TEST_RR(6, and, 0x00000000, 0x12345678, 0x00000000)
TEST_RR_SRC1_EQ_DEST(7, and, 0x0f000f00, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC2_EQ_DEST(8, and, 0x0f000f00, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC12_EQ_DEST(9, and, 0xff00ff00, 0xff00ff00)
TEST_RR_ZERO_SRC1(10, and, 0x00000000, 0x0f0f0f0f)
TEST_RR_ZERO_SRC2(11, and, 0x00000000, 0xff00ff00)
TEST_RR_ZERO_DEST(12, and, 0xff00ff00, 0x0f0f0f0f)
/* OR */
TEST_RR(13, or, 0xff0fff0f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR(14, or, 0xfff0fff0, 0x0ff00ff0, 0xf0f0f0f0)
TEST_RR(15, or, 0x0fff0fff, 0x00ff00ff, 0x0f0f0f0f)
TEST_RR(16, or, 0xf0fff0ff, 0xf00ff00f, 0xf0f0f0f0)
TEST_RR(17, or, 0xffffffff, 0x12345678, 0xffffffff)
TEST_RR(18, or, 0x12345678, 0x12345678, 0x00000000)
TEST_RR_SRC1_EQ_DEST(19, or, 0xff0fff0f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC2_EQ_DEST(20, or, 0xff0fff0f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC12_EQ_DEST(21, or, 0xff00ff00, 0xff00ff00)
TEST_RR_ZERO_SRC1(22, or, 0x0f0f0f0f, 0x0f0f0f0f)
TEST_RR_ZERO_SRC2(23, or, 0xff00ff00, 0xff00ff00)
TEST_RR_ZERO_DEST(24, or, 0xff00ff00, 0x0f0f0f0f)
/* XOR */
TEST_RR(25, xor, 0xf00ff00f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR(26, xor, 0xff00ff00, 0x0ff00ff0, 0xf0f0f0f0)
TEST_RR(27, xor, 0x0ff00ff0, 0x00ff00ff, 0x0f0f0f0f)
TEST_RR(28, xor, 0x00ff00ff, 0xf00ff00f, 0xf0f0f0f0)
TEST_RR(29, xor, 0xedcba987, 0x12345678, 0xffffffff)
TEST_RR(30, xor, 0x12345678, 0x12345678, 0x00000000)
TEST_RR_SRC1_EQ_DEST(31, xor, 0xf00ff00f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC2_EQ_DEST(32, xor, 0xf00ff00f, 0xff00ff00, 0x0f0f0f0f)
TEST_RR_SRC12_EQ_DEST(33, xor, 0x00000000, 0xff00ff00)
TEST_RR_ZERO_SRC1(34, xor, 0x0f0f0f0f, 0x0f0f0f0f)
TEST_RR_ZERO_SRC2(35, xor, 0xff00ff00, 0xff00ff00)
TEST_RR_ZERO_DEST(36, xor, 0xff00ff00, 0x0f0f0f0f)
/* ANDI */
TEST_RI(37, andi, 0xff00ff00, 0xff00ff00, -241)
TEST_RI(38, andi, 0x000000f0, 0x0ff00ff0, 240)
TEST_RI(39, andi, 0x0000000f, 0x00ff00ff, 1807)
TEST_RI(40, andi, 0x00000000, 0xf00ff00f, 240)
TEST_RI(41, andi, 0x00ff0f00, 0x00ff0f00, -1)
TEST_RI(42, andi, 0x00000000, 0x12345678, 0)
TEST_RI(43, andi, 0x80000000, 0x80000000, -2048)
TEST_RI(44, andi, 0x000007ff, 0x7fffffff, 2047)
TEST_RI_SRC1_EQ_DEST(45, andi, 0x00000700, 0xff00ff00, 1807)
TEST_RI_ZERO_DEST(46, andi, 0xff00ff00, 1807)
/* ORI */
TEST_RI(47, ori, 0xffffff0f, 0xff00ff00, -241)
TEST_RI(48, ori, 0x0ff00ff0, 0x0ff00ff0, 240)
TEST_RI(49, ori, 0x00ff07ff, 0x00ff00ff, 1807)
TEST_RI(50, ori, 0xf00ff0ff, 0xf00ff00f, 240)
TEST_RI(51, ori, 0xffffffff, 0x00ff0f00, -1)
TEST_RI(52, ori, 0x12345678, 0x12345678, 0)
TEST_RI(53, ori, 0xfffff800, 0x80000000, -2048)
TEST_RI(54, ori, 0x7fffffff, 0x7fffffff, 2047)
TEST_RI_SRC1_EQ_DEST(55, ori, 0xff00ff0f, 0xff00ff00, 1807)
TEST_RI_ZERO_DEST(56, ori, 0xff00ff00, 1807)
/* XORI */
TEST_RI(57, xori, 0x00ff000f, 0xff00ff00, -241)
TEST_RI(58, xori, 0x0ff00f00, 0x0ff00ff0, 240)
TEST_RI(59, xori, 0x00ff07f0, 0x00ff00ff, 1807)
TEST_RI(60, xori, 0xf00ff0ff, 0xf00ff00f, 240)
TEST_RI(61, xori, 0xff00f0ff, 0x00ff0f00, -1)
TEST_RI(62, xori, 0x12345678, 0x12345678, 0)
TEST_RI(63, xori, 0x7ffff800, 0x80000000, -2048)
TEST_RI(64, xori, 0x7ffff800, 0x7fffffff, 2047)
TEST_RI_SRC1_EQ_DEST(65, xori, 0xff00f80f, 0xff00ff00, 1807)
TEST_RI_ZERO_DEST(66, xori, 0xff00ff00, 1807)

TEST_END
