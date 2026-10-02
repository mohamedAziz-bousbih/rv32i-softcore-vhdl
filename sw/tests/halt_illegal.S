/*
 * halt_illegal.S - an instruction outside RV32I stops the core.
 *
 * The core implements no trap vector (no Zicsr), so this exception halts
 * it. The halt must be precise: the store before the faulting instruction
 * has set the LEDs to 0x155 and the ADDI directly before it (in write-back
 * while the fault is detected) still retires; the store behind it, which
 * would set the LEDs to 0x156, never executes. The faulting instruction
 * must not write its destination either: x14 keeps its sentinel instead of
 * becoming 3 + 4, which an RV32M MUL misdecoded as ADD would produce.
 *
 * @expect halt_illegal
 * @leds 0x155
 * @reg x7 0x156
 * @reg x14 0x5a5
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   s1, MMIO_BASE
    li   x1, 3
    li   x2, 4
    li   x14, 0x5a5

    li   t2, 0x155
    sw   t2, GPIO_OUT_OFF(s1)
    addi t2, t2, 1
    .word 0x02208733             /* mul x14, x1, x2 (RV32M) */
    sw   t2, GPIO_OUT_OFF(s1)

    /* Only reached if the core failed to halt. */
    li   t0, (1 << 1) | 1
    sw   t0, TEST_STATUS_OFF(s1)
1:  j    1b
