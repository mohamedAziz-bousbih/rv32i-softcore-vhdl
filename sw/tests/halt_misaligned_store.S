/*
 * halt_misaligned_store.S - a misaligned store stops the core.
 *
 * The core implements no trap vector (no Zicsr), so this exception halts
 * it. The halt must be precise: the store before the faulting instruction
 * has set the LEDs to 0x155 and the ADDI directly before it (in write-back
 * while the fault is detected) still retires; the store behind it, which
 * would set the LEDs to 0x156, never executes.
 *
 * @expect halt_misaligned_store
 * @leds 0x155
 * @reg x7 0x156
 */

#include "test_macros.h"

    .section .text.init
    .globl _start
_start:
    li   s1, MMIO_BASE

    li   t2, 0x155
    sw   t2, GPIO_OUT_OFF(s1)
    addi t2, t2, 1
    sh   t2, GPIO_OUT_OFF + 1(s1) /* would also change the LEDs */
    sw   t2, GPIO_OUT_OFF(s1)

    /* Only reached if the core failed to halt. */
    li   t0, (1 << 1) | 1
    sw   t0, TEST_STATUS_OFF(s1)
1:  j    1b
