/*
 * jump.S - JAL and JALR.
 *
 * Link values and targets are compared with link-time addresses loaded via
 * LUI/ADDI (LA_ABS). JALR is checked for the bit-0 clearing of the target
 * (after the addition), for rd == rs1, and for a base register that was
 * produced by the instruction directly before it.
 */

#include "test_macros.h"

TEST_BEGIN

/* JAL beyond the +-4 KiB reach of a branch: +8192 forward, -8196 back.
 * First for the same reason as in branch.S. */
test_1:
    li   TESTNUM, 1
    j    4f
5:  j    6f                 /* backward target, address B           */
4:  jal  x0, 7f             /* at B + 4: offset +8192               */
    j    fail
    .skip 8184
7:  jal  x0, 5b             /* at B + 8196: offset -8196            */
    j    fail
6:

/* JAL writes the address of the following instruction. */
test_2:
    li   TESTNUM, 2
jal_2:
    jal  x1, 4f
    j    fail
4:  LA_ABS(x29, jal_2 + 4)
    bne  x1, x29, fail

/* Backward JAL linking into a register other than ra. */
test_3:
    li   TESTNUM, 3
    j    5f
4:  LA_ABS(x29, jal_3 + 4)
    bne  x5, x29, fail
    j    6f
5:
jal_3:
    jal  x5, 4b
    j    fail
6:

/* JAL with rd = x0 (the `j` pseudo-instruction) links nowhere. */
TEST_CASE(4, x14, 0, jal x0, 4f; 4: or x14, x0, x0)

/* JALR to a register, link = pc + 4. */
test_5:
    li   TESTNUM, 5
    LA_ABS(x2, 4f)
jalr_5:
    jalr x1, 0(x2)
    j    fail
4:  LA_ABS(x29, jalr_5 + 4)
    bne  x1, x29, fail

/* Positive and negative immediates. */
test_6:
    li   TESTNUM, 6
    LA_ABS(x2, 4f - 12)
    jalr x0, 12(x2)
    j    fail
4:
test_7:
    li   TESTNUM, 7
    LA_ABS(x2, 4f + 2048)
    jalr x0, -2048(x2)
    j    fail
4:

/* Bit 0 of rs1 + imm is cleared: an odd base lands on the even target.
 * Instruction fetch ignores the low address bits, so the target would be
 * executed even with bit 0 still set; AUIPC at the target exposes the PC. */
test_8:
    li   TESTNUM, 8
    LA_ABS(x2, jalr_8_target)
    addi x2, x2, 1
    jalr x0, 0(x2)
    j    fail
jalr_8_target:
    auipc x14, 0
    LA_ABS(x29, jalr_8_target)
    bne  x14, x29, fail

/* The clearing happens after the addition: (T + 1) + (-1) = T. Clearing
 * the base first would give T - 1 instead. */
test_9:
    li   TESTNUM, 9
    LA_ABS(x2, jalr_9_target + 1)
    jalr x0, -1(x2)
    j    fail
jalr_9_target:
    auipc x14, 0
    LA_ABS(x29, jalr_9_target)
    bne  x14, x29, fail

/* rd == rs1: the target uses the old value, then the link overwrites it. */
test_10:
    li   TESTNUM, 10
    LA_ABS(x2, 4f)
jalr_10:
    jalr x2, 0(x2)
    j    fail
4:  LA_ABS(x29, jalr_10 + 4)
    bne  x2, x29, fail

/* Base computed by the instruction right before the JALR (forwarded). */
test_11:
    li   TESTNUM, 11
    LA_ABS(x2, 4f - 4)
    addi x2, x2, 4
    jalr x0, 0(x2)
    j    fail
4:

/* Base loaded by the instruction right before the JALR (load forwarding,
 * the computed-goto / jump-table pattern). */
test_12:
    li   TESTNUM, 12
    LA_ABS(x5, jump_table)
    lw   x2, 4(x5)
    jalr x0, 0(x2)
    j    fail
jalr_12_target:

/* Nested calls through the stack: call/ret are AUIPC+JALR and JALR. */
test_13:
    li   TESTNUM, 13
    li   sp, RAM_BASE + 0x400
    li   x14, 0
    call func_a
    li   x29, 3
    bne  x14, x29, fail
    li   x29, RAM_BASE + 0x400
    bne  sp, x29, fail
    j    4f

func_a:
    addi sp, sp, -4
    sw   ra, 0(sp)
    addi x14, x14, 1
    call func_b
    addi x14, x14, 1
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret
func_b:
    addi x14, x14, 1
    ret
4:

/* JALR to x0 with ra as base (ret) leaves ra intact. */
test_14:
    li   TESTNUM, 14
    LA_ABS(ra, 4f)
    mv   x5, ra
    ret
    j    fail
4:  bne  ra, x5, fail

TEST_END

    .section .rodata
    .balign 4
jump_table:
    .word fail
    .word jalr_12_target
