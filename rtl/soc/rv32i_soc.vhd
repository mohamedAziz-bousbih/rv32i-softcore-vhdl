-- rv32i_soc: the core plus instruction ROM, data RAM and peripherals.
--
-- Modified Harvard organisation: instruction fetch has its own ROM port, so
-- fetch and data accesses never compete for a memory and the pipeline needs
-- no structural-hazard stalls. The ROM's second port makes constants and
-- initialised-data images readable with ordinary loads. Instructions can
-- only be fetched from ROM: the fetch port ignores the region bits, so any
-- PC outside the ROM simply aliases into it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;
use work.soc_pkg.all;

entity rv32i_soc is
  generic (
    ROM_INIT      : word_array_t;       -- program image, word 0 first
    ROM_ADDR_BITS : positive := 12;     -- 2**12 words = 16 KiB
    RAM_ADDR_BITS : positive := 12;     -- 16 KiB
    CLKS_PER_BIT  : positive := 434;    -- 50 MHz / 115200 baud
    GPIO_WIDTH    : positive := 10
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    uart_tx  : out std_logic;
    gpio_out : out std_logic_vector(GPIO_WIDTH - 1 downto 0);
    gpio_in  : in  std_logic_vector(GPIO_WIDTH - 1 downto 0);
    dbg      : out soc_debug_t;
    -- register file debug read address (testbench only)
    dbg_reg_addr : in reg_idx_t := (others => '0')
  );
end entity rv32i_soc;

architecture rtl of rv32i_soc is

  signal imem_addr  : word_t;
  signal imem_rdata : word_t;
  signal dmem_addr  : word_t;
  signal dmem_we    : byte_en_t;
  signal dmem_wdata : word_t;
  signal dmem_rdata : word_t;

  signal region    : region_t;
  signal region_q  : region_t := REGION_ROM;  -- region of the previous access
  signal ram_we    : byte_en_t;
  signal mmio_sel  : std_logic;
  signal mmio_we   : std_logic;
  signal rom_rdata : word_t;
  signal ram_rdata : word_t;
  signal io_rdata  : word_t;

  signal retire : retire_t;

begin

  core : entity work.rv32i_core
    port map (
      clk        => clk,
      rst        => rst,
      imem_addr  => imem_addr,
      imem_rdata => imem_rdata,
      dmem_addr  => dmem_addr,
      dmem_we    => dmem_we,
      dmem_wdata => dmem_wdata,
      dmem_rdata => dmem_rdata,
      halted     => dbg.halted,
      halt_cause => dbg.halt_cause,
      halt_pc    => dbg.halt_pc,
      retire     => retire,
      dbg_reg_addr => dbg_reg_addr,
      dbg_reg_data => dbg.reg_data
    );

  dbg.retire <= retire;

  ---------------------------------------------------------------------------
  -- Address decode. Stores to ROM or unmapped regions are dropped, loads
  -- from unmapped regions return zero.
  ---------------------------------------------------------------------------
  region   <= dmem_addr(31 downto 28);
  ram_we   <= dmem_we when region = REGION_RAM else "0000";
  mmio_sel <= '1' when region = REGION_MMIO else '0';
  mmio_we  <= '1' when dmem_we /= "0000" else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      region_q <= region;
    end if;
  end process;

  with region_q select dmem_rdata <=
    rom_rdata       when REGION_ROM,
    ram_rdata       when REGION_RAM,
    io_rdata        when REGION_MMIO,
    (others => '0') when others;

  ---------------------------------------------------------------------------
  -- Memories and peripherals
  ---------------------------------------------------------------------------
  rom : entity work.rom_dp
    generic map (
      ADDR_BITS => ROM_ADDR_BITS,
      INIT      => ROM_INIT
    )
    port map (
      clk    => clk,
      addr_a => imem_addr(ROM_ADDR_BITS + 1 downto 2),
      q_a    => imem_rdata,
      addr_b => dmem_addr(ROM_ADDR_BITS + 1 downto 2),
      q_b    => rom_rdata
    );

  ram : entity work.ram_be
    generic map (
      ADDR_BITS => RAM_ADDR_BITS
    )
    port map (
      clk   => clk,
      addr  => dmem_addr(RAM_ADDR_BITS + 1 downto 2),
      we    => ram_we,
      wdata => dmem_wdata,
      q     => ram_rdata
    );

  mmio : entity work.soc_mmio
    generic map (
      CLKS_PER_BIT => CLKS_PER_BIT,
      GPIO_WIDTH   => GPIO_WIDTH
    )
    port map (
      clk          => clk,
      rst          => rst,
      sel          => mmio_sel,
      idx          => dmem_addr(7 downto 2),
      we           => mmio_we,
      wdata        => dmem_wdata,
      rdata        => io_rdata,
      retire_pulse => retire.valid,
      uart_tx      => uart_tx,
      gpio_out     => gpio_out,
      gpio_in      => gpio_in,
      status_we    => dbg.status_we,
      status_data  => dbg.status_data
    );

end architecture rtl;
