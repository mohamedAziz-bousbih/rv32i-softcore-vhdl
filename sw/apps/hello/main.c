/*
 * hello - demo and self-test program for the RV32I SoC.
 *
 * Prints a greeting, runs small kernels with known results, measures each
 * one with the MTIME (cycles) and INSTRET counters and reports pass/fail to
 * the test-status register. On the DE10-Lite it then keeps mirroring the
 * slide switches onto the LEDs.
 *
 * Measurement windows never contain UART output, so the cycle counts do not
 * depend on the baud rate and are the same in simulation and on the board.
 *
 * Expected output: expected_uart.txt ('#' stands for a number). The
 * testbench drives 0x2A5 onto the switches, which end up on the LEDs:
 * @leds 0x2a5
 */
#include <stdint.h>

#include "soc.h"

/* The helpers from rt_arith.c, called directly where plain C operators
 * would be undefined behaviour (division by zero, INT32_MIN / -1). */
uint32_t __mulsi3(uint32_t a, uint32_t b);
uint32_t __udivsi3(uint32_t n, uint32_t d);
uint32_t __umodsi3(uint32_t n, uint32_t d);
int32_t  __divsi3(int32_t n, int32_t d);
int32_t  __modsi3(int32_t n, int32_t d);

#define SORT_LEN 48
#define CRC_LEN  256

/* CRC-32 of the 256-byte buffer filled by fill_crc_buffer(), computed
 * independently with Python's zlib.crc32. */
#define CRC_BUFFER_EXPECTED 0x78825239u

struct perf {
    uint32_t cycles;
    uint32_t instret;
};

/* Hides a value from the optimiser, so that kernels called with constant
 * arguments are executed at run time instead of being folded into their
 * result at compile time. Generates no instructions. */
static inline uint32_t opaque(uint32_t v)
{
    __asm__ volatile("" : "+r"(v));
    return v;
}

static int first_failure;  /* number of the first failed check, 0 = none */
static int check_count;

static uint32_t sort_data[SORT_LEN];
static uint8_t crc_buffer[CRC_LEN];

static int check(int ok)
{
    check_count++;
    if (!ok && first_failure == 0)
        first_failure = check_count;
    return ok;
}

static struct perf perf_start(void)
{
    struct perf p = { soc_cycles(), soc_instret() };
    return p;
}

static struct perf perf_stop(struct perf start)
{
    struct perf p = { soc_cycles() - start.cycles, soc_instret() - start.instret };
    return p;
}

/* Prints hundredths as "i.ff". */
static void put_fixed2(uint32_t hundredths)
{
    uint32_t frac = hundredths % 100u;

    uart_put_dec(hundredths / 100u);
    uart_putc('.');
    uart_putc((char)('0' + frac / 10u));
    uart_putc((char)('0' + frac % 10u));
}

static void put_result(int ok, struct perf p)
{
    uart_puts(ok ? " ok (" : " FAIL (");
    uart_put_dec(p.cycles);
    uart_puts(" cycles, ");
    uart_put_dec(p.instret);
    uart_puts(" instr, CPI ");
    put_fixed2(p.cycles * 100u / p.instret);
    uart_puts(")\n");
}

/* ---------------------------------------------------------------- kernels */

static uint32_t fib_iter(uint32_t n)
{
    uint32_t a = 0, b = 1;

    while (n-- > 0) {
        uint32_t t = a + b;
        a = b;
        b = t;
    }
    return a;
}

/* Deliberately naive: exercises calls, returns and the stack, i.e. the
 * taken-jump penalty of the pipeline. */
static uint32_t fib_rec(uint32_t n)
{
    return n < 2 ? n : fib_rec(n - 1) + fib_rec(n - 2);
}

/* Numerical Recipes LCG; the multiply is emulated by __mulsi3. */
static uint32_t lcg_next(uint32_t *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

static void bubble_sort(uint32_t *a, int n)
{
    for (int end = n - 1; end > 0; end--) {
        int swapped = 0;
        for (int i = 0; i < end; i++) {
            if (a[i] > a[i + 1]) {
                uint32_t t = a[i];
                a[i] = a[i + 1];
                a[i + 1] = t;
                swapped = 1;
            }
        }
        if (!swapped)
            break;
    }
}

/* Bitwise reflected CRC-32 (IEEE 802.3), no lookup table. */
static uint32_t crc32_sw(const uint8_t *p, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFu;

    while (len-- > 0) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

/* The same CRC on the MMIO accelerator: one store per byte. */
static uint32_t crc32_hw(const uint8_t *p, uint32_t len)
{
    MMIO_REG(CRC_STATE_OFF) = 0xFFFFFFFFu;
    while (len-- > 0)
        MMIO_REG(CRC_DATA_OFF) = *p++;
    return ~MMIO_REG(CRC_STATE_OFF);
}

static void fill_crc_buffer(void)
{
    for (uint32_t i = 0; i < CRC_LEN; i++)
        crc_buffer[i] = (uint8_t)(i * 7u + 3u);
}

/* ------------------------------------------------------------------ tests */

static void test_fib(void)
{
    struct perf p = perf_start();
    uint32_t v = fib_iter(opaque(47));  /* largest Fibonacci number below 2^32 */
    p = perf_stop(p);
    uart_puts("fib_iter(47) = ");
    uart_put_dec(v);
    put_result(check(v == 2971215073u), p);

    p = perf_start();
    v = fib_rec(opaque(15));
    p = perf_stop(p);
    uart_puts("fib_rec(15) = ");
    uart_put_dec(v);
    put_result(check(v == 610u), p);
}

static void test_sort(void)
{
    uint32_t seed = 12345u;
    uint32_t sum = 0, xor_all = 0;
    int ok = 1;

    for (int i = 0; i < SORT_LEN; i++) {
        sort_data[i] = lcg_next(&seed);
        sum += sort_data[i];
        xor_all ^= sort_data[i];
    }

    struct perf p = perf_start();
    bubble_sort(sort_data, SORT_LEN);
    p = perf_stop(p);

    /* Sorted, and still the same multiset (as far as sum and XOR tell). */
    for (int i = 0; i < SORT_LEN; i++) {
        if (i > 0 && sort_data[i - 1] > sort_data[i])
            ok = 0;
        sum -= sort_data[i];
        xor_all ^= sort_data[i];
    }
    ok = ok && sum == 0 && xor_all == 0;

    uart_puts("bubble_sort(48 words)");
    put_result(check(ok), p);
}

static void test_crc(void)
{
    static const uint8_t check_input[] = "123456789";
    struct perf p;
    uint32_t sw, hw;

    /* 0xCBF43926 is the published check value of CRC-32/ISO-HDLC. */
    p = perf_start();
    sw = crc32_sw((const uint8_t *)opaque((uint32_t)check_input), opaque(9));
    p = perf_stop(p);
    uart_puts("crc32_sw(\"123456789\") = ");
    uart_put_hex(sw);
    put_result(check(sw == 0xCBF43926u), p);

    fill_crc_buffer();

    p = perf_start();
    sw = crc32_sw(crc_buffer, CRC_LEN);
    p = perf_stop(p);
    uart_puts("crc32_sw(256 bytes) = ");
    uart_put_hex(sw);
    put_result(check(sw == CRC_BUFFER_EXPECTED), p);

    p = perf_start();
    hw = crc32_hw(crc_buffer, CRC_LEN);
    p = perf_stop(p);
    uart_puts("crc32_hw(256 bytes) = ");
    uart_put_hex(hw);
    put_result(check(hw == CRC_BUFFER_EXPECTED), p);
}

static void test_mul_div(void)
{
    uint32_t seed = 1u;
    uint32_t acc = 0;
    struct perf p;
    int ok;

    ok = check(__mulsi3(12345u, 6789u) == 83810205u);
    ok &= check(__mulsi3(0xFFFFFFFFu, 0xFFFFFFFFu) == 1u);
    ok &= check(__mulsi3(0x10000u, 0x10000u) == 0u);

    /* 32 products of pseudo-random operands; acc is checked so that the
     * compiler cannot drop the loop. */
    p = perf_start();
    for (int i = 0; i < 32; i++)
        acc += __mulsi3(lcg_next(&seed), lcg_next(&seed));
    p = perf_stop(p);
    ok &= check(acc == 0x56891660u);
    uart_puts("mul x32 (emulated)");
    put_result(ok, p);

    ok = check(__udivsi3(0xFFFFFFFFu, 10u) == 429496729u);
    ok &= check(__umodsi3(0xFFFFFFFFu, 10u) == 5u);
    ok &= check(__divsi3(-7, 2) == -3 && __modsi3(-7, 2) == -1);
    ok &= check(__divsi3(7, -2) == -3 && __modsi3(7, -2) == 1);
    ok &= check(__divsi3(INT32_MIN, -1) == INT32_MIN && __modsi3(INT32_MIN, -1) == 0);
    ok &= check(__udivsi3(1234u, 0u) == 0xFFFFFFFFu && __umodsi3(1234u, 0u) == 1234u);
    ok &= check(__divsi3(-1234, 0) == -1 && __modsi3(-1234, 0) == -1234);

    p = perf_start();
    acc = __udivsi3(0xDEADBEEFu, 12345u);
    p = perf_stop(p);
    ok &= check(acc == 302626u);
    uart_puts("div (emulated)");
    put_result(ok, p);
}

int main(void)
{
    uart_puts("Hello from RV32I\n");

    test_fib();
    test_sort();
    test_crc();
    test_mul_div();

    uint32_t sw = gpio_read();
    uart_puts("switches = ");
    uart_put_hex(sw);
    uart_putc('\n');
    gpio_write(sw);

    if (first_failure == 0) {
        uart_puts("PASS (");
        uart_put_dec((uint32_t)check_count);
        uart_puts(" checks)\n");
    } else {
        uart_puts("FAIL (check ");
        uart_put_dec((uint32_t)first_failure);
        uart_puts(")\n");
    }
    soc_report(first_failure);

    /* The simulation ends at the report; the board keeps running. */
    for (;;)
        gpio_write(gpio_read());
}
