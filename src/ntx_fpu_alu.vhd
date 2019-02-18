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

-- ALU for the NTX FPU. implements comparison and gating functionality required
-- for max/min, argmax/argmin, ReLu, inverse ReLu, MaxPool and inverse MaxPool.
--
-- note that comparisons are always between the internal state (either the
-- accumulator reg or the internal counter) and operand B.
--
-- so in order to start a comparison (single or a sequence), you have to init
-- the accu reg. this can be done via the RegMux, so you can either preload opA,
-- opB, 0.0 or 1.0 into that accu.
--
-- the accumulator itself does not necessarily need to be activated during a
-- comparison sequence, so it is possible to compare to a complete sequence to a
-- static value.
--
-- the internal counter (check the constant, should be 16bit at the moment) is
-- reset upon a load, and keeps track of the index of the current element fed
-- into the comparison unit. this value is latched internally whenever the
-- comparison returns true. this latched value can be selected as an output,
-- which enables to compute argmax (i.e. the index of the maximum element).
--
-- further, the unit can selectively gate a second stream (fed in via opA),
-- based on comparison results from stream opB. this can be used for inverse
-- ReLu and inverse MaxPool.
--
-- the accureg is not cleared upon soft clear, since it has to be loaded
-- anyways...

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fp32_pkg.all;
use work.ntx_pkg.all;
use work.ntx_tools_pkg.all;

entity ntx_fpu_alu is
  port (
    --------------------------
    Clk_CI             : in  std_logic;
    Rst_RBI            : in  std_logic;
    Clr_SI             : in  std_logic;
    --------------------------
    -- input operands
    OpA_DI             : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OpB_DI             : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    -- compare with internal counter for equality
    CntEqEn_SI         : in  std_logic;
    -- 1x: LE, 01: LT, 00: EQ
    LtEqSel_SI         : in  std_logic_vector(1 downto 0);
    -- inverts comparison result
    InvRes_SI          : in  std_logic;
    -- enable accu counter
    AccuCntEn_SI       : in  std_logic;
    -- enable conditional accumulation
    AccuEn_SI          : in  std_logic;
    -- force accumulation register enable, and resets internal counter
    AccuSet_SI         : in  std_logic;
    -- select operand to set the accu. note that this also selects the output result if the comparison is true. otherwise the output result is the accu state.
    -- 00: opA, 01: opB, 10: 0.0, 11: 1.0
    RegMuxSel_SI       : in  std_logic_vector(1 downto 0);
    -- select what to output
    -- 0: comparison result mux, 1: the most recent sequence index where the comparison returned true
    OutMuxSel_SI       : in  std_logic;
    -- ALU output
    Out_DO             : out std_logic_vector(C_FP32_WIDTH-1 downto 0);
    -- internal ACCU reg, can be used as temporary operand storage for MAC as well
    AccuReg_DO         : out std_logic_vector(C_FP32_WIDTH-1 downto 0);
    -- used for conditional macs
    CompRes_SO         : out std_logic
    --------------------------
    );
end entity ntx_fpu_alu;

architecture RTL of ntx_fpu_alu is

    signal CompRes_S               : std_logic;

    signal AluRegMux_D             : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal ResMux_D                : std_logic_vector(C_FP32_WIDTH-1 downto 0);

    signal AccuReg_DN, AccuReg_DP  : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal Cnt_DN, Cnt_DP          : unsigned(C_NST_FPU_ALU_CNT_WIDTH-1 downto 0);
    signal CntReg_DN, CntReg_DP    : unsigned(C_NST_FPU_ALU_CNT_WIDTH-1 downto 0);

    signal BothEqZero_S            : std_logic;
    signal CntEq_S                 : std_logic;
    signal Eq_S                    : std_logic;
    signal Lt_S                    : std_logic;

    signal MaskMode_S              : std_logic;
    signal BinMode_S               : std_logic;
    signal ThreshMode_S            : std_logic;

begin
----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------

----------------------------------------------------------------------------
-- Datapath
----------------------------------------------------------------------------

    MaskMode_S   <= to_std_logic(RegMuxSel_SI    = "11",false) or to_std_logic(RegMuxSel_SI    = "00",false);
    BinMode_S    <= to_std_logic(RegMuxSel_SI    = "10",false);
    ThreshMode_S <= to_std_logic(RegMuxSel_SI    = "01",false);

    AluRegMux_D <= OpB_DI          when ThreshMode_S = '1' else
                   OpA_DI;

    ResMux_D    <= AluRegMux_D     when (CompRes_S = '1' or AccuSet_SI = '1')  and (MaskMode_S = '1' or ThreshMode_S = '1') else
                   C_FP32_ZERO_VAL when (CompRes_S = '0' or AccuSet_SI = '1')  and (BinMode_S = '1' or MaskMode_S = '1') else
                   C_FP32_ONE_VAL  when (CompRes_S = '1')                      and (BinMode_S = '1') else
                   AccuReg_DP;

    AccuReg_DN  <= ResMux_D      when AccuEn_SI = '1' or AccuSet_SI = '1' else
                   AccuReg_DP;

    -- select either the index or the res mux
    Out_DO      <= std_logic_vector(resize(CntReg_DN, Out_DO'length)) when OutMuxSel_SI = '1' else
                   ResMux_D;

    Cnt_DN      <= (others=>'0') when AccuSet_SI = '1' or Clr_SI = '1' else
                   Cnt_DP + 1    when AccuCntEn_SI  = '1' else
                   Cnt_DP;

    CntReg_DN   <= (others=>'0') when AccuSet_SI = '1' or Clr_SI = '1' else
                   Cnt_DP        when CompRes_S  = '1' and AccuCntEn_SI  = '1' else
                   CntReg_DP;

----------------------------------------------------------------------------
-- Control and Comparators (note: the int/fp comparators are duplicated
-- to shorten critical paths through the ALU on FPGAs...)
----------------------------------------------------------------------------

    BothEqZero_S <= '1' when fp32_isZero(OpB_DI) = '1' and fp32_isZero(AccuReg_DP) = '1' else
                    '0';

    -- note that 0.0 = 0.0 discards the sign!
    Eq_S         <= '1' when OpB_DI             = AccuReg_DP else
                    '1' when BothEqZero_S       = '1'        else -- does not care about signs in case of zeroes!
                    '1' when fp32_isInf(OpB_DI) = '1'  and fp32_isInf(AccuReg_DP) = '1' and fp32_getSign(OpB_DI) = fp32_getSign(AccuReg_DP)      else
                    '0';

    Lt_S         <= '0'                          when BothEqZero_S = '1'                                                                              else
                    '1'                          when fp32_getSign(OpB_DI) = '1' and fp32_getSign(AccuReg_DP) = '0'                                   else
                    '0'                          when fp32_getSign(OpB_DI) = '0' and fp32_getSign(AccuReg_DP) = '1'                                   else
                    to_std_logic(fp32_getExp(OpB_DI) & fp32_getMant(OpB_DI) < fp32_getExp(AccuReg_DP) & fp32_getMant(AccuReg_DP), fp32_getSign(AccuReg_DP) = '1');

    CntEq_S      <= to_std_logic(unsigned(AccuReg_DP) = Cnt_DP, false);

    -- mux the comparison result
    CompRes_S    <= CntEq_S        xor InvRes_SI when CntEqEn_SI = '1' else
                    Eq_S           xor InvRes_SI when LtEqSel_SI = "00" else
                    Lt_S           xor InvRes_SI when LtEqSel_SI = "01" else
                    (Eq_S or Lt_S) xor InvRes_SI when LtEqSel_SI = "10" else
                    '0';

    CompRes_SO  <= CompRes_S;

    AccuReg_DO  <= AccuReg_DP;

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

    p_clk : process(Clk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            AccuReg_DP <= (others=>'0');
            Cnt_DP     <= (others=>'0');
            CntReg_DP  <= (others=>'0');
        elsif Clk_CI'event and Clk_CI = '1' then
            Cnt_DP     <= Cnt_DN;
            CntReg_DP  <= CntReg_DN;
            AccuReg_DP <= AccuReg_DN;
        end if;
    end process p_clk;

end architecture;













