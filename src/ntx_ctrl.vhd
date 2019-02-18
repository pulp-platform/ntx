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

-- Note: write valid responses are ignored!

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ntx_pkg.all;
use work.ntx_tools_pkg.all;

-- pragma translate_off
use std.textio.all;
-- pragma translate_on

entity ntx_ctrl is
  generic (
    -- for simulation purposes only
    G_NST_ID              : string  := "NTX";
    G_VERBOSE             : boolean := false;
    G_TARGET              : natural := 1
    );
  port (
    --------------------------
    Clk_CI                : in  std_logic;
    Rst_RBI               : in  std_logic;
    -- synchronous clear
    Clr_SI                : in  std_logic;
    -- status
    Idle_SO               : out std_logic;
    CmdIrq_SO             : out std_logic;
    InvCmd_SO             : out std_logic;
    -- operand fetch
    Tcdm0RReq_SO          : out std_logic;
    Tcdm0RAck_SI          : in  std_logic;
    Tcdm0RAddr_DO         : out unsigned(C_ADDR_WIDTH-1 downto 0);
    Tcdm1RReq_SO          : out std_logic;
    Tcdm1RAck_SI          : in  std_logic;
    Tcdm1RAddr_DO         : out unsigned(C_ADDR_WIDTH-1 downto 0);
    -- from regIf
    NstJob_DI             : in  T_NST_JOB;
    NstJobEmpty_SI        : in  std_logic;
    NstJobReEn_SO         : out std_logic;
    -- to FPU
    FpuCmd_DO             : out T_FPU_CMD;
    FpuCmdReEn_SI         : in  std_logic;
    FpuCmdWrEn_SO         : out std_logic;
    FpuWbAddrWrEn_SO      : out std_logic;
    -- to DAG
    DagDataAddr_DI        : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
    DagStepEn_SO          : out std_logic;
    DagInit_SO            : out std_logic;
    DagLoopStartTrig_SI   : in  std_logic_vector(C_N_HW_LOOPS downto 0);
    DagLoopEndTrig_SI     : in  std_logic_vector(C_N_HW_LOOPS downto 0)
    --------------------------
    );
end entity ntx_ctrl;


architecture RTL of ntx_ctrl is

    -- masking of DAG triggers
    signal InitTrigMask_S                : std_logic_vector(C_N_HW_LOOPS downto 0);
    signal StoreTrigMask_S               : std_logic_vector(C_N_HW_LOOPS downto 0);
    signal DoneTrigMask_S                : std_logic_vector(C_N_HW_LOOPS downto 0);
    signal InitTrig_S                    : std_logic;
    signal StoreTrig_S                   : std_logic;
    signal DoneTrig_S                    : std_logic;

    -- other control signals
    signal InvCmd_S                      : std_logic;
    signal InvOpCode_SN, InvOpCode_SP    : std_logic;
    signal FpuCmdSel_S                   : std_logic;

    signal FpuCmd_D                      : T_FPU_CMD;
    signal OpAAguSel_S                   : unsigned(log2ceil(C_N_AGUS)-1 downto 0);

    signal FpuCmdWrEn_S                  : std_logic;

    signal Tcdm0RAddr_D                  : unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
    signal Tcdm0RReq_SB                  : std_logic;
    signal Tcdm0WrEn_S                   : std_logic;

    signal Tcdm1RReq_SB                  : std_logic;
    signal Tcdm1WrEn_S                   : std_logic;

    -- IRQ triggers
    signal RaiseWbIrq_S        : std_logic;
    signal RaiseCmdIrq_S       : std_logic;

    -- special types
    type T_STATE is (IDLE, INIT_STEP, CALC_STEP, INV_CMD);
    signal State_SP, State_SN  : T_STATE;

    type T_FPU_CMD_LUT is array(natural range <>) of T_FPU_CMD;
    signal FpuCmdInitLut_D     : T_FPU_CMD_LUT(C_N_NST_OPCODES-1 downto 0);
    signal FpuCmdStepLut_D     : T_FPU_CMD_LUT(C_N_NST_OPCODES-1 downto 0);

    type T_AGU_SEL_LUT is array(natural range <>) of unsigned(log2ceil(C_N_AGUS)-1 downto 0);
    signal Agu0InitLut_D       : T_AGU_SEL_LUT(C_N_NST_OPCODES-1 downto 0);
    signal Agu0StepLut_D       : T_AGU_SEL_LUT(C_N_NST_OPCODES-1 downto 0);
    signal InitCycleLut_D      : std_logic_vector(C_N_NST_OPCODES-1 downto 0);

    signal DoInitCycle_S       : std_logic;
    signal DoInitLoad_S        : std_logic;

    signal OpCode_D            : T_NST_OPCODE;

    signal CmdInFlight_DN, CmdInFlight_DP : unsigned(log2ceil(C_FPU_INPUT_FIFO_DEPTH+1)-1 downto 0);
    signal Stall_S             : std_logic;

begin
----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------

--synopsys translate_off
  assert not ((NstJob_DI.nstCmd.initLevel > NstJob_DI.nstCmd.outerLevel) and (Clk_CI'event and Clk_CI = '1') and NstJobEmpty_SI = '0')
    report G_NST_ID & ": invalid loop nest specification"   severity failure;
  assert not ((NstJob_DI.nstCmd.innerLevel > NstJob_DI.nstCmd.outerLevel) and (Clk_CI'event and Clk_CI = '1') and NstJobEmpty_SI = '0')
    report G_NST_ID & ": invalid loop nest specification"   severity failure;
  assert not ((NstJob_DI.nstCmd.innerLevel > NstJob_DI.nstCmd.initLevel) and (Clk_CI'event and Clk_CI = '1') and NstJobEmpty_SI = '0')
    report G_NST_ID & ": invalid loop nest specification"   severity failure;
  assert not ((OpCode_D >= C_N_NST_OPCODES) and (Clk_CI'event and Clk_CI = '1') and NstJobEmpty_SI = '0')
    report G_NST_ID & ": invalid opcode"   severity failure;
--synopsys translate_on

----------------------------------------------------------------------------
-- some simulation output...
----------------------------------------------------------------------------

-- pragma translate_off
g_dbg : if G_VERBOSE generate
begin
    p_dbg : process
    begin
        while true loop
            wait until Idle_SO'event and Idle_SO = '0';

            report LF & G_NST_ID         & "> executing job with params:"                                                                  & LF &
                        G_NST_ID         & "> opCode: "            & integer'image(to_integer(NstJob_DI.nstCmd.opCode))                    & LF &
                        G_NST_ID         & "> initLevel: "         & integer'image(to_integer(NstJob_DI.nstCmd.initLevel))                 & LF &
                        G_NST_ID         & "> innerLevel: "        & integer'image(to_integer(NstJob_DI.nstCmd.innerLevel))                & LF &
                        G_NST_ID         & "> outerLevel: "        & integer'image(to_integer(NstJob_DI.nstCmd.outerLevel))                & LF &
                        G_NST_ID         & "> initSel: "           & integer'image(to_integer(NstJob_DI.nstCmd.initSel))                   & LF &
                        G_NST_ID         & "> auxFunc: "           & integer'image(to_integer(NstJob_DI.nstCmd.auxFunc))                   & LF &
                        G_NST_ID         & "> irqCfg: "            & integer'image(to_integer(NstJob_DI.nstCmd.irqCfg))                    & LF &
                        G_NST_ID         & "> polarity: "          & std_logic'image(NstJob_DI.nstCmd.polarity)                            & LF &
                        G_NST_ID         & "> loop bounds 4-0: ["  & integer'image(to_integer(NstJob_DI.loopEnd(4)))                & ", " &
                                           " "                     & integer'image(to_integer(NstJob_DI.loopEnd(3)))                & ", " &
                                           " "                     & integer'image(to_integer(NstJob_DI.loopEnd(2)))                & ", " &
                                           " "                     & integer'image(to_integer(NstJob_DI.loopEnd(1)))                & ", " &
                                           " "                     & integer'image(to_integer(NstJob_DI.loopEnd(0)))                & "]"  & LF &
                        G_NST_ID         & "> DAG offsets 2-0: ["  & to_hstring(NstJob_DI.aguBase(2) & "00")                        & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguBase(1) & "00")                        & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguBase(0) & "00")                        & "]"  & LF &
                        G_NST_ID         & "> DAG0 strides 4-0: [" & to_hstring(NstJob_DI.aguStride(0*C_N_HW_LOOPS + 4) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(0*C_N_HW_LOOPS + 3) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(0*C_N_HW_LOOPS + 2) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(0*C_N_HW_LOOPS + 1) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(0*C_N_HW_LOOPS + 0) & "00")     & "]"  & LF &
                        G_NST_ID         & "> DAG1 strides 4-0: [" & to_hstring(NstJob_DI.aguStride(1*C_N_HW_LOOPS + 4) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(1*C_N_HW_LOOPS + 3) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(1*C_N_HW_LOOPS + 2) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(1*C_N_HW_LOOPS + 1) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(1*C_N_HW_LOOPS + 0) & "00")     & "]"  & LF &
                        G_NST_ID         & "> DAG2 strides 4-0: [" & to_hstring(NstJob_DI.aguStride(2*C_N_HW_LOOPS + 4) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(2*C_N_HW_LOOPS + 3) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(2*C_N_HW_LOOPS + 2) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(2*C_N_HW_LOOPS + 1) & "00")     & ", " &
                                           " "                     & to_hstring(NstJob_DI.aguStride(2*C_N_HW_LOOPS + 0) & "00")     & "]"  & LF;
            wait until Idle_SO'event and Idle_SO = '1';
            report LF & G_NST_ID & "> done";
        end loop;
    end process p_dbg;
end generate g_dbg;
-- pragma translate_on


----------------------------------------------------------------------------
-- trigger signals for init, load and store
----------------------------------------------------------------------------

    -- only trigger init load if enabled
    InitTrigMask_S  <= Hot1EncodeDn(NstJob_DI.nstCmd.initLevel, InitTrigMask_S'length);
    InitTrig_S      <= VectorOR(InitTrigMask_S and DagLoopStartTrig_SI) and DoInitCycle_S;

    StoreTrigMask_S <= Hot1EncodeDn(NstJob_DI.nstCmd.innerLevel, StoreTrigMask_S'length);
    StoreTrig_S     <= VectorOR(StoreTrigMask_S and DagLoopEndTrig_SI);

    DoneTrigMask_S  <= not ThermEncodeDn(NstJob_DI.nstCmd.outerLevel, DoneTrigMask_S'length, true);
    DoneTrig_S      <= VectorAND(DoneTrigMask_S or DagLoopEndTrig_SI);


----------------------------------------------------------------------------
-- command LUT definition
----------------------------------------------------------------------------

    ------------------------------------
    --MAC: multiply accumulate/subtract (with or without init load)
    InitCycleLut_D(C_NST_MAC_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_MAC_OP) <= (opAReEn           => DoInitLoad_S,
                                      macAccuEn         => '1',
                                      macAccuSel        => '1',
                                      macOpBSel         => "1" & DoInitLoad_S, -- switch to 1.0 when a value is loaded
                                      aluRegMuxSel      => "00",
                                      aluLtEqSel        => "00",
                                      others            => '0');

    FpuCmdStepLut_D(C_NST_MAC_OP) <= (opAReEn           => '1',
                                      opBReEn           => '1',
                                      macAccuEn         => '1',
                                      macSubEn          => NstJob_DI.nstCmd.polarity,
                                      macReLuEn         => NstJob_DI.nstCmd.auxFunc(0),
                                      macNormEn         => StoreTrig_S,
                                      fpuWbIrq          => RaiseWbIrq_S,
                                      macOpBSel         => "00",
                                      aluRegMuxSel      => "00",
                                      aluLtEqSel        => "00",
                                      others            => '0');

    Agu0InitLut_D(C_NST_MAC_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_MAC_OP) <= "00";

    ------------------------------------
    -- VADDSUB: vector addition/subtraction
    InitCycleLut_D(C_NST_VADDSUB_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_VADDSUB_OP) <= (opAReEn       => DoInitLoad_S,
                                          macAccuEn     => '1',
                                          macAccuSel    => '1',
                                          macOpBSel     => "1" & DoInitLoad_S, -- switch to 1.0 when a value is loaded
                                          macSubEn      => NstJob_DI.nstCmd.polarity,
                                          aluRegMuxSel  => "00",
                                          aluLtEqSel    => "00",
                                          others        => '0');

    FpuCmdStepLut_D(C_NST_VADDSUB_OP) <= (opAReEn       => '1',
                                          macAccuEn     => '1',
                                          macReLuEn     => NstJob_DI.nstCmd.auxFunc(0),
                                          macNormEn     => StoreTrig_S,
                                          fpuWbIrq      => RaiseWbIrq_S,
                                          macOpBSel     => "11",-- 1.0
                                          aluRegMuxSel  => "00",
                                          aluLtEqSel    => "00",
                                          others        => '0');

    Agu0InitLut_D(C_NST_VADDSUB_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_VADDSUB_OP) <= "00";

    ------------------------------------
    -- VMULT: vector multiplication
    InitCycleLut_D(C_NST_VMULT_OP)  <= '0';
    FpuCmdInitLut_D(C_NST_VMULT_OP) <= (macOpBSel       => "00",
                                        aluRegMuxSel    => "00",
                                        aluLtEqSel      => "00",
                                        others          => '0');

    FpuCmdStepLut_D(C_NST_VMULT_OP) <= (opAReEn         => '1',
                                        opBReEn         => '1',
                                        macAccuEn       => '1',
                                        macAccuSel      => '1',
                                        macReLuEn       => NstJob_DI.nstCmd.auxFunc(0),
                                        macNormEn       => StoreTrig_S,
                                        fpuWbIrq        => RaiseWbIrq_S,
                                        macSubEn        => NstJob_DI.nstCmd.polarity,
                                        macOpBSel       => "00",
                                        aluRegMuxSel    => "00",
                                        aluLtEqSel      => "00",
                                        others          => '0');

    Agu0InitLut_D(C_NST_VMULT_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_VMULT_OP) <= "00";

   ------------------------------------
    -- Outer product:
    InitCycleLut_D(C_NST_OUTERP_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_OUTERP_OP) <= (opAReEn       => DoInitLoad_S,
                                         aluAccuSet    => '1',
                                         macOpBSel     => "00",
                                         aluLtEqSel    => "00",
                                         aluRegMuxSel  =>  (not DoInitLoad_S) & "0", -- switch to zero in case no value is loaded
                                         others        => '0');

    FpuCmdStepLut_D(C_NST_OUTERP_OP) <= (opAReEn           => '1',
                                         macAccuEn         => '1',
                                         macAccuSel        => '1',
                                         macSubEn          => NstJob_DI.nstCmd.polarity,
                                         macReLuEn         => NstJob_DI.nstCmd.auxFunc(0),
                                         macNormEn         => StoreTrig_S,
                                         fpuWbIrq          => RaiseWbIrq_S,
                                         aluLtEqSel        => "00",
                                         macOpBSel         => "01",
                                         aluRegMuxSel      => "00",
                                         others            => '0');

    Agu0InitLut_D(C_NST_OUTERP_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_OUTERP_OP) <= "00";

    ------------------------------------
    -- (A)MAXMIN: maximum/minimum command
    InitCycleLut_D(C_NST_MAXMIN_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_MAXMIN_OP) <= (opAReEn       => DoInitLoad_S,
                                         aluAccuSet    => '1',
                                         macOpBSel     => "00",
                                         aluRegMuxSel  => (not DoInitLoad_S) & "0", -- switch to zero in case no value is loaded
                                         aluLtEqSel    => "00",
                                         others        => '0');

    FpuCmdStepLut_D(C_NST_MAXMIN_OP) <= (opBReEn       => '1',
                                         fpuWbIrq      => RaiseWbIrq_S,
                                         aluAccuEn     => '1',
                                         aluLtEqSel    => "01",
                                         aluInvRes     => not NstJob_DI.nstCmd.polarity,
                                         aluOutVld     => StoreTrig_S,
                                         macOpBSel     => "00",
                                         aluRegMuxSel  => "01",
                                         aluOutMuxSel  => NstJob_DI.nstCmd.auxFunc(0),
                                         aluAccuCntEn  => NstJob_DI.nstCmd.auxFunc(0),
                                         others        => '0');

    Agu0InitLut_D(C_NST_MAXMIN_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_MAXMIN_OP) <= "00";

    ------------------------------------
    -- TSTTH: comparison with a constant or thresholding with a constant
    InitCycleLut_D(C_NST_THTST_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_THTST_OP) <= (opAReEn       => DoInitLoad_S,
                                        aluAccuSet    => '1',
                                        macOpBSel     => "00",
                                        aluRegMuxSel  =>  (not DoInitLoad_S) & "0", -- switch to zero in case no value is loaded
                                        aluLtEqSel    => "00",
                                        others        => '0');

    FpuCmdStepLut_D(C_NST_THTST_OP) <= (opBReEn       => '1',
                                        fpuWbIrq      => RaiseWbIrq_S,
                                        aluAccuEn     => '0',-- leave this constant
                                        aluLtEqSel    => std_logic_vector(NstJob_DI.nstCmd.auxFunc(1 downto 0)),
                                        aluInvRes     => NstJob_DI.nstCmd.polarity,
                                        aluOutVld     => StoreTrig_S,
                                        macOpBSel     => "00",
                                        aluRegMuxSel  => NstJob_DI.nstCmd.auxFunc(2) & not NstJob_DI.nstCmd.auxFunc(2),-- select between binary out and thresholding...
                                        aluOutMuxSel  => '0',
                                        others        => '0');

    Agu0InitLut_D(C_NST_THTST_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_THTST_OP) <= "00";

    ------------------------------------
    -- MASK: conditional masking of a second stream
    InitCycleLut_D(C_NST_MASK_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_MASK_OP) <= (opAReEn       => DoInitLoad_S,
                                       aluAccuSet    => '1',
                                       macOpBSel     => "00",
                                       aluRegMuxSel  => (not DoInitLoad_S) & "0", -- switch to zero in case no value is loaded
                                       aluLtEqSel    => "00",
                                       others        => '0');

    FpuCmdStepLut_D(C_NST_MASK_OP) <= (opAReEn       => '1',
                                       opBReEn       => not NstJob_DI.nstCmd.auxFunc(2), -- if we compare to the internal counter, this is not needed...
                                       fpuWbIrq      => RaiseWbIrq_S,
                                       aluAccuEn     => '0',-- leave this constant
                                       aluLtEqSel    => std_logic_vector(NstJob_DI.nstCmd.auxFunc(1 downto 0)),
                                       aluInvRes     => NstJob_DI.nstCmd.polarity,
                                       aluOutVld     => StoreTrig_S,
                                       aluCntEqEn    => NstJob_DI.nstCmd.auxFunc(2),
                                       aluAccuCntEn  => NstJob_DI.nstCmd.auxFunc(2),
                                       macOpBSel     => "00",
                                       aluRegMuxSel  => "00",-- select masking operation of opA (outputs 0.0 if false, outputs opA if true)
                                       others        => '0');

    Agu0InitLut_D(C_NST_MASK_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_MASK_OP) <= "00";

    ------------------------------------
    -- MASKMAC: conditional read-modify write on a second stream
    InitCycleLut_D(C_NST_MASKMAC_OP)  <= '1';
    FpuCmdInitLut_D(C_NST_MASKMAC_OP) <= (opAReEn       => '1',-- always loads this
                                          opBReEn       => DoInitLoad_S,
                                          macAccuEn     => '1',
                                          macAccuSel    => '1',
                                          macOpBSel     => "11",-- switch to 1.0 when a value is loaded
                                          aluAccuSet    => '1',
                                          aluRegMuxSel  => (not DoInitLoad_S) & DoInitLoad_S, -- switch to zero in case no value is loaded from opB
                                          aluLtEqSel    => "00",
                                          others        => '0');

    FpuCmdStepLut_D(C_NST_MASKMAC_OP) <= (opAReEn       => '1',
                                          opBReEn       => not NstJob_DI.nstCmd.auxFunc(2), -- if we compare to the internal counter, this is not needed...
                                          macOpBSel     => "11",
                                          macAccuEn     => '1',
                                          macNormEn     => StoreTrig_S,
                                          macCondEn     => '1',
                                          aluLtEqSel    => std_logic_vector(NstJob_DI.nstCmd.auxFunc(1 downto 0)),
                                          aluInvRes     => NstJob_DI.nstCmd.polarity,
                                          aluCntEqEn    => NstJob_DI.nstCmd.auxFunc(2),
                                          aluAccuCntEn  => NstJob_DI.nstCmd.auxFunc(2),
                                          aluRegMuxSel  => "00",
                                          fpuWbIrq      => RaiseWbIrq_S,
                                          others        => '0');

    -- this is needed due to simultanous load of accu and alu registers...
    Agu0InitLut_D(C_NST_MASKMAC_OP) <= "00";
    Agu0StepLut_D(C_NST_MASKMAC_OP) <= "10";

    ------------------------------------
    -- COPY Operation: conditional read-modify write on a second stream
    InitCycleLut_D(C_NST_COPY_OP)  <= not NstJob_DI.nstCmd.auxFunc(0);
    FpuCmdInitLut_D(C_NST_COPY_OP) <= (opAReEn       => DoInitLoad_S,
                                       aluAccuSet    => '1',
                                       macOpBSel     => "00",
                                       aluRegMuxSel  => "1" & DoInitLoad_S, -- switch to zero in case no value is loaded
                                       aluLtEqSel    => "00",
                                       others        => '0');

    FpuCmdStepLut_D(C_NST_COPY_OP) <= (opAReEn       => NstJob_DI.nstCmd.auxFunc(0),
                                       opBReEn       => '0',
                                       macOpBSel     => "00",
                                       aluLtEqSel    => "11",-- disable comparison
                                       aluRegMuxSel  => NstJob_DI.nstCmd.auxFunc(0) & "1", -- switch from AluReg to opA if AuxFunc(0) = 1;
                                       aluAccuSet    => NstJob_DI.nstCmd.auxFunc(0),
                                       aluOutVld     => StoreTrig_S,
                                       fpuWbIrq      => RaiseWbIrq_S,
                                       others        => '0');

    Agu0InitLut_D(C_NST_COPY_OP) <= NstJob_DI.nstCmd.initSel;
    Agu0StepLut_D(C_NST_COPY_OP) <= "00";



----------------------------------------------------------------------------
-- command decoder LUTs
----------------------------------------------------------------------------

    OpCode_D <= NstJob_DI.nstCmd.opCode;

    -- inner <= init <= outer
    InvOpCode_SN <= '1' when NstJob_DI.nstCmd.initLevel  > NstJob_DI.nstCmd.outerLevel else
                    '1' when NstJob_DI.nstCmd.innerLevel > NstJob_DI.nstCmd.outerLevel else
                    '1' when NstJob_DI.nstCmd.innerLevel > NstJob_DI.nstCmd.initLevel else
                    '1' when OpCode_D >= C_N_NST_OPCODES else
                    '0';

    -- decode
    FpuCmd_D    <= FpuCmdInitLut_D(to_integer(OpCode_D)) when FpuCmdSel_S = '1' and InvOpCode_SP = '0' else
                   FpuCmdStepLut_D(to_integer(OpCode_D)) when FpuCmdSel_S = '0' and InvOpCode_SP = '0' else
                   C_FPU_NOP_CMD;

    FpuCmd_DO   <= FpuCmd_D;

    OpAAguSel_S <= Agu0InitLut_D(to_integer(OpCode_D)) when FpuCmdSel_S = '1' and InvOpCode_SP = '0' else
                   Agu0StepLut_D(to_integer(OpCode_D)) when FpuCmdSel_S = '0' and InvOpCode_SP = '0' else
                   (others=>'0');

    -- issue init load in this case
    DoInitLoad_S    <= '0' when NstJob_DI.nstCmd.initSel = "11" else
                       '1';

    -- check wether this operation requires an init cycle
    DoInitCycle_S   <= InitCycleLut_D(to_integer(OpCode_D)) when InvOpCode_SP = '0' else
                       '0';

    -- IRQs
    RaiseWbIrq_S  <= to_std_logic(NstJob_DI.nstCmd.irqCfg = "10", false) and DoneTrig_S;
    RaiseCmdIrq_S <= to_std_logic(NstJob_DI.nstCmd.irqCfg = "01", false) and DoneTrig_S and FpuCmdWrEn_S and (not FpuCmdSel_S);
    -- note: the WB IRQ travels through the FPU pipeline first...
    CmdIrq_SO     <=  RaiseCmdIrq_S or InvCmd_S;

    FpuCmdWrEn_SO <= FpuCmdWrEn_S;

    -- write the WB address if required
    FpuWbAddrWrEn_SO <= FpuCmdWrEn_S and (FpuCmd_D.macNormEn or FpuCmd_D.aluOutVld);

    -- output this internal signal to status regs
    InvCmd_SO        <= InvCmd_S;

    -- credit based stalling
    CmdInFlight_DN <= CmdInFlight_DP   when FpuCmdWrEn_S = '1' and FpuCmdReEn_SI = '1' else
                      CmdInFlight_DP+1 when FpuCmdWrEn_S = '1'  else
                      CmdInFlight_DP-1 when FpuCmdReEn_SI = '1' else
                      CmdInFlight_DP;

    Stall_S <= '1' when CmdInFlight_DP = C_FPU_INPUT_FIFO_DEPTH  else
               '0';

----------------------------------------------------------------------------
-- read requests + buffering
----------------------------------------------------------------------------

    Tcdm0WrEn_S <= FpuCmd_D.opAReEn and FpuCmdWrEn_S;
    Tcdm1WrEn_S <= FpuCmd_D.opBReEn and FpuCmdWrEn_S;

    -- make sure address is byte aligned
    -- here we need to be able to select all AGUs (to suppor the init loads...)
    Tcdm0RAddr_D  <= DagDataAddr_DI(0) when OpAAguSel_S = "11" else
                     DagDataAddr_DI(to_integer(OpAAguSel_S));

    -- req if not empty
    Tcdm0RReq_SO              <= not Tcdm0RReq_SB;
    Tcdm1RReq_SO              <= not Tcdm1RReq_SB;

    -- zero pad address
    Tcdm0RAddr_DO(1 downto 0)                                   <= (others=>'0');
    Tcdm0RAddr_DO(Tcdm0RAddr_DO'high downto C_AGU_ADDR_WIDTH+2) <= (others=>'0');
    Tcdm1RAddr_DO(1 downto 0)                                   <= (others=>'0');
    Tcdm1RAddr_DO(Tcdm1RAddr_DO'high downto C_AGU_ADDR_WIDTH+2) <= (others=>'0');


    i_req0_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => C_AGU_ADDR_WIDTH,
        G_FIFO_DEPTH            => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH    => 1,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX CTRL REQ0 FIFO]",
        G_TARGET                => G_TARGET
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_SI,

        -- input port
        Data_DI                 => std_logic_vector(Tcdm0RAddr_D),
        WrEn_SI                 => Tcdm0WrEn_S,
        Full_SO                 => open,
        AlmFull_SO              => open,

        -- output port
        unsigned(Data_DO)       => Tcdm0RAddr_DO(C_AGU_ADDR_WIDTH+2-1 downto 2),
        ReEn_SI                 => Tcdm0RAck_SI,
        Empty_SO                => Tcdm0RReq_SB,
        AlmEmpty_SO             => open
    );

    i_req1_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => C_AGU_ADDR_WIDTH,
        G_FIFO_DEPTH            => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH    => 1,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX CTRL REQ1 FIFO]",
        G_TARGET                => G_TARGET
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_SI,

        -- input port
        Data_DI                 => std_logic_vector(DagDataAddr_DI(1)),
        WrEn_SI                 => Tcdm1WrEn_S,
        Full_SO                 => open,
        AlmFull_SO              => open,

        -- output port
        unsigned(Data_DO)       => Tcdm1RAddr_DO(C_AGU_ADDR_WIDTH+2-1 downto 2),
        ReEn_SI                 => Tcdm1RAck_SI,
        Empty_SO                => Tcdm1RReq_SB,
        AlmEmpty_SO             => open
    );
----------------------------------------------------------------------------
-- controller FSM
----------------------------------------------------------------------------

    p_fsm : process(all)
    begin

    --default:
    State_SN      <= State_SP;
    Idle_SO       <= '0';
    InvCmd_S      <= '0';
    NstJobReEn_SO <= '0';
    DagStepEn_SO  <= '0';
    DagInit_SO    <= '0';
    FpuCmdSel_S   <= '0';
    FpuCmdWrEn_S  <= '0';

    case (State_SP) is
    --------------------------------------------
    when IDLE =>
        Idle_SO <= '1';

        if NstJobEmpty_SI = '0' and Stall_S = '0' then
            DagInit_SO <= '1';
            State_SN   <= CALC_STEP;
        end if;

    --------------------------------------------
    when CALC_STEP =>
        -- bail out if the command is invalid
        if InvOpCode_SP = '1' then
          State_SN <= INV_CMD;
        elsif Stall_S = '0' then
          FpuCmdWrEn_S  <= '1';

          -- perform an init step
          -- no counter increment in this case!
          if InitTrig_S = '1' then
            State_SN    <= INIT_STEP;
            FpuCmdSel_S <= '1';
          -- computation end
          elsif DoneTrig_S = '1' then
            State_SN      <= IDLE;
            DagStepEn_SO  <= '1';
            NstJobReEn_SO <= '1';
          else
            DagStepEn_SO <= '1';
          end if;
        end if;
    --------------------------------------------
    when INIT_STEP =>
        if Stall_S = '0' then
          FpuCmdWrEn_S <= '1';
          DagStepEn_SO <= '1';

          -- computation end
          if DoneTrig_S = '1' then
            State_SN      <= IDLE;
            NstJobReEn_SO <= '1';
          else
            State_SN     <= CALC_STEP;
          end if;
        end if;
    --------------------------------------------
    when INV_CMD =>
        -- stay here and wait for soft clear
        InvCmd_S <= '1';
    ----------------------------------------------
    -- exhaustive FSM!
    --when others =>
    --    State_SN <= IDLE;
    --------------------------------------------
    end case;

    end process p_fsm;

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

    p_clk : process(Clk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            State_SP       <= IDLE;
            InvOpCode_SP   <= '0';
            CmdInFlight_DP <= (others=>'0');
        elsif Clk_CI'event and Clk_CI = '1' then
            if Clr_SI = '1' then
                State_SP       <= IDLE;
                InvOpCode_SP   <= '0';
                CmdInFlight_DP <= (others=>'0');
            else
                State_SP       <= State_SN;
                InvOpCode_SP   <= InvOpCode_SN;
                CmdInFlight_DP <= CmdInFlight_DN;
            end if;
        end if;
    end process p_clk;

end architecture;
