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

-- latency: 2*C_FP32_PCS_N_SEGS + 1

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

entity fp32_norm is
  port (
    Clk_CI      : in  std_logic;
    Rst_RBI     : in  std_logic;
    Clr_SI      : in  std_logic;
    -- minuend input (from de norm)
    Val_DI      : in  unsigned(C_FP32_PCS_WIDTH - 1  downto 0);
    Carry_DI    : in  unsigned(C_FP32_PCS_N_SEGS - 1 downto 0);
    Overflow_SI : in  std_logic;
    NormEn_SI   : in  std_logic;
    -- floating point output
    FpRes_DO    : out std_logic_vector(C_FP32_WIDTH-1 downto 0);
    Vld_SO      : out std_logic
    );
end fp32_norm;

architecture RTL of fp32_norm is

  signal Val_D                     : unsigned(C_FP32_PCS_WIDTH - 1  downto 0);
  signal Carry_D                   : unsigned(C_FP32_PCS_N_SEGS - 1 downto 0);

  signal CarryPropOut0_D           : unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  signal CarryPropOut0Vld_S        : std_logic;

  signal Invert_S                  : std_logic;
  signal InvSum_D                  : unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  signal InvCarry_D                : unsigned(C_FP32_PCS_N_SEGS-1 downto 0);

  signal CarryPropOut1_D           : unsigned(C_FP32_PCS_WIDTH-1 downto 0);

  signal SignRegs_DN, SignRegs_DP  : std_logic_vector(C_FP32_PCS_N_SEGS + 2 -1 downto 0);

  signal ZeroCntIn_D               : std_logic_vector(2**C_FP32_EXP_WIDTH - 1  downto 0);

  signal ShiftSize_DN,ShiftSize_DP : unsigned(C_FP32_EXP_WIDTH - 1 downto 0);
  signal ShiftIn_DN, ShiftIn_DP    : unsigned(C_FP32_MANT_WIDTH + 2**C_FP32_EXP_WIDTH - 1  downto 0);
  signal ShiftTmp_D                : unsigned(C_FP32_MANT_WIDTH + 2**C_FP32_EXP_WIDTH - 1  downto 0);
  signal ShiftOut_DN, ShiftOut_DP  : unsigned(C_FP32_MANT_WIDTH + 2**C_FP32_EXP_WIDTH - 1  downto 0);

  signal Zero_S                    : std_logic;
  signal Zero_SN, Zero_SP          : std_logic_vector(1 downto 0);
  signal Oflow_SN, Oflow_SP        : std_logic_vector(1 downto 0);

  signal ExpDiff_D                 : unsigned(C_FP32_EXP_WIDTH - 1 downto 0);
  signal Exp_DN, Exp_DP            : unsigned(C_FP32_EXP_WIDTH - 1 downto 0);

  signal VldReg_SN, VldReg_SP      : std_logic_vector(1 downto 0);

begin
-----------------------------------------------------------------------------
-- assertions
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- sign inversion and carry propagation
-----------------------------------------------------------------------------

  -- gate the inputs to zero if not enabled
  Val_D   <= VectScalAND(Val_DI, NormEn_SI);
  Carry_D <= VectScalAND(Carry_DI, NormEn_SI);

  -- first, we have to propagate the carries in order to know whether the number is negative or not
  i_fp32_pcsCarryProp0 : entity work.fp32_pcsCarryProp
    generic map (
      G_NUM_ADDERS    => C_FP32_PCS_N_SEGS-1
      )
    port map(
      Clk_CI      => Clk_CI,
      Rst_RBI     => Rst_RBI,
      Clr_SI      => Clr_SI,
      -- input
      SumIn_DI    => Val_D,
      CarryIn_DI  => Carry_D,
      Vld_SI      => NormEn_SI,

      -- ouptut
      SumOut_DO   => CarryPropOut0_D,
      Vld_SO      => CarryPropOut0Vld_S
      );

  -- now we have to do the sign inversion
  Invert_S    <= CarryPropOut0_D(CarryPropOut0_D'high);
  InvSum_D    <= VectScalXOR(CarryPropOut0_D, Invert_S);
  InvCarry_D  <= resize(to_unsigned(0,1) & Invert_S, InvCarry_D'length);
  SignRegs_DN <= SignRegs_DP(SignRegs_DP'high-1 downto 0) & Invert_S;

  i_fp32_pcsCarryProp1 : entity work.fp32_pcsCarryProp
    generic map (
      G_NUM_ADDERS    => C_FP32_PCS_N_SEGS
      )
    port map(
      Clk_CI      => Clk_CI,
      Rst_RBI     => Rst_RBI,
      Clr_SI      => Clr_SI,
      -- input
      SumIn_DI    => InvSum_D,
      CarryIn_DI  => InvCarry_D,
      Vld_SI      => CarryPropOut0Vld_S,

      -- ouptut
      SumOut_DO   => CarryPropOut1_D,
      Vld_SO      => VldReg_SN(0)
      );

  VldReg_SN(1) <= VldReg_SP(0);
  Vld_SO       <= VldReg_SP(1);

-----------------------------------------------------------------------------
-- leading zero counter, exponent logic
-----------------------------------------------------------------------------

  -- check overflow guard bits, and maximum exponent
  g_rangeBits : if 	C_FP32_N_ACCU_OFLOW_BITS > 0 generate
  begin
    Oflow_SN  <= Oflow_SP(Oflow_SP'high-1 downto 0) & (VectorOR(CarryPropOut1_D(CarryPropOut1_D'high-1 downto CarryPropOut1_D'high-1-C_FP32_N_ACCU_OFLOW_BITS+1)) or VectorNOR(ShiftSize_DN));
	end generate g_rangeBits;

  g_noRangeBits : if C_FP32_N_ACCU_OFLOW_BITS = 0 generate
  begin
	  Oflow_SN  <= Oflow_SP(Oflow_SP'high-1 downto 0) & VectorNOR(ShiftSize_DN);
  end generate g_noRangeBits;

  ZeroCntIn_D <= std_logic_vector(CarryPropOut1_D(CarryPropOut1_D'high-1-C_FP32_N_ACCU_OFLOW_BITS downto C_FP32_MANT_WIDTH));
  ShiftIn_DN  <= CarryPropOut1_D(CarryPropOut1_D'high-1-C_FP32_N_ACCU_OFLOW_BITS downto 0);
  ExpDiff_D   <= resize(unsigned(to_signed(C_FP32_MAX_EXP,ExpDiff_D'length+1) - signed(resize(ShiftSize_DP,ExpDiff_D'length+1))), ExpDiff_D'length);
  Zero_SN     <= Zero_SP(Zero_SP'high-1 downto 0) & (Zero_S and not Oflow_SN(0));

  -- set to zero in case of underflow
  Exp_DN      <= VectScalAND(ExpDiff_D, not Zero_SP(0));

-----------------------------------------------------------------------------
-- leading zero counter
-----------------------------------------------------------------------------

  i_lzc : entity work.ntx_lzc
  generic map(
    G_VECTORLEN  => 2**C_FP32_EXP_WIDTH,
    G_FLIPVECTOR => true
    )
  port map(

    Vector_DI      => ZeroCntIn_D,
    FirstOneIdx_DO => ShiftSize_DN,
    NoOnes_SO      => Zero_S
    );


-----------------------------------------------------------------------------
-- barrel shifter
-----------------------------------------------------------------------------

  ShiftTmp_D   <= resize(ShiftIn_DP,ShiftTmp_D'length);
  ShiftOut_DN  <= shift_left(ShiftTmp_D, to_integer(ShiftSize_DP));

-----------------------------------------------------------------------------
-- output
-----------------------------------------------------------------------------

  FpRes_DO     <= SignRegs_DP(SignRegs_DP'high) & C_FP32_INF_VAL(C_FP32_INF_VAL'high-1 downto 0)  when Oflow_SP(Oflow_SP'high) = '1' else
                  SignRegs_DP(SignRegs_DP'high) & C_FP32_ZERO_VAL(C_FP32_ZERO_VAL'high-1 downto 0) when  Zero_SP(Zero_SP'high) = '1' else
                  SignRegs_DP(SignRegs_DP'high) & std_logic_vector(Exp_DP) & std_logic_vector(ShiftOut_DP(ShiftOut_DP'high-1 downto ShiftOut_DP'high-1-C_FP32_MANT_WIDTH+1));

-----------------------------------------------------------------------------
-- regs
-----------------------------------------------------------------------------

  p_delRegs : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then
      SignRegs_DP  <= (others=>'0');
      Zero_SP      <= (others=>'0');
      Oflow_SP     <= (others=>'0');
      ShiftSize_DP <= (others=>'0');
      ShiftOut_DP  <= (others=>'0');
      Exp_DP       <= (others=>'0');
      ShiftIn_DP   <= (others=>'0');
      VldReg_SP    <= (others=>'0');
    elsif Clk_CI'event and Clk_CI = '1' then

      if Clr_SI = '1' then
        VldReg_SP    <= (others=>'0');
      else
        VldReg_SP    <= VldReg_SN;
      end if;

      SignRegs_DP  <= SignRegs_DN;

      if VldReg_SN(0) = '1' then
        Zero_SP(0)   <= Zero_SN(0);
        Oflow_SP(0)  <= Oflow_SN(0);
        ShiftSize_DP <= ShiftSize_DN;
        ShiftIn_DP   <= ShiftIn_DN;
      end if;

      if VldReg_SN(1) = '1' then
        Exp_DP       <= Exp_DN;
        Zero_SP(1)   <= Zero_SN(1);
        Oflow_SP(1)  <= Oflow_SN(1);
        ShiftOut_DP  <= ShiftOut_DN;
      end if;
    end if;
  end process p_delRegs;

end architecture RTL;






