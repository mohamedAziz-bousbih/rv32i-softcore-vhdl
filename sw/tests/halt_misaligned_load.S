/*
 * halt_misaligned_load.S - a misaligned load stops the core.
 *
 * The core implements no trap vector (no Zicsr), so this exception halts
 * it. The halt must be precise: the store before the faulting instruction
 * has set the LEDs to 0x155 and the ADDI directly before it (in write-back
 * while the fault is detected) still retires; the store behind it, which
 * would set the LEDs to 0x156, never executes. The faulting load must not
 * write its destination either: x14 keeps its sentinel. The load addresses
 * the ROM, whose first word is nonzero, so a wrongly completed load would
 * be visible.
 *
 * @expect halt_misaligned_load
 * @leds 0x155
 * @reg x7 0x156
 * @reg x14 0x5a5
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   s1, MMIO_BASE
    li   x14, 0x5a5
    li   t2, 0x155
    sw   t2, GPIO_OUT_OFF(s1)
    addi t2, t2, 1
    lw   x14, 2(x0)                /* word load from a halfword address */
    sw   t2, GPIO_OUT_OFF(s1)

    /* Only reached if the core failed to halt. */
    li   t0, (1 << 1) | 1
    sw   t0, TEST_STATUS_OFF(s1)
1:  j    1b
