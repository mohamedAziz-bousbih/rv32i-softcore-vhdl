/*
 * libsoc.c - polled UART output and test reporting.
 */
#include "soc.h"

void uart_putc(char c)
{
    /* A write while the transmitter is busy would be dropped. */
    while (MMIO_REG(UART_STATUS_OFF) & UART_BUSY)
        ;
    MMIO_REG(UART_DATA_OFF) = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

void uart_put_dec(uint32_t v)
{
    char buf[10];
    int n = 0;

    /* The / and % below become __udivsi3/__umodsi3 calls: RV32I has no
     * divide instruction (see rt_arith.c). */
    do {
        buf[n++] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v != 0);
    while (n > 0)
        uart_putc(buf[--n]);
}

void uart_put_hex(uint32_t v)
{
    static const char digits[] = "0123456789ABCDEF";

    uart_puts("0x");
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc(digits[(v >> shift) & 0xFu]);
}

void uart_flush(void)
{
    while (MMIO_REG(UART_STATUS_OFF) & UART_BUSY)
        ;
}

void soc_report(int failed_case)
{
    uart_flush();
    MMIO_REG(TEST_STATUS_OFF) =
        failed_case ? (((uint32_t)failed_case << 1) | 1u) : TEST_PASS;
}
