-- de10lite_top: the SoC on a Terasic DE10-Lite (Intel MAX 10 10M50DAF484C7G).
--
--   MAX10_CLK1_50  50 MHz oscillator, used directly as the system clock
--   KEY(0)         reset (the push-buttons are active low and debounced
--                  on the board)
--   SW(9:0)        GPIO inputs
--   LEDR(9:0)      GPIO outputs
--   UART_TX        115200 baud 8N1, on GPIO_0 of the 2x20 expansion header
--                  (3.3 V levels: connect a 3.3 V USB-UART adapter's RX)
--
-- The program is the one in rom_image_pkg (generated from sw/apps/hello by
-- scripts/build_sw.py).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rom_image_pkg.all;

entity de10lite_top is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 115_200
  );
  port (
    MAX10_CLK1_50 : in  std_logic;
    KEY           : in  std_logic_vector(0 downto 0);  -- KEY1 is unused
    SW            : in  std_logic_vector(9 downto 0);
    LEDR          : out std_logic_vector(9 downto 0);
    UART_TX       : out std_logic
  );
end entity de10lite_top;

architecture rtl of de10lite_top is

  signal clk : std_logic;

  -- Reset: held for 16 cycles after configuration (MAX 10 registers take
  -- their declared power-up values) and while KEY(0) is pressed. KEY(0) is
  -- synchronised first; the reset release is therefore synchronous too.
  signal key_meta  : std_logic := '1';
  signal key_sync  : std_logic := '1';
  signal rst_count : unsigned(3 downto 0) := (others => '0');
  signal rst       : std_logic := '1';

begin

  clk <= MAX10_CLK1_50;

  process (clk)
  begin
    if rising_edge(clk) then
      key_meta <= KEY(0);
      key_sync <= key_meta;
      if key_sync = '0' then
        rst_count <= (others => '0');
        rst       <= '1';
      elsif rst_count /= 15 then
        rst_count <= rst_count + 1;
        rst       <= '1';
      else
        rst <= '0';
      end if;
    end if;
  end process;

  soc : entity work.rv32i_soc
    generic map (
      ROM_INIT      => ROM_IMAGE,
      ROM_ADDR_BITS => 12,
      RAM_ADDR_BITS => 12,
      -- Rounded to the nearest integer: 434 cycles give 115207 baud.
      CLKS_PER_BIT  => (CLK_HZ + BAUD / 2) / BAUD,
      GPIO_WIDTH    => 10
    )
    port map (
      clk      => clk,
      rst      => rst,
      uart_tx  => UART_TX,
      gpio_out => LEDR,
      gpio_in  => SW,
      -- Simulation-only observation ports; synthesis removes their logic.
      dbg          => open,
      dbg_reg_addr => "00000"
    );

end architecture rtl;
