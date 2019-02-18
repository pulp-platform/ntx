-- Copyright 2017-2019 ETH Zurich and University of Bologna.
--
-- Copyright and related rights are licensed under the Solderpad Hardware
-- License, Version 0.51 (the "License"); you may not use this file except in
-- compliance with the License.  You may obtain a copy of the License at
-- http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-- or agreed to in writing, software, hardware and materials distributed under
-- this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-- CONDITIONS OF ANY KIND, either express or implied. See the License for the
-- specific language governing permissions and limitations under the License.
--
-- Michael Schaffner (schaffner@iis.ee.ethz.ch)
-- Fabian Schuiki (fschuiki@iis.ee.ethz.ch)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

package ntx_pkg is

-----------------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------------

  -- latencies
  constant C_FP32_MAC_LAT             : natural := 2*C_FP32_PCS_N_SEGS + 6 ; -- should be 10 at the moment

  -- FIFO Depths
  constant C_NST_JOB_FIFO_DEPTH       : natural := 1;
  constant C_FPU_TCDM_READ_LATENCY    : natural := 1;
  -- use depth 8 for FPGA
  -- use depth 5 for ASIC
  constant C_FPU_INPUT_FIFO_DEPTH     : natural := 5;
  -- use depth 8 for FPGA
  -- use depth 7 for ASIC
  constant C_FPU_OUTPUT_FIFO_DEPTH    : natural := 7;
  constant C_FPU_INPUT_FIFO_ALM_FULL  : natural := C_FPU_INPUT_FIFO_DEPTH-C_FPU_TCDM_READ_LATENCY-1;
  constant C_FPU_WB_THRESH            : natural := 1;

  -- address generation
  constant C_N_HW_LOOPS               : natural := 5;
  constant C_HW_LOOP_WIDTH            : natural := 16;
  constant C_N_AGUS                   : natural := 3;
  constant C_AGU_ADDR_WIDTH           : natural := 18; -- (word aligned!) 1MByte
  constant C_ADDR_WIDTH               : natural := 32;
  constant C_DATA_WIDTH               : natural := C_FP32_WIDTH;
  constant C_BYTE_ENABLE_WIDTH        : natural := C_DATA_WIDTH/8;

  -- ALU counter for argmax/min
  constant C_NST_FPU_ALU_CNT_WIDTH    : natural := 16;

  -- address map for NTX
  -- status register is not writeable
  -- cmd register is not readable
  -- a masked write to the IRQ reg clears the corresponding interrupt bit
  -- do not change these addresses, unless you know what you are doing!
  constant C_REG_ADDR_WIDTH           : natural := 5;
  constant C_NST_STAT_REG             : natural := 4 * 16#00#;
  constant C_NST_CTRL_REG             : natural := 4 * 16#01#;
  constant C_NST_CMD_REG              : natural := 4 * 16#02#;-- NTX command triggers execution!
  constant C_NST_IRQ_REG              : natural := 4 * 16#03#;
  constant C_NST_LOOP_REGS            : natural := 4 * 16#04#;-- LOOP Bound 0,1,2,3,4
  constant C_NST_AGU0_REGS            : natural := 4 * 16#09#;-- Offset, S0, S1, S2, S3, S4
  constant C_NST_AGU1_REGS            : natural := 4 * 16#0F#;-- Offset, S0, S1, S2, S3, S4
  constant C_NST_AGU2_REGS            : natural := 4 * 16#15#;-- Offset, S0, S1, S2, S3, S4

  -- NTX commands
  constant C_N_NST_OPCODES            : natural := 9;
  constant C_NST_MAC_OP               : natural := 0;
  constant C_NST_VADDSUB_OP           : natural := 1;
  constant C_NST_VMULT_OP             : natural := 2;
  constant C_NST_OUTERP_OP            : natural := 3;
  constant C_NST_MAXMIN_OP            : natural := 4;
  constant C_NST_THTST_OP             : natural := 5;
  constant C_NST_MASK_OP              : natural := 6;
  constant C_NST_MASKMAC_OP           : natural := 7;
  constant C_NST_COPY_OP              : natural := 8;


-----------------------------------------------------------------------------
-- Types
-----------------------------------------------------------------------------

  constant C_FPU_CMD_WDITH    : natural := 22;
  constant C_NST_OPCODE_WIDTH : natural := log2ceil(C_N_NST_OPCODES);
  constant C_NST_CMD_WIDTH    : natural := C_NST_OPCODE_WIDTH + 8 + 3*log2ceil(C_N_HW_LOOPS+1);
  constant C_NST_JOB_WIDTH    : natural := C_NST_CMD_WIDTH                +
                                           C_N_HW_LOOPS * C_HW_LOOP_WIDTH +
                                           C_N_AGUS * (C_N_HW_LOOPS+1) * C_AGU_ADDR_WIDTH;

  type T_FPU_CMD is record
      opAReEn       : std_logic;
      opBReEn       : std_logic;
      macOpBSel     : std_logic_vector(1 downto 0);
      macAccuEn     : std_logic;
      macAccuSel    : std_logic;
      macSubEn      : std_logic;
      macNormEn     : std_logic;
      macReLuEn     : std_logic;
      macCondEn     : std_logic;
      aluAccuCntEn  : std_logic;
      aluCntEqEn    : std_logic;
      aluLtEqSel    : std_logic_vector(1 downto 0);
      aluInvRes     : std_logic;
      aluAccuEn     : std_logic;
      aluAccuSet    : std_logic;
      aluRegMuxSel  : std_logic_vector(1 downto 0);
      aluOutMuxSel  : std_logic;
      aluOutVld     : std_logic;
      fpuWbIrq      : std_logic;
  end record;

  constant C_FPU_NOP_CMD : T_FPU_CMD := (macOpBSel       => "00",
                                         aluRegMuxSel    => "00",
                                         aluLtEqSel      => "00",
                                         others          => '0');

  subtype T_NST_OPCODE is unsigned(C_NST_OPCODE_WIDTH-1 downto 0);

  type T_LOOP_ARRAY         is array(natural range <>) of unsigned(C_HW_LOOP_WIDTH-1 downto 0);
  type T_AGU_ADDRESS_ARRAY  is array(natural range <>) of unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
  type T_DATA_ARRAY         is array(natural range <>) of std_logic_vector(C_DATA_WIDTH-1 downto 0);

  type T_NST_CMD is record
    polarity    : std_logic;            -- 0: positive, 1: negative (use to switch between ADD/SUB and MAX/MIN)
    irqCfg      : unsigned(1 downto 0); -- 00: no IRQ, 01: raise after CMD completion, 10: raise after WB completion
    auxFunc     : unsigned(2 downto 0); -- auxiliary function selection, used to add switch on additional functionality. when set together with a MAC operation, this results in a Relu operation right at the output. when set together with MAXMIN, this produces AMAX or AMIN instead.
    initSel     : unsigned(1 downto 0); -- 00: AGU0, 01: AGU1, 10: AGU2, 11: zero (0.0)
    outerLevel  : unsigned(log2ceil(C_N_HW_LOOPS+1) - 1 downto 0);
    innerLevel  : unsigned(log2ceil(C_N_HW_LOOPS+1) - 1 downto 0);
    initLevel   : unsigned(log2ceil(C_N_HW_LOOPS+1) - 1 downto 0);
    opCode      : T_NST_OPCODE; -- opcode
  end record;

  type T_NST_JOB is record
    nstCmd    : T_NST_CMD;
    loopEnd   : T_LOOP_ARRAY(C_N_HW_LOOPS-1 downto 0);
    aguBase   : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
    aguStride : T_AGU_ADDRESS_ARRAY(C_N_HW_LOOPS*C_N_AGUS-1 downto 0);
  end record;

-----------------------------------------------------------------------------
-- Conversion Functions
-----------------------------------------------------------------------------

  function fpuCmd2slv (inval : T_FPU_CMD) return std_logic_vector;
  function slv2fpuCmd (inval : std_logic_vector(C_FPU_CMD_WDITH - 1 downto 0)) return T_FPU_CMD;

  function nstCmd2slv (inval : T_NST_CMD) return std_logic_vector;
  function slv2nstCmd (inval : std_logic_vector(C_NST_CMD_WIDTH-1 downto 0)) return T_NST_CMD;

  function nstJob2slv (inval : T_NST_JOB) return std_logic_vector;
  function slv2nstJob (inval : std_logic_vector(C_NST_JOB_WIDTH-1 downto 0)) return T_NST_JOB;

end package ntx_pkg;




package body ntx_pkg is

-----------------------------------------------------------------------------
-- fpuCmd conversion
-----------------------------------------------------------------------------

  function fpuCmd2slv(inval : T_FPU_CMD) return std_logic_vector is
    variable outval : std_logic_vector(C_FPU_CMD_WDITH - 1 downto 0);
  begin
    outval(21)           := inval.opAReEn;
    outval(20)           := inval.opBReEn;
    outval(19)           := inval.fpuWbIrq;
    outval(18 downto 17) := inval.macOpBSel;
    outval(16)           := inval.macAccuEn;
    outval(15)           := inval.macAccuSel;
    outval(14)           := inval.macSubEn;
    outval(13)           := inval.macNormEn;
    outval(12)           := inval.macReLuEn;
    outval(11)           := inval.macCondEn;
    outval(10)           := inval.aluAccuCntEn;
    outval(9)            := inval.aluCntEqEn;
    outval(8 downto 7)   := inval.aluLtEqSel;
    outval(6)            := inval.aluInvRes;
    outval(5)            := inval.aluAccuEn;
    outval(4)            := inval.aluAccuSet;
    outval(3 downto 2)   := inval.aluRegMuxSel;
    outval(1)            := inval.aluOutMuxSel;
    outval(0)            := inval.aluOutVld;
    return outval;
  end fpuCmd2slv;

  function slv2fpuCmd(inval : std_logic_vector(C_FPU_CMD_WDITH - 1 downto 0)) return T_FPU_CMD is
    variable outval : T_FPU_CMD;
  begin
    outval.opAReEn           := inval(21)          ;
    outval.opBReEn           := inval(20)          ;
    outval.fpuWbIrq          := inval(19)          ;
    outval.macOpBSel         := inval(18 downto 17);
    outval.macAccuEn         := inval(16)          ;
    outval.macAccuSel        := inval(15)          ;
    outval.macSubEn          := inval(14)          ;
    outval.macNormEn         := inval(13)          ;
    outval.macReLuEn         := inval(12)          ;
    outval.macCondEn         := inval(11)          ;
    outval.aluAccuCntEn      := inval(10)          ;
    outval.aluCntEqEn        := inval(9)           ;
    outval.aluLtEqSel        := inval(8 downto 7)  ;
    outval.aluInvRes         := inval(6)           ;
    outval.aluAccuEn         := inval(5)           ;
    outval.aluAccuSet        := inval(4)           ;
    outval.aluRegMuxSel      := inval(3 downto 2)  ;
    outval.aluOutMuxSel      := inval(1)           ;
    outval.aluOutVld         := inval(0)           ;
    return outval;
  end slv2fpuCmd;

-----------------------------------------------------------------------------
-- nstCmd conversion
-----------------------------------------------------------------------------

  function nstCmd2slv(inval : T_NST_CMD) return std_logic_vector is
    variable outval : std_logic_vector(C_NST_CMD_WIDTH - 1 downto 0);
  begin
    outval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+7)                                                        := inval.polarity;
    outval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+6 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+5) := std_logic_vector(inval.irqCfg);
    outval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+4 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+2) := std_logic_vector(inval.auxFunc);
    outval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+1 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+0) := std_logic_vector(inval.initSel);
    outval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)-1 downto 2*log2ceil(C_N_HW_LOOPS+1)+C_NST_OPCODE_WIDTH)   := std_logic_vector(inval.outerLevel);
    outval(C_NST_OPCODE_WIDTH+2*log2ceil(C_N_HW_LOOPS+1)-1 downto 1*log2ceil(C_N_HW_LOOPS+1)+C_NST_OPCODE_WIDTH)   := std_logic_vector(inval.innerLevel);
    outval(C_NST_OPCODE_WIDTH+1*log2ceil(C_N_HW_LOOPS+1)-1 downto C_NST_OPCODE_WIDTH)                              := std_logic_vector(inval.initLevel);
    outval(C_NST_OPCODE_WIDTH-1 downto 0)                                                                          := std_logic_vector(inval.opCode);
    return outval;
  end nstCmd2slv;

  function slv2nstCmd(inval : std_logic_vector(C_NST_CMD_WIDTH - 1 downto 0)) return T_NST_CMD is
    variable outval : T_NST_CMD;
  begin
    outval.polarity    := inval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+7);
    outval.irqCfg      := unsigned(inval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+6 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+5));
    outval.auxFunc     := unsigned(inval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+4 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+2));
    outval.initSel     := unsigned(inval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+1 downto C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)+0));
    outval.outerLevel  := unsigned(inval(C_NST_OPCODE_WIDTH+3*log2ceil(C_N_HW_LOOPS+1)-1 downto 2*log2ceil(C_N_HW_LOOPS+1)+C_NST_OPCODE_WIDTH));
    outval.innerLevel  := unsigned(inval(C_NST_OPCODE_WIDTH+2*log2ceil(C_N_HW_LOOPS+1)-1 downto 1*log2ceil(C_N_HW_LOOPS+1)+C_NST_OPCODE_WIDTH));
    outval.initLevel   := unsigned(inval(C_NST_OPCODE_WIDTH+1*log2ceil(C_N_HW_LOOPS+1)-1 downto C_NST_OPCODE_WIDTH));
    outval.opCode      := unsigned(inval(C_NST_OPCODE_WIDTH-1 downto 0));
    return outval;
  end slv2nstCmd;

-----------------------------------------------------------------------------
-- nstJob conversion
-----------------------------------------------------------------------------

  function nstJob2slv(inval : T_NST_JOB) return std_logic_vector is
    variable outval : std_logic_vector(C_NST_JOB_WIDTH - 1 downto 0);
    variable offset : natural;
  begin

    outval(C_NST_CMD_WIDTH-1 downto 0) := nstCmd2slv(inval.nstCmd);

    offset          := C_NST_CMD_WIDTH;
    for k in 0 to C_N_HW_LOOPS-1 loop
      outval((k+1) * C_HW_LOOP_WIDTH + offset -1 downto k * C_HW_LOOP_WIDTH + offset) := std_logic_vector(inval.loopEnd(k));
    end loop;

    offset          := C_NST_CMD_WIDTH + C_N_HW_LOOPS * C_HW_LOOP_WIDTH;
    for k in 0 to C_N_AGUS-1 loop
       outval((k+1) * C_AGU_ADDR_WIDTH + offset -1 downto k * C_AGU_ADDR_WIDTH + offset) := std_logic_vector(inval.aguBase(k));
    end loop;

    offset          := C_NST_CMD_WIDTH + C_N_HW_LOOPS * C_HW_LOOP_WIDTH + C_N_AGUS*C_AGU_ADDR_WIDTH;
    for k in 0 to C_N_AGUS*C_N_HW_LOOPS-1 loop

      outval((k+1) * C_AGU_ADDR_WIDTH + offset -1 downto k * C_AGU_ADDR_WIDTH + offset) := std_logic_vector(inval.aguStride(k));
    end loop;

    return outval;
  end nstJob2slv;

  function slv2nstJob(inval : std_logic_vector(C_NST_JOB_WIDTH - 1 downto 0)) return T_NST_JOB is
    variable outval : T_NST_JOB;
    variable offset : natural;
  begin

    outval.nstCmd := slv2nstCmd(inval(C_NST_CMD_WIDTH-1 downto 0));

    offset          := C_NST_CMD_WIDTH;
    for k in 0 to C_N_HW_LOOPS-1 loop
      outval.loopEnd(k) := unsigned(inval((k+1) * C_HW_LOOP_WIDTH + offset -1 downto k * C_HW_LOOP_WIDTH + offset));
    end loop;

    offset          := C_NST_CMD_WIDTH + C_N_HW_LOOPS * C_HW_LOOP_WIDTH;
    for k in 0 to C_N_AGUS-1 loop
      outval.aguBase(k) := unsigned(inval((k+1) * C_AGU_ADDR_WIDTH + offset -1 downto k * C_AGU_ADDR_WIDTH + offset));
    end loop;

    offset          := C_NST_CMD_WIDTH + C_N_HW_LOOPS * C_HW_LOOP_WIDTH + C_N_AGUS*C_AGU_ADDR_WIDTH;
    for k in 0 to C_N_AGUS*C_N_HW_LOOPS-1 loop
      outval.aguStride(k) := unsigned(inval((k+1) * C_AGU_ADDR_WIDTH + offset -1 downto k * C_AGU_ADDR_WIDTH + offset));
    end loop;

    return outval;
  end slv2nstJob;

end ntx_pkg;


