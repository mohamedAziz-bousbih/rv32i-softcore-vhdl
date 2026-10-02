/*
 * mmio.S - memory map and peripherals: GPIO, MTIME, INSTRET, the CRC-32
 * unit, the UART transmitter and the behaviour of unmapped addresses.
 *
 * The counter cases pin down the pipeline timing: back-to-back loads are
 * one cycle apart, a taken branch costs one extra cycle, and its bubble is
 * not counted as an instruction.
 *
 * @uart OK
 * @leds 0x2c3
 */

#include "test_macros.h"

TEST_BEGIN
    li   s1, MMIO_BASE

/* GPIO: the output register holds 10 bits; the testbench drives 0x2A5
 * onto the switch inputs. */
TEST_CASE(1, x14, 0x3ff, li x2, 0x3ff; sw x2, GPIO_OUT_OFF(s1); lw x14, GPIO_OUT_OFF(s1))
TEST_CASE(2, x14, 0x155, li x2, 0xfffffd55; sw x2, GPIO_OUT_OFF(s1); lw x14, GPIO_OUT_OFF(s1))
TEST_CASE(3, x14, 0x2a5, lw x14, GPIO_IN_OFF(s1))

/* MTIME counts clock cycles. */
TEST_CASE(4, x14, 1,
    lw x5, MTIME_OFF(s1); lw x6, MTIME_OFF(s1); sub x14, x6, x5)
TEST_CASE(5, x14, 4,
    lw x5, MTIME_OFF(s1); nop; nop; nop; lw x6, MTIME_OFF(s1); sub x14, x6, x5)
TEST_CASE(6, x14, 3,
    lw x5, MTIME_OFF(s1); beq x0, x0, 4f; 4: lw x6, MTIME_OFF(s1); sub x14, x6, x5)
/* A write is visible to the next instruction, and the counter wraps. */
TEST_CASE(7, x14, 1000,
    li x2, 1000; sw x2, MTIME_OFF(s1); lw x14, MTIME_OFF(s1))
TEST_CASE(8, x14, 0,
    li x2, -1; sw x2, MTIME_OFF(s1); nop; lw x14, MTIME_OFF(s1))

/* INSTRET counts retired instructions, not cycles. */
TEST_CASE(9, x14, 3,
    lw x5, INSTRET_OFF(s1); nop; nop; lw x6, INSTRET_OFF(s1); sub x14, x6, x5)
TEST_CASE(10, x14, 2,
    lw x5, INSTRET_OFF(s1); beq x0, x0, 4f; 4: lw x6, INSTRET_OFF(s1); sub x14, x6, x5)
/* The store that writes INSTRET is counted on top of the new value. */
TEST_CASE(11, x14, 101,
    li x2, 100; sw x2, INSTRET_OFF(s1); lw x14, INSTRET_OFF(s1))

/* CRC-32 unit: the standard check value of "123456789", fed with byte
 * stores (the core replicates SB data into all lanes). */
test_12:
    li   TESTNUM, 12
    li   x2, -1
    sw   x2, CRC_STATE_OFF(s1)
    la   x1, crc_input
    addi x7, x1, 9
4:  lbu  x5, 0(x1)
    sb   x5, CRC_DATA_OFF(s1)
    addi x1, x1, 1
    bne  x1, x7, 4b
    lw   x14, CRC_STATE_OFF(s1)
    not  x14, x14
    li   x29, 0xcbf43926
    bne  x14, x29, fail
TEST_CASE(13, x14, 0x12345678,
    li x2, 0x12345678; sw x2, CRC_STATE_OFF(s1); lw x14, CRC_STATE_OFF(s1))

/* Unmapped MMIO offsets and unmapped regions read as zero. */
TEST_CASE(14, x14, 0, li x14, -1; lw x14, 0x3c(s1))
TEST_CASE(15, x14, 0, li x1, 0x30000000; li x14, -1; lw x14, 0(x1))

/* Stores to the ROM are dropped. */
TEST_CASE(16, x14, 0x600dc0de, la x1, rom_word; sw x0, 0(x1); lw x14, 0(x1))

/* The RAM is partially decoded: it repeats every 16 KiB of its window. */
TEST_CASE(17, x14, 0x0badf00d,
    li x1, RAM_BASE + 0x4200; li x2, 0x0badf00d; sw x2, 0(x1);
    li x1, RAM_BASE + 0x0200; lw x14, 0(x1))

/* UART: busy right after a write, and a write while busy is dropped, so
 * the line received by the testbench is "OK". */
test_18:
    li   TESTNUM, 18
    li   x2, 0x4f               /* 'O' */
    sw   x2, UART_DATA_OFF(s1)
    lw   x14, UART_STATUS_OFF(s1)
    li   x2, 0x58               /* 'X', must be dropped */
    sw   x2, UART_DATA_OFF(s1)
    li   x29, UART_BUSY
    bne  x14, x29, fail
4:  lw   x14, UART_STATUS_OFF(s1)
    bnez x14, 4b
    li   x2, 0x4b               /* 'K' */
    sw   x2, UART_DATA_OFF(s1)
5:  lw   x14, UART_STATUS_OFF(s1)
    bnez x14, 5b
    li   x2, 0x0a               /* '\n' */
    sw   x2, UART_DATA_OFF(s1)
6:  lw   x14, UART_STATUS_OFF(s1)
    bnez x14, 6b

    /* Final LED pattern, compared by the testbench (@leds). */
    li   x2, 0x2c3
    sw   x2, GPIO_OUT_OFF(s1)

TEST_END

    .section .rodata
    .balign 4
rom_word:
    .word 0x600dc0de
crc_input:
    .ascii "123456789"
