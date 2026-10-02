/*
 * store.S - SB, SH, SW to the data RAM.
 *
 * The RAM has one write enable per byte lane. Each case stores and then
 * loads in the very next instruction (no stall exists for that), and the
 * merge cases check that a partial store leaves the other lanes alone.
 */

#include "test_macros.h"

#define BUF (RAM_BASE + 0x100)

TEST_BEGIN

/* SW / LW, including negative offsets. */
TEST_ST_LD(1, sw, lw, 0xaa00aa00, 0xaa00aa00, 0, BUF)
TEST_ST_LD(2, sw, lw, 0x00aa00aa, 0x00aa00aa, 4, BUF)
TEST_ST_LD(3, sw, lw, 0x0aa00aa0, 0x0aa00aa0, -4, BUF + 16)
TEST_ST_LD(4, sw, lw, 0xa00aa00a, 0xa00aa00a, 2044, BUF)
TEST_ST_LD(5, sw, lw, 0x12345678, 0x12345678, -2048, BUF + 2048)

/* SH in both halfword lanes, read back signed and unsigned. */
TEST_ST_LD(6, sh, lh, 0xffffaa00, 0xaa00, 0, BUF)
TEST_ST_LD(7, sh, lhu, 0x0000aa00, 0xaa00, 2, BUF)
TEST_ST_LD(8, sh, lh, 0x00000aa0, 0x0aa0, 2, BUF)
TEST_ST_LD(9, sh, lhu, 0x0000a00a, 0xa00a, -2, BUF + 8)

/* SB in all four byte lanes. */
TEST_ST_LD(10, sb, lb, 0xffffffaa, 0xaa, 0, BUF)
TEST_ST_LD(11, sb, lbu, 0x000000aa, 0xaa, 1, BUF)
TEST_ST_LD(12, sb, lb, 0x00000055, 0x55, 2, BUF)
TEST_ST_LD(13, sb, lbu, 0x000000a0, 0xa0, 3, BUF)
TEST_ST_LD(14, sb, lb, 0xffffff80, 0x80, -1, BUF + 8)

/* Only the low byte / halfword of rs2 is stored. */
TEST_ST_LD(15, sb, lbu, 0x00000078, 0x12345678, 1, BUF)
TEST_ST_LD(16, sh, lhu, 0x00005678, 0x12345678, 2, BUF)

/* Byte stores assemble a word lane by lane (little-endian). */
TEST_CASE(17, x14, 0x44332211,
    li x1, BUF; sw x0, 0(x1);
    li x2, 0x11; sb x2, 0(x1);
    li x2, 0x22; sb x2, 1(x1);
    li x2, 0x33; sb x2, 2(x1);
    li x2, 0x44; sb x2, 3(x1);
    lw x14, 0(x1))

TEST_CASE(18, x14, 0xdeadbeef,
    li x1, BUF; sw x0, 0(x1);
    li x2, 0xbeef; sh x2, 0(x1);
    li x2, 0xdead; sh x2, 2(x1);
    lw x14, 0(x1))

/* Partial stores leave the neighbouring lanes untouched. */
TEST_CASE(19, x14, 0xaa11ccdd,
    li x1, BUF; li x2, 0xaabbccdd; sw x2, 0(x1);
    li x2, 0x11; sb x2, 2(x1);
    lw x14, 0(x1))
TEST_CASE(20, x14, 0xaa115566,
    li x1, BUF; li x2, 0x5566; sh x2, 0(x1);
    lw x14, 0(x1))

/* Loading one lane of a word that a byte store just changed. */
TEST_CASE(21, x14, 0xffffffaa,
    li x1, BUF; li x2, 0x01020304; sw x2, 0(x1);
    li x2, 0xaa; sb x2, 1(x1);
    lb x14, 1(x1))

/* Store data and store address produced by the preceding instruction. */
TEST_CASE(22, x14, 0x00000101,
    li x1, BUF; li x2, 0x100; addi x2, x2, 1; sw x2, 0(x1); lw x14, 0(x1))
TEST_CASE(23, x14, 0x00000202,
    li x1, BUF; li x2, 0x202; addi x1, x1, 8; sw x2, 0(x1); lw x14, 0(x1))

/* Load followed by a store of the loaded value (the memcpy pattern). */
TEST_CASE(24, x14, 0x0000beef,
    li x1, BUF; li x2, 0xbeef; sw x2, 0(x1);
    lw x5, 0(x1); sw x5, 4(x1); lw x14, 4(x1))

/* Storing x0 clears memory. */
TEST_CASE(25, x14, 0,
    li x1, BUF; li x2, -1; sw x2, 0(x1); sw x0, 0(x1); lw x14, 0(x1))

/* Back-to-back stores to different words, then the loads. */
TEST_CASE(26, x14, 0x00000003,
    li x1, BUF; li x5, 1; li x6, 2;
    sw x5, 0(x1); sw x6, 4(x1);
    lw x7, 0(x1); lw x8, 4(x1); add x14, x7, x8)

/* The last word of the 16 KiB RAM. */
TEST_ST_LD(27, sw, lw, 0x5a5a5a5a, 0x5a5a5a5a, 0, RAM_BASE + 0x3ffc)

TEST_END
