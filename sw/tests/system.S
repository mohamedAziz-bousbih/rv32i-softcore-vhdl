/*
 * system.S - FENCE, NOP and the hard-wired zero register.
 *
 * FENCE retires as a no-op: the core performs one memory access at a time,
 * in program order, on memories without caches, so every ordering a FENCE
 * can ask for already holds. The specification requires implementations to
 * ignore FENCE's rs1/rd fields (and unknown fm values), so hand-encoded
 * variants with those fields set must not write a register either.
 * ECALL and EBREAK halt the core; see the halt_*.S tests.
 */

#include "test_macros.h"

#define BUF (RAM_BASE + 0x300)

TEST_BEGIN

/* Store, FENCE, load: the data is simply there. */
TEST_CASE(1, x14, 0x1234,
    li x1, BUF; li x2, 0x1234; sw x2, 0(x1); fence; lw x14, 0(x1))
TEST_CASE(2, x14, 0x5678,
    li x1, BUF; li x2, 0x5678; sw x2, 0(x1); fence rw, rw; lw x14, 0(x1))
TEST_CASE(3, x14, 0x9abc,
    li x1, BUF; li x2, 0x9abc; sw x2, 0(x1); fence iorw, iorw; lw x14, 0(x1))

/* fence.tso (fm = 1000) and pause (fence w, 0) are FENCE encodings too. */
TEST_CASE(4, x14, 5, li x14, 5; .word 0x8330000f; .word 0x0100000f)

/* rd = x14, rs1 = x1, pred = succ = iorw: x14 must keep its value. */
TEST_CASE(5, x14, 6, li x14, 6; li x1, 0x40; .word 0x0ff0870f)

/* NOP is addi x0, x0, 0 and changes nothing. */
TEST_CASE(6, x14, 7, li x14, 7; nop; nop; nop)

/* x0 ignores writes from every kind of instruction... */
TEST_CASE(7, x14, 0, addi x0, x0, 5; or x14, x0, x0)
TEST_CASE(8, x14, 0, li x1, -1; add x0, x1, x1; or x14, x0, x0)
TEST_CASE(9, x14, 0, lui x0, 0xfffff; or x14, x0, x0)

/* ...and reads as zero in both operand positions. */
TEST_CASE(10, x14, 0, li x14, -1; add x14, x0, x0)
TEST_CASE(11, x14, 1, li x1, 1; sltu x14, x0, x1)

TEST_END
