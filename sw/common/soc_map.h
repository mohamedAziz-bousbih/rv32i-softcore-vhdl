/*
 * soc_map.h - memory map of the SoC, shared by C and assembly sources.
 * Mirrors the constants in rtl/soc/soc_pkg.vhd.
 */
#ifndef SOC_MAP_H
#define SOC_MAP_H

#define ROM_BASE  0x00000000  /* 16 KiB: code and read-only data          */
#define RAM_BASE  0x10000000  /* 16 KiB: data and stack                    */
#define MMIO_BASE 0x20000000  /* peripherals, offsets below                 */

#define UART_DATA_OFF   0x00  /* W : send one byte (ignored while busy)     */
#define UART_STATUS_OFF 0x04  /* R : bit 0 = transmitter busy               */
#define GPIO_OUT_OFF    0x10  /* RW: LEDs                                   */
#define GPIO_IN_OFF     0x14  /* R : switches (synchronised)                */
#define MTIME_OFF       0x20  /* RW: counts clock cycles                    */
#define INSTRET_OFF     0x24  /* RW: counts retired instructions; a read
                                 returns the count of all older ones, and
                                 the store that writes it is counted too   */
#define CRC_STATE_OFF   0x30  /* RW: CRC-32 register                        */
#define CRC_DATA_OFF    0x34  /* W : fold the low byte into CRC_STATE       */
#define TEST_STATUS_OFF 0x40  /* W : 1 = pass, (n << 1) | 1 = case n failed */

#define UART_BUSY 0x1
#define TEST_PASS 1

#endif
