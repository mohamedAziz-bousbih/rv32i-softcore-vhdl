-- uart_tx: 8N1 serial transmitter.
--
-- A write while busy is ignored; software polls the busy flag first.
-- The line is driven straight from a flip-flop so it cannot glitch.

library ieee;
use ieee.std_logic_1164.all;

entity uart_tx is
  generic (
    CLKS_PER_BIT : positive  -- clock frequency / baud rate
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    data  : in  std_logic_vector(7 downto 0);
    start : in  std_logic;
    busy  : out std_logic;
    tx    : out std_logic
  );
end entity uart_tx;

architecture rtl of uart_tx is
  -- Frame = stop & data & start, shifted out LSB first. Shifting ones in
  -- from the top leaves the line idle-high once the frame is gone.
  signal shreg     : std_logic_vector(9 downto 0) := (others => '1');
  signal bits_left : natural range 0 to 10 := 0;
  signal baud_cnt  : natural range 0 to CLKS_PER_BIT - 1 := 0;
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        shreg     <= (others => '1');
        bits_left <= 0;
        baud_cnt  <= 0;
      elsif bits_left = 0 then
        if start = '1' then
          shreg     <= '1' & data & '0';
          bits_left <= 10;
          baud_cnt  <= 0;
        end if;
      elsif baud_cnt = CLKS_PER_BIT - 1 then
        baud_cnt  <= 0;
        shreg     <= '1' & shreg(9 downto 1);
        bits_left <= bits_left - 1;
      else
        baud_cnt <= baud_cnt + 1;
      end if;
    end if;
  end process;

  busy <= '0' when bits_left = 0 else '1';
  tx   <= shreg(0);

end architecture rtl;
