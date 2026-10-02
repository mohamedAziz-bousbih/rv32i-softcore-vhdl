/*
 * rt_arith.c - integer multiply and divide for a core without the M
 * extension.
 *
 * The compiler lowers every 32-bit *, / and % to calls of these helpers
 * (the libgcc/compiler-rt names), so this file is what "emulated
 * instructions" means on RV32I: a native ADD costs one cycle, a multiply
 * costs a loop of shifts and adds. hello/main.c measures the difference.
 *
 * Division by zero follows the RISC-V M-extension convention (quotient -1,
 * i.e. all ones, remainder = dividend) instead of trapping. For the unsigned
 * helpers this falls out of the restoring-division loop by itself.
 */
#include <stdint.h>

uint32_t __mulsi3(uint32_t a, uint32_t b);
uint32_t __udivsi3(uint32_t n, uint32_t d);
uint32_t __umodsi3(uint32_t n, uint32_t d);
int32_t  __divsi3(int32_t n, int32_t d);
int32_t  __modsi3(int32_t n, int32_t d);

uint32_t __mulsi3(uint32_t a, uint32_t b)
{
    uint32_t r = 0;

    /* Shift-and-add, iterating over the smaller operand: the loop runs
     * once per significant bit of the multiplier. */
    if (a < b) {
        uint32_t t = a;
        a = b;
        b = t;
    }
    while (b != 0) {
        if (b & 1u)
            r += a;
        a <<= 1;
        b >>= 1;
    }
    return r;
}

/* Restoring division, one quotient bit per iteration. */
static uint32_t udivmod(uint32_t n, uint32_t d, uint32_t *rem)
{
    uint32_t q = 0;
    uint32_t r = 0;

    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= 1u << i;
        }
    }
    *rem = r;
    return q;
}

uint32_t __udivsi3(uint32_t n, uint32_t d)
{
    uint32_t r;
    return udivmod(n, d, &r);
}

uint32_t __umodsi3(uint32_t n, uint32_t d)
{
    uint32_t r;
    udivmod(n, d, &r);
    return r;
}

/* Magnitudes are computed in unsigned arithmetic so that INT32_MIN has no
 * overflow; INT32_MIN / -1 wraps to INT32_MIN as on RISC-V hardware. */
static uint32_t magnitude(int32_t v)
{
    return v < 0 ? 0u - (uint32_t)v : (uint32_t)v;
}

int32_t __divsi3(int32_t n, int32_t d)
{
    uint32_t r;
    uint32_t q;

    if (d == 0)
        return -1;  /* the sign fix-up below would turn it into +1 */
    q = udivmod(magnitude(n), magnitude(d), &r);
    return (int32_t)(((n < 0) != (d < 0)) ? 0u - q : q);
}

int32_t __modsi3(int32_t n, int32_t d)
{
    uint32_t r;
    udivmod(magnitude(n), magnitude(d), &r);
    return (int32_t)(n < 0 ? 0u - r : r);
}
