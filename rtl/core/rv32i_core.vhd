-- rv32i_core: RV32I CPU with a 3-stage in-order pipeline.
--
--   FD  fetch/decode : the synchronous instruction memory delivers the word
--                      addressed in the previous cycle; decode and register
--                      read happen in the same cycle.
--   EX  execute      : forwarding, ALU, branch resolution, data-memory
--                      address/byte-enables (the data memory registers them).
--   WB  write-back   : load data arrives from the synchronous data memory,
--                      is aligned/extended and written to the register file.
--
-- Both memory ports have a fixed latency of one cycle: the address is driven
-- combinationally in cycle n and the data is valid in cycle n+1. This is
-- exactly the read behaviour of an FPGA block RAM, so no stall logic exists:
--   * data hazards are removed by WB->EX forwarding plus a write-through
--     register file (a load result is forwarded straight from WB, so even a
--     load followed by a dependent instruction does not stall);
--   * control hazards cost one bubble: branches and jumps resolve in EX, the
--     instruction already in FD is squashed and EX drives the target address
--     into the instruction memory (static not-taken prediction).
-- Hence every instruction takes one cycle, plus one for each taken branch or
-- jump. The Python reference model relies on exactly this rule to predict
-- timer reads and total cycle counts.
--
-- Exceptions (ECALL, EBREAK, illegal instruction, misaligned fetch/load/
-- store) are precise: the faulting instruction and everything younger are
-- discarded, everything older completes, and the core halts with the cause
-- and PC on its outputs. There is no trap vector (no Zicsr), so halting is
-- the whole exception mechanism.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

entity rv32i_core is
  generic (
    RESET_VECTOR : word_t := x"00000000"
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;  -- synchronous, active high
    -- Instruction port: imem_rdata is the word at the imem_addr of the
    -- previous cycle.
    imem_addr  : out word_t;
    imem_rdata : in  word_t;
    -- Data port: same timing. dmem_we carries one enable per byte lane.
    dmem_addr  : out word_t;
    dmem_we    : out byte_en_t;
    dmem_wdata : out word_t;
    dmem_rdata : in  word_t;
    -- Status
    halted     : out std_logic;
    halt_cause : out halt_cause_t;
    halt_pc    : out word_t;
    retire     : out retire_t;
    -- Debug read access to the register file (simulation)
    dbg_reg_addr : in  reg_idx_t := (others => '0');
    dbg_reg_data : out word_t
  );
end entity rv32i_core;

architecture rtl of rv32i_core is

  constant INSTR_NOP : word_t := x"00000013";  -- addi x0, x0, 0
  constant ZERO      : word_t := (others => '0');

  -- FD stage. The instruction register is the memory's own output latch.
  signal pc_fd     : word_t := RESET_VECTOR;
  signal fd_dec    : decoded_t;
  signal rf_rdata1 : word_t;
  signal rf_rdata2 : word_t;
  signal next_pc   : word_t;

  -- FD/EX pipeline register
  signal ex_valid   : std_logic := '0';
  signal ex_pc      : word_t := ZERO;
  signal ex_instr   : word_t := INSTR_NOP;
  signal ex_dec     : decoded_t := decode(INSTR_NOP);
  signal ex_rs1_val : word_t := ZERO;
  signal ex_rs2_val : word_t := ZERO;

  -- EX stage
  signal op1       : word_t;
  signal op2       : word_t;
  signal alu_a     : word_t;
  signal alu_b     : word_t;
  signal alu_y     : word_t;
  signal ex_pc4    : word_t;
  signal ex_target : word_t;
  signal ex_take   : std_logic;
  signal ex_cause  : halt_cause_t;
  signal ex_fault  : std_logic;
  signal ex_go     : std_logic;  -- EX instruction is valid and commits
  signal redirect  : std_logic;
  signal st_be     : byte_en_t;
  signal st_data   : word_t;

  -- EX/WB pipeline register
  signal wb_valid       : std_logic := '0';
  signal wb_rd_we       : std_logic := '0';
  signal wb_rd          : reg_idx_t := (others => '0');
  signal wb_is_load     : std_logic := '0';
  signal wb_funct3      : funct3_t := (others => '0');
  signal wb_byte_off    : std_logic_vector(1 downto 0) := "00";
  signal wb_exec_result : word_t := ZERO;
  -- Kept only for the retire trace; synthesis removes them when unused.
  signal wb_pc          : word_t := ZERO;
  signal wb_instr       : word_t := INSTR_NOP;
  signal wb_st_be       : byte_en_t := "0000";
  signal wb_mem_addr    : word_t := ZERO;
  signal wb_st_data     : word_t := ZERO;

  -- WB stage
  signal wb_result : word_t;
  signal rf_we     : std_logic;

  signal halted_r     : std_logic := '0';
  signal halt_cause_r : halt_cause_t := HALT_NONE;
  signal halt_pc_r    : word_t := ZERO;

begin

  ---------------------------------------------------------------------------
  -- FD: decode + register read
  ---------------------------------------------------------------------------
  fd_dec <= decode(imem_rdata);

  regfile : entity work.rv32i_regfile
    port map (
      clk    => clk,
      raddr1 => fd_dec.rs1,
      raddr2 => fd_dec.rs2,
      rdata1 => rf_rdata1,
      rdata2 => rf_rdata2,
      we     => rf_we,
      waddr  => wb_rd,
      wdata  => wb_result,
      dbg_addr => dbg_reg_addr,
      dbg_data => dbg_reg_data
    );

  -- The instruction memory registers next_pc, so the redirect from EX takes
  -- effect with a single bubble.
  next_pc <= RESET_VECTOR when rst = '1' else
             ex_target when redirect = '1' else
             std_logic_vector(unsigned(pc_fd) + 4);
  imem_addr <= next_pc;

  ---------------------------------------------------------------------------
  -- EX
  ---------------------------------------------------------------------------
  -- Forwarding. The register file already returns the value being written
  -- back this cycle to FD, so the only producer EX can miss is the
  -- instruction currently in WB. decode() clears rd_we for rd = x0, so a
  -- discarded write to x0 is never forwarded.
  op1 <= wb_result when wb_valid = '1' and wb_rd_we = '1' and wb_rd = ex_dec.rs1 else ex_rs1_val;
  op2 <= wb_result when wb_valid = '1' and wb_rd_we = '1' and wb_rd = ex_dec.rs2 else ex_rs2_val;

  with ex_dec.a_sel select alu_a <=
    op1    when A_RS1,
    ex_pc  when A_PC,
    ZERO   when A_ZERO;

  alu_b <= op2 when ex_dec.b_sel = B_RS2 else ex_dec.imm;

  alu : entity work.rv32i_alu
    port map (
      op => ex_dec.alu_op,
      a  => alu_a,
      b  => alu_b,
      y  => alu_y
    );

  ex_pc4 <= std_logic_vector(unsigned(ex_pc) + 4);

  -- JALR clears bit 0 of the computed address; JAL and branches use a
  -- dedicated PC-relative adder so the ALU stays free for the comparison
  -- operands.
  ex_target <= alu_y(31 downto 1) & '0' when ex_dec.is_jalr = '1' else
               std_logic_vector(unsigned(ex_pc) + unsigned(ex_dec.imm));

  ex_take <= ex_dec.is_jal or ex_dec.is_jalr or
             (ex_dec.is_branch and branch_taken(ex_dec.funct3, op1, op2));

  -- Priority follows the RISC-V exception priority for a single
  -- instruction: decode-time faults first, then address-misaligned.
  -- Bit 0 of a jump target is always cleared (JALR) or zero (immediates),
  -- so only bit 1 can make it misaligned without the C extension.
  process (all)
  begin
    if ex_dec.cause /= HALT_NONE then
      ex_cause <= ex_dec.cause;
    elsif ex_take = '1' and ex_target(1) = '1' then
      ex_cause <= HALT_MISALIGNED_FETCH;
    elsif ex_dec.is_load = '1' and is_misaligned(ex_dec.funct3, alu_y(1 downto 0)) then
      ex_cause <= HALT_MISALIGNED_LOAD;
    elsif ex_dec.is_store = '1' and is_misaligned(ex_dec.funct3, alu_y(1 downto 0)) then
      ex_cause <= HALT_MISALIGNED_STORE;
    else
      ex_cause <= HALT_NONE;
    end if;
  end process;

  ex_fault <= ex_valid when ex_cause /= HALT_NONE else '0';
  ex_go    <= ex_valid when ex_cause = HALT_NONE else '0';
  redirect <= ex_go and ex_take;

  st_be   <= store_byte_enable(ex_dec.funct3, alu_y(1 downto 0))
             when ex_go = '1' and ex_dec.is_store = '1' else "0000";
  st_data <= store_lanes(ex_dec.funct3, op2);

  dmem_addr  <= alu_y;
  dmem_we    <= st_be;
  dmem_wdata <= st_data;

  ---------------------------------------------------------------------------
  -- WB
  ---------------------------------------------------------------------------
  wb_result <= load_extend(dmem_rdata, wb_funct3, wb_byte_off) when wb_is_load = '1' else
               wb_exec_result;
  rf_we <= wb_valid and wb_rd_we;

  ---------------------------------------------------------------------------
  -- Pipeline registers
  ---------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        -- The memory latches RESET_VECTOR during reset, so the first
        -- instruction is valid in FD in the first cycle after reset.
        pc_fd        <= RESET_VECTOR;
        ex_valid     <= '0';
        wb_valid     <= '0';
        halted_r     <= '0';
        halt_cause_r <= HALT_NONE;
        halt_pc_r    <= ZERO;
      elsif halted_r = '0' then
        -- FD -> EX. A redirect or fault in EX squashes the FD instruction.
        pc_fd      <= next_pc;
        ex_valid   <= not redirect and not ex_fault;
        ex_pc      <= pc_fd;
        ex_instr   <= imem_rdata;
        ex_dec     <= fd_dec;
        ex_rs1_val <= rf_rdata1;
        ex_rs2_val <= rf_rdata2;

        -- EX -> WB
        wb_valid    <= ex_go;
        wb_rd_we    <= ex_dec.rd_we;
        wb_rd       <= ex_dec.rd;
        wb_is_load  <= ex_dec.is_load;
        wb_funct3   <= ex_dec.funct3;
        wb_byte_off <= alu_y(1 downto 0);
        if ex_dec.wb_pc4 = '1' then
          wb_exec_result <= ex_pc4;
        else
          wb_exec_result <= alu_y;
        end if;
        wb_pc       <= ex_pc;
        wb_instr    <= ex_instr;
        wb_st_be    <= st_be;
        wb_mem_addr <= alu_y;
        wb_st_data  <= st_data;

        -- On a fault, the older instruction in WB commits on this edge,
        -- wb_valid <= ex_go drops the faulting one, and the frozen pipeline
        -- keeps everything younger out of WB: the halt is precise.
        if ex_fault = '1' then
          halted_r     <= '1';
          halt_cause_r <= ex_cause;
          halt_pc_r    <= ex_pc;
        end if;
      end if;
    end if;
  end process;

  halted     <= halted_r;
  halt_cause <= halt_cause_r;
  halt_pc    <= halt_pc_r;

  retire.valid    <= wb_valid;
  retire.pc       <= wb_pc;
  retire.instr    <= wb_instr;
  retire.rd_we    <= wb_rd_we;
  retire.rd       <= wb_rd;
  retire.rd_data  <= wb_result;
  retire.st_be    <= wb_st_be;
  retire.mem_addr <= wb_mem_addr;
  retire.st_data  <= wb_st_data;

end architecture rtl;
