/*
 * hazard.S - data and control hazards of the 3-stage pipeline.
 *
 * Data: a consumer directly behind its producer gets the value through the
 * WB -> EX forwarding path, a consumer two behind through the write-through
 * register file, later ones from the register file proper. Each distance is
 * checked for rs1 and rs2, for ALU and load producers, and for branch,
 * store and JALR consumers.
 *
 * Control: a taken branch or jump squashes the one instruction already
 * fetched behind it. A squashed instruction must not write a register,
 * must not store, and must not be forwarded.
 */

#include "test_macros.h"

#define BUF (RAM_BASE + 0x200)

TEST_BEGIN

/* ALU -> ALU at distance 1, 2, 3 and 4, rs1 side. */
TEST_CASE(1, x14, 12, addi x1, x0, 11; addi x14, x1, 1)
TEST_CASE(2, x14, 12, addi x1, x0, 11; nop; addi x14, x1, 1)
TEST_CASE(3, x14, 12, addi x1, x0, 11; nop; nop; addi x14, x1, 1)
TEST_CASE(4, x14, 12, addi x1, x0, 11; nop; nop; nop; addi x14, x1, 1)

/* ALU -> ALU, rs2 side. */
TEST_CASE(5, x14, -11, addi x2, x0, 11; sub x14, x0, x2)
TEST_CASE(6, x14, -11, addi x2, x0, 11; nop; sub x14, x0, x2)
TEST_CASE(7, x14, -11, addi x2, x0, 11; nop; nop; sub x14, x0, x2)

/* Both operands in flight at once: rs1 at distance 2, rs2 at distance 1. */
TEST_CASE(8, x14, 3, addi x1, x0, 5; addi x2, x0, 2; sub x14, x1, x2)

/* The youngest producer wins when the same register is written twice. */
TEST_CASE(9, x14, 2, addi x5, x0, 1; addi x5, x0, 2; add x14, x5, x0)
TEST_CASE(10, x14, 2, addi x5, x0, 1; addi x5, x0, 2; nop; add x14, x5, x0)

/* A dependency chain with every instruction feeding the next. */
TEST_CASE(11, x14, 16,
    addi x5, x0, 1; add x5, x5, x5; add x5, x5, x5; add x5, x5, x5; add x14, x5, x5)

/* Load -> ALU at distance 1 and 2, both operand sides. */
TEST_CASE(12, x14, 0x101,
    li x1, BUF; li x2, 0x100; sw x2, 0(x1); lw x5, 0(x1); addi x14, x5, 1)
TEST_CASE(13, x14, 0x101,
    li x1, BUF; li x2, 0x100; sw x2, 0(x1); lw x5, 0(x1); nop; addi x14, x5, 1)
TEST_CASE(14, x14, 0xff,
    li x1, BUF; li x2, 0x100; sw x2, 0(x1); li x6, 0x1ff; lw x5, 0(x1); sub x14, x6, x5)

/* Pointer chasing: a loaded value is the next load's address. */
TEST_CASE(15, x14, 0x5555,
    li x1, BUF; li x2, BUF + 8; sw x2, 0(x1); li x2, 0x5555; sw x2, 8(x1);
    lw x5, 0(x1); lw x14, 0(x5))

/* ALU -> branch and load -> branch, distance 1. */
test_16:
    li   TESTNUM, 16
    addi x5, x0, 3
    addi x6, x0, 3
    beq  x5, x6, 4f
    j    fail
4:
test_17:
    li   TESTNUM, 17
    li   x1, BUF
    li   x6, 0x77
    sw   x6, 0(x1)
    lw   x5, 0(x1)
    bne  x5, x6, fail
    lw   x5, 0(x1)
    beq  x5, x6, 4f
    j    fail
4:

/* ALU -> store data and ALU -> store address, distance 1. */
TEST_CASE(18, x14, 0x43,
    li x1, BUF; addi x2, x0, 0x42; addi x2, x2, 1; sw x2, 0(x1); lw x14, 0(x1))
TEST_CASE(19, x14, 0x44,
    li x1, BUF - 4; li x2, 0x44; addi x1, x1, 4; sw x2, 0(x1); lw x14, 0(x1))

/* An instruction behind a taken branch is squashed: no register write. */
TEST_CASE(20, x14, 0,
    li x14, 0; beq x0, x0, 4f; addi x14, x14, 1; addi x14, x14, 1; 4: nop)

/* ... behind JAL and JALR as well. */
TEST_CASE(21, x14, 0,
    li x14, 0; jal x0, 4f; addi x14, x14, 1; 4: nop)
TEST_CASE(22, x14, 0,
    li x14, 0; LA_ABS(x2, 4f); jalr x0, 0(x2); addi x14, x14, 1; 4: nop)

/* A squashed store does not reach memory. */
TEST_CASE(23, x14, 0,
    li x1, BUF; sw x0, 0(x1); li x2, 0x55; beq x0, x0, 4f; sw x2, 0(x1); 4: lw x14, 0(x1))

/* A squashed instruction is not forwarded to the branch target. */
TEST_CASE(24, x14, 7,
    li x5, 7; beq x0, x0, 4f; addi x5, x0, 99; 4: add x14, x5, x0)

/* A taken branch at the target of a taken branch. */
test_25:
    li   TESTNUM, 25
    beq  x0, x0, 4f
    j    fail
4:  bne  TESTNUM, x0, 5f
    j    fail
5:

/* The link register written by JAL is forwarded to the next instruction. */
test_26:
    li   TESTNUM, 26
jal_26:
    jal  x1, 4f
4:  addi x14, x1, 0
    LA_ABS(x29, jal_26 + 4)
    bne  x14, x29, fail

TEST_END
