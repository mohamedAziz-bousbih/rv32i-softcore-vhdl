-- rv32i_pkg: shared types, encodings and pure helper functions for the core.
--
-- Everything that is combinational and stateless (instruction decode,
-- immediate generation, branch condition, load/store lane handling) lives
-- here as functions so the pipeline in rv32i_core reads like a block diagram.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package rv32i_pkg is

  subtype word_t is std_logic_vector(31 downto 0);
  type word_array_t is array (natural range <>) of word_t;
  subtype reg_idx_t is std_logic_vector(4 downto 0);
  subtype funct3_t is std_logic_vector(2 downto 0);
  subtype byte_en_t is std_logic_vector(3 downto 0);

  -- Major opcodes (instr[6:0]) of the RV32I base ISA.
  constant OPC_LUI      : std_logic_vector(6 downto 0) := "0110111";
  constant OPC_AUIPC    : std_logic_vector(6 downto 0) := "0010111";
  constant OPC_JAL      : std_logic_vector(6 downto 0) := "1101111";
  constant OPC_JALR     : std_logic_vector(6 downto 0) := "1100111";
  constant OPC_BRANCH   : std_logic_vector(6 downto 0) := "1100011";
  constant OPC_LOAD     : std_logic_vector(6 downto 0) := "0000011";
  constant OPC_STORE    : std_logic_vector(6 downto 0) := "0100011";
  constant OPC_OP_IMM   : std_logic_vector(6 downto 0) := "0010011";
  constant OPC_OP       : std_logic_vector(6 downto 0) := "0110011";
  constant OPC_MISC_MEM : std_logic_vector(6 downto 0) := "0001111";
  constant OPC_SYSTEM   : std_logic_vector(6 downto 0) := "1110011";

  -- ALU operation = {instr[30], funct3}. Reusing the instruction bits means
  -- the decoder needs no translation table for OP/OP-IMM; only ADDI must
  -- force bit 3 to zero because instr[30] is an immediate bit there.
  subtype alu_op_t is std_logic_vector(3 downto 0);
  constant ALU_ADD  : alu_op_t := "0000";
  constant ALU_SUB  : alu_op_t := "1000";
  constant ALU_SLL  : alu_op_t := "0001";
  constant ALU_SLT  : alu_op_t := "0010";
  constant ALU_SLTU : alu_op_t := "0011";
  constant ALU_XOR  : alu_op_t := "0100";
  constant ALU_SRL  : alu_op_t := "0101";
  constant ALU_SRA  : alu_op_t := "1101";
  constant ALU_OR   : alu_op_t := "0110";
  constant ALU_AND  : alu_op_t := "0111";

  -- Load/store width encodings (funct3).
  constant F3_B  : funct3_t := "000";
  constant F3_H  : funct3_t := "001";
  constant F3_W  : funct3_t := "010";
  constant F3_BU : funct3_t := "100";
  constant F3_HU : funct3_t := "101";

  type a_sel_t is (A_RS1, A_PC, A_ZERO);
  type b_sel_t is (B_RS2, B_IMM);

  -- Reasons for the core to stop. The core implements no privileged
  -- architecture (no CSRs, no trap vector), so every exception condition
  -- freezes the pipeline and is reported on the halt outputs instead.
  type halt_cause_t is (
    HALT_NONE,
    HALT_ECALL,
    HALT_EBREAK,
    HALT_ILLEGAL,
    HALT_MISALIGNED_FETCH,
    HALT_MISALIGNED_LOAD,
    HALT_MISALIGNED_STORE
  );

  type decoded_t is record
    rs1       : reg_idx_t;
    rs2       : reg_idx_t;
    rd        : reg_idx_t;
    funct3    : funct3_t;
    imm       : word_t;
    rd_we     : std_logic;  -- writes a register other than x0
    alu_op    : alu_op_t;
    a_sel     : a_sel_t;
    b_sel     : b_sel_t;
    wb_pc4    : std_logic;  -- result is the link address pc+4 (JAL/JALR)
    is_load   : std_logic;
    is_store  : std_logic;
    is_branch : std_logic;
    is_jal    : std_logic;
    is_jalr   : std_logic;
    cause     : halt_cause_t;  -- ECALL/EBREAK/illegal detected at decode
  end record;

  -- Architectural effects of one retired instruction, exported for the
  -- testbench's commit trace (lockstep comparison with the Python model).
  type retire_t is record
    valid    : std_logic;
    pc       : word_t;
    instr    : word_t;
    rd_we    : std_logic;
    rd       : reg_idx_t;
    rd_data  : word_t;
    st_be    : byte_en_t;  -- "0000" unless the instruction is a store
    mem_addr : word_t;     -- ALU result: the effective address of a load or store
    st_data  : word_t;     -- store data as driven onto the byte lanes
  end record;

  function imm_i(instr : word_t) return word_t;
  function imm_s(instr : word_t) return word_t;
  function imm_b(instr : word_t) return word_t;
  function imm_u(instr : word_t) return word_t;
  function imm_j(instr : word_t) return word_t;

  function decode(instr : word_t) return decoded_t;

  function branch_taken(f3 : funct3_t; a, b : word_t) return std_logic;

  function load_extend(word : word_t; f3 : funct3_t;
                       byte_off : std_logic_vector(1 downto 0)) return word_t;
  function store_byte_enable(f3 : funct3_t;
                             byte_off : std_logic_vector(1 downto 0)) return byte_en_t;
  function store_lanes(f3 : funct3_t; data : word_t) return word_t;
  function is_misaligned(f3 : funct3_t;
                         byte_off : std_logic_vector(1 downto 0)) return boolean;

end package rv32i_pkg;

package body rv32i_pkg is

  function sext(v : std_logic_vector) return word_t is
  begin
    return std_logic_vector(resize(signed(v), 32));
  end function;

  function imm_i(instr : word_t) return word_t is
  begin
    return sext(instr(31 downto 20));
  end function;

  function imm_s(instr : word_t) return word_t is
  begin
    return sext(instr(31 downto 25) & instr(11 downto 7));
  end function;

  function imm_b(instr : word_t) return word_t is
  begin
    return sext(instr(31) & instr(7) & instr(30 downto 25) & instr(11 downto 8) & '0');
  end function;

  function imm_u(instr : word_t) return word_t is
  begin
    return instr(31 downto 12) & x"000";
  end function;

  function imm_j(instr : word_t) return word_t is
  begin
    return sext(instr(31) & instr(19 downto 12) & instr(20) & instr(30 downto 21) & '0');
  end function;

  function decode(instr : word_t) return decoded_t is
    variable d  : decoded_t;
    variable f3 : funct3_t;
    variable f7 : std_logic_vector(6 downto 0);
  begin
    f3 := instr(14 downto 12);
    f7 := instr(31 downto 25);

    d.rs1       := instr(19 downto 15);
    d.rs2       := instr(24 downto 20);
    d.rd        := instr(11 downto 7);
    d.funct3    := f3;
    d.imm       := imm_i(instr);
    d.rd_we     := '0';
    d.alu_op    := ALU_ADD;
    d.a_sel     := A_RS1;
    d.b_sel     := B_IMM;
    d.wb_pc4    := '0';
    d.is_load   := '0';
    d.is_store  := '0';
    d.is_branch := '0';
    d.is_jal    := '0';
    d.is_jalr   := '0';
    d.cause     := HALT_NONE;

    case instr(6 downto 0) is
      when OPC_LUI =>
        d.rd_we := '1';
        d.a_sel := A_ZERO;
        d.imm   := imm_u(instr);

      when OPC_AUIPC =>
        d.rd_we := '1';
        d.a_sel := A_PC;
        d.imm   := imm_u(instr);

      when OPC_JAL =>
        d.rd_we  := '1';
        d.wb_pc4 := '1';
        d.is_jal := '1';
        d.imm    := imm_j(instr);

      when OPC_JALR =>
        if f3 = "000" then
          d.rd_we   := '1';
          d.wb_pc4  := '1';
          d.is_jalr := '1';
        else
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_BRANCH =>
        -- funct3 010 and 011 are reserved.
        if f3(2 downto 1) /= "01" then
          d.is_branch := '1';
          d.imm       := imm_b(instr);
        else
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_LOAD =>
        if f3 = F3_B or f3 = F3_H or f3 = F3_W or f3 = F3_BU or f3 = F3_HU then
          d.rd_we   := '1';
          d.is_load := '1';
        else
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_STORE =>
        if f3 = F3_B or f3 = F3_H or f3 = F3_W then
          d.is_store := '1';
          d.imm      := imm_s(instr);
        else
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_OP_IMM =>
        d.rd_we  := '1';
        d.alu_op := '0' & f3;
        if f3 = "001" then
          -- SLLI: shamt[5] would be RV64 only, so all of funct7 must be zero.
          if f7 /= "0000000" then
            d.cause := HALT_ILLEGAL;
          end if;
        elsif f3 = "101" then
          -- SRLI / SRAI, distinguished by instr[30].
          if f7 = "0000000" or f7 = "0100000" then
            d.alu_op := instr(30) & f3;
          else
            d.cause := HALT_ILLEGAL;
          end if;
        end if;

      when OPC_OP =>
        d.rd_we  := '1';
        d.b_sel  := B_RS2;
        d.alu_op := instr(30) & f3;
        if not (f7 = "0000000" or (f7 = "0100000" and (f3 = "000" or f3 = "101"))) then
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_MISC_MEM =>
        -- FENCE orders memory accesses. This core issues at most one access
        -- per cycle, in program order, to memories without caches, so the
        -- ordering is already guaranteed and FENCE retires as a no-op.
        -- FENCE.I (funct3 001) belongs to Zifencei and is not implemented.
        if f3 /= "000" then
          d.cause := HALT_ILLEGAL;
        end if;

      when OPC_SYSTEM =>
        if instr = x"00000073" then
          d.cause := HALT_ECALL;
        elsif instr = x"00100073" then
          d.cause := HALT_EBREAK;
        else
          -- CSR instructions (Zicsr) and other SYSTEM encodings.
          d.cause := HALT_ILLEGAL;
        end if;

      when others =>
        -- Includes 16-bit (compressed) encodings and the all-zero word.
        d.cause := HALT_ILLEGAL;
    end case;

    -- x0 is hard-wired to zero: treating "rd = x0" as "no write" here means
    -- neither the register file nor the forwarding network needs to care.
    if d.rd = "00000" then
      d.rd_we := '0';
    end if;

    return d;
  end function;

  function branch_taken(f3 : funct3_t; a, b : word_t) return std_logic is
    variable cond : boolean;
  begin
    -- funct3[2:1] selects the comparison, funct3[0] inverts it:
    -- BEQ/BNE, BLT/BGE, BLTU/BGEU.
    case f3(2 downto 1) is
      when "00"   => cond := a = b;
      when "10"   => cond := signed(a) < signed(b);
      when "11"   => cond := unsigned(a) < unsigned(b);
      when others => cond := false;
    end case;
    if cond /= (f3(0) = '1') then
      return '1';
    end if;
    return '0';
  end function;

  function load_extend(word : word_t; f3 : funct3_t;
                       byte_off : std_logic_vector(1 downto 0)) return word_t is
    variable shifted : word_t;
  begin
    shifted := std_logic_vector(shift_right(unsigned(word), 8 * to_integer(unsigned(byte_off))));
    case f3 is
      when F3_B   => return sext(shifted(7 downto 0));
      when F3_H   => return sext(shifted(15 downto 0));
      when F3_BU  => return std_logic_vector(resize(unsigned(shifted(7 downto 0)), 32));
      when F3_HU  => return std_logic_vector(resize(unsigned(shifted(15 downto 0)), 32));
      when others => return word;
    end case;
  end function;

  function store_byte_enable(f3 : funct3_t;
                             byte_off : std_logic_vector(1 downto 0)) return byte_en_t is
  begin
    case f3(1 downto 0) is
      when "00" =>
        return std_logic_vector(shift_left(to_unsigned(1, 4), to_integer(unsigned(byte_off))));
      when "01" =>
        if byte_off(1) = '0' then
          return "0011";
        end if;
        return "1100";
      when others =>
        return "1111";
    end case;
  end function;

  function store_lanes(f3 : funct3_t; data : word_t) return word_t is
  begin
    -- Replicate the datum into every lane it may occupy; the byte enables
    -- then pick the right one. Keeps the store path free of a shifter.
    case f3(1 downto 0) is
      when "00"   => return data(7 downto 0) & data(7 downto 0) & data(7 downto 0) & data(7 downto 0);
      when "01"   => return data(15 downto 0) & data(15 downto 0);
      when others => return data;
    end case;
  end function;

  function is_misaligned(f3 : funct3_t;
                         byte_off : std_logic_vector(1 downto 0)) return boolean is
  begin
    case f3(1 downto 0) is
      when "01"   => return byte_off(0) = '1';
      when "10"   => return byte_off /= "00";
      when others => return false;
    end case;
  end function;

end package body rv32i_pkg;
