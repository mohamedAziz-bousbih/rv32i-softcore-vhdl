-- soc_mmio: memory-mapped peripherals of the SoC.
--
--   UART TX      8N1 transmitter with a busy flag
--   GPIO         output register (LEDs) and synchronised inputs (switches)
--   MTIME        32-bit free-running cycle counter, writable
--   INSTRET      32-bit retired-instruction counter, writable
--   CRC32        one-byte-per-cycle CRC-32 accelerator
--   TEST_STATUS  result register watched by the simulation testbench
--
-- Registers are written as whole words (the core replicates byte and
-- halfword store data across lanes, so SB to UART_DATA also works). Reads
-- have no side effects and are registered to give the one-cycle latency the
-- core's data port expects.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;
use work.soc_pkg.all;

entity soc_mmio is
  generic (
    CLKS_PER_BIT : positive;
    GPIO_WIDTH   : positive
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- bus
    sel          : in  std_logic;  -- access targets the MMIO region
    idx          : in  mmio_idx_t;
    we           : in  std_logic;
    wdata        : in  word_t;
    rdata        : out word_t;
    -- event inputs
    retire_pulse : in  std_logic;  -- an instruction retires this cycle
    -- pins
    uart_tx      : out std_logic;
    gpio_out     : out std_logic_vector(GPIO_WIDTH - 1 downto 0);
    gpio_in      : in  std_logic_vector(GPIO_WIDTH - 1 downto 0);
    -- simulation observation
    status_we    : out std_logic;
    status_data  : out word_t
  );
end entity soc_mmio;

architecture rtl of soc_mmio is

  signal wr         : std_logic;
  signal uart_start : std_logic;
  signal uart_busy  : std_logic;

  signal gpio_out_r : std_logic_vector(GPIO_WIDTH - 1 downto 0) := (others => '0');
  -- Two-flop synchroniser: the switches are asynchronous to clk.
  signal gpio_meta  : std_logic_vector(GPIO_WIDTH - 1 downto 0) := (others => '0');
  signal gpio_sync  : std_logic_vector(GPIO_WIDTH - 1 downto 0) := (others => '0');

  signal mtime       : unsigned(31 downto 0) := (others => '0');
  signal instret     : unsigned(31 downto 0) := (others => '0');
  -- instret including the instruction retiring in this cycle. A load in EX
  -- sees its predecessor in WB, not yet counted; reading instret_now makes
  -- the value exactly "instructions retired before this load".
  signal instret_now : unsigned(31 downto 0);
  signal crc         : word_t := (others => '1');

  signal status_we_r   : std_logic := '0';
  signal status_data_r : word_t := (others => '0');

begin

  assert GPIO_WIDTH <= 32 report "GPIO_WIDTH must not exceed 32" severity failure;

  wr         <= sel and we;
  uart_start <= '1' when wr = '1' and idx = MMIO_UART_DATA else '0';

  instret_now <= instret + 1 when retire_pulse = '1' else instret;

  uart : entity work.uart_tx
    generic map (
      CLKS_PER_BIT => CLKS_PER_BIT
    )
    port map (
      clk   => clk,
      rst   => rst,
      data  => wdata(7 downto 0),
      start => uart_start,
      busy  => uart_busy,
      tx    => uart_tx
    );

  process (clk)
  begin
    if rising_edge(clk) then
      gpio_meta <= gpio_in;
      gpio_sync <= gpio_meta;

      if rst = '1' then
        gpio_out_r  <= (others => '0');
        mtime       <= (others => '0');
        instret     <= (others => '0');
        crc         <= (others => '1');
        status_we_r <= '0';
      else
        mtime       <= mtime + 1;
        instret     <= instret_now;
        status_we_r <= '0';

        -- A software write takes precedence over the counter increments.
        if wr = '1' then
          case idx is
            when MMIO_GPIO_OUT =>
              gpio_out_r <= wdata(GPIO_WIDTH - 1 downto 0);
            when MMIO_MTIME =>
              mtime <= unsigned(wdata);
            when MMIO_INSTRET =>
              instret <= unsigned(wdata);
            when MMIO_CRC_STATE =>
              crc <= wdata;
            when MMIO_CRC_DATA =>
              crc <= crc32_update_byte(crc, wdata(7 downto 0));
            when MMIO_TEST_STATUS =>
              status_we_r   <= '1';
              status_data_r <= wdata;
            when others =>
              null;
          end case;
        end if;
      end if;

      rdata <= (others => '0');
      case idx is
        when MMIO_UART_STATUS => rdata(0) <= uart_busy;
        when MMIO_GPIO_OUT    => rdata(GPIO_WIDTH - 1 downto 0) <= gpio_out_r;
        when MMIO_GPIO_IN     => rdata(GPIO_WIDTH - 1 downto 0) <= gpio_sync;
        when MMIO_MTIME       => rdata <= std_logic_vector(mtime);
        when MMIO_INSTRET     => rdata <= std_logic_vector(instret_now);
        when MMIO_CRC_STATE   => rdata <= crc;
        when others           => null;
      end case;
    end if;
  end process;

  gpio_out    <= gpio_out_r;
  status_we   <= status_we_r;
  status_data <= status_data_r;

end architecture rtl;
