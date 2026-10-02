/*
 * soc.h - C access to the SoC peripherals.
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#include "soc_map.h"

#define MMIO_REG(off) (*(volatile uint32_t *)(MMIO_BASE + (off)))

static inline uint32_t soc_cycles(void)  { return MMIO_REG(MTIME_OFF); }
static inline uint32_t soc_instret(void) { return MMIO_REG(INSTRET_OFF); }

static inline uint32_t gpio_read(void)        { return MMIO_REG(GPIO_IN_OFF); }
static inline void     gpio_write(uint32_t v) { MMIO_REG(GPIO_OUT_OFF) = v; }

void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_dec(uint32_t v);
void uart_put_hex(uint32_t v);   /* "0x" and eight digits */
void uart_flush(void);           /* waits until the last frame has left */

/* Reports the result to the TEST_STATUS register (watched by the
 * simulation testbench) after the UART has drained. */
void soc_report(int failed_case);

#endif
