-- soc_pkg: memory map, debug record and helpers shared by the SoC blocks.
--
-- Memory map (address bits [31:28] select the region, the rest is
-- partially decoded, so each region aliases within its 256 MiB window):
--
--   0x0000_0000  ROM   instructions + read-only data (second read port)
--   0x1000_0000  RAM   data, stack
--   0x2000_0000  MMIO  peripherals, see MMIO_* word offsets below
--
-- Every region answers with a fixed latency of one cycle, which is what the
-- core's data port expects. sw/common/soc_map.h mirrors these constants for
-- the software.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

package soc_pkg is

  subtype region_t is std_logic_vector(3 downto 0);
  constant REGION_ROM  : region_t := x"0";
  constant REGION_RAM  : region_t := x"1";
  constant REGION_MMIO : region_t := x"2";

  -- MMIO registers, as word offsets (address bits [7:2]) from 0x2000_0000.
  subtype mmio_idx_t is std_logic_vector(5 downto 0);
  constant MMIO_UART_DATA   : mmio_idx_t := "000000";  -- 0x00 W: send byte
  constant MMIO_UART_STATUS : mmio_idx_t := "000001";  -- 0x04 R: bit0 = busy
  constant MMIO_GPIO_OUT    : mmio_idx_t := "000100";  -- 0x10 RW: LEDs
  constant MMIO_GPIO_IN     : mmio_idx_t := "000101";  -- 0x14 R: switches
  constant MMIO_MTIME       : mmio_idx_t := "001000";  -- 0x20 RW: cycle counter
  constant MMIO_INSTRET     : mmio_idx_t := "001001";  -- 0x24 RW: retired instrs
  constant MMIO_CRC_STATE   : mmio_idx_t := "001100";  -- 0x30 RW: CRC-32 state
  constant MMIO_CRC_DATA    : mmio_idx_t := "001101";  -- 0x34 W: fold in a byte
  constant MMIO_TEST_STATUS : mmio_idx_t := "010000";  -- 0x40 W: test result

  -- Everything a testbench needs to observe the SoC without probing
  -- internal signals. Unused on the board, where synthesis prunes it.
  type soc_debug_t is record
    halted      : std_logic;
    halt_cause  : halt_cause_t;
    halt_pc     : word_t;
    retire      : retire_t;
    status_we   : std_logic;  -- TEST_STATUS written in the previous cycle
    status_data : word_t;
    reg_data    : word_t;     -- register selected by dbg_reg_addr
  end record;

  -- Reflected CRC-32 (IEEE 802.3, polynomial 0xEDB88320), one byte per call.
  function crc32_update_byte(crc : word_t; data : std_logic_vector(7 downto 0)) return word_t;

end package soc_pkg;

package body soc_pkg is

  function crc32_update_byte(crc : word_t; data : std_logic_vector(7 downto 0)) return word_t is
    variable c : word_t := crc;
  begin
    c(7 downto 0) := c(7 downto 0) xor data;
    -- Eight unrolled shift/XOR steps become one level of XOR trees in
    -- hardware: the whole byte is absorbed in a single clock cycle.
    for i in 0 to 7 loop
      if c(0) = '1' then
        c := ('0' & c(31 downto 1)) xor x"EDB88320";
      else
        c := '0' & c(31 downto 1);
      end if;
    end loop;
    return c;
  end function;

end package body soc_pkg;
