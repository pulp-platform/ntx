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
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

entity fp32_pcsMult is
  generic (
    G_TARGET    : natural := 1 -- 0: ASIC, 1: ALTERA
    -- ASIC target assumes synopsys design compiler with designware.
    -- for synthesis, uncomment the DWARE libs above...
    );
  port (
    Clk_CI      : in  std_logic;
    Rst_RBI     : in  std_logic;
    -- multiplier input
    OpA_DI      : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OpB_DI      : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    Vld_SI      : in  std_logic;
    -- multiplier output (ready for pcsAdd input)
    Sign_DO     : out std_logic;
    Out_DO      : out unsigned(C_FP32_PCS_WIDTH - 1  downto 0)
    );
end fp32_pcsMult;

architecture RTL of fp32_pcsMult is

  constant C_SHIFT_OUT_WIDTH            : natural := (C_FP32_MANT_WIDTH + 1)*2 - 1 + 2**C_FP32_EXP_WIDTH;

  signal MultOut_D                      : unsigned((C_FP32_MANT_WIDTH + 1)*2 - 1 downto 0);

  signal ExpAReg_DN, ExpAReg_DP         : unsigned(C_FP32_EXP_WIDTH-1 downto 0);
  signal ExpBReg_DN, ExpBReg_DP         : unsigned(C_FP32_EXP_WIDTH-1 downto 0);
  signal ExpSum_DN, ExpSum_DP           : signed(C_FP32_EXP_WIDTH+1 downto 0);

  signal ExpLtZero_S                    : std_logic;
  signal ExpGeMax_S                     : std_logic;
  signal ExpIsMinOne_S                  : std_logic;
  signal GateSignal_S                   : std_logic;

  signal SignOutReg_DN, SignOutReg_DP   : std_logic_vector(3 downto 0);

  signal ShiftIn_DN, ShiftIn_DP         : unsigned((C_FP32_MANT_WIDTH + 1)*2 - 1 downto 0);
  signal ShiftSize_DN, ShiftSize_DP     : unsigned(C_FP32_EXP_WIDTH - 1 downto 0);
  signal ShiftOut_D                     : unsigned(C_SHIFT_OUT_WIDTH - 1 downto 0);
  signal ShiftOut_DN, ShiftOut_DP       : unsigned(C_FP32_PCS_WIDTH - 1 downto 0);

  signal ShiftTmp_D                     : unsigned(C_SHIFT_OUT_WIDTH - 1 downto 0);

  -- only needed for ASIC target
  signal ExtMantA_DN, ExtMantA_DP       : unsigned(C_FP32_MANT_WIDTH downto 0);
  signal ExtMantB_DN, ExtMantB_DP       : unsigned(C_FP32_MANT_WIDTH downto 0);
  signal MultOut_DN, MultOut_DP         : unsigned((C_FP32_MANT_WIDTH + 1)*2 - 1 downto 0);

  --component declaration for synopsys DWARE multiplier
  component DW02_mult_2_stage is
    generic (
      A_width : POSITIVE := 8;
      B_width : POSITIVE := 8 );
    port (
      CLK     : in std_logic;
      TC      : in std_logic;
      A       : in std_logic_vector(A_width-1 downto 0);
      B       : in std_logic_vector(B_width-1 downto 0);
      PRODUCT : out std_logic_vector(A_width+B_width-1 downto 0)
    );
  end component DW02_mult_2_stage;

  --component declaration for altera multadd
  COMPONENT lpm_mult
  GENERIC (
          lpm_hint                : STRING;
          lpm_pipeline            : NATURAL;
          lpm_representation      : STRING;
          lpm_type                : STRING;
          lpm_widtha              : NATURAL;
          lpm_widthb              : NATURAL;
          lpm_widthp              : NATURAL
  );
  PORT (
                  aclr    : IN  STD_LOGIC ;
                  sclr    : IN  STD_LOGIC ;
                  clken   : IN  STD_LOGIC ;
                  clock   : IN  STD_LOGIC ;
                  dataa   : IN  STD_LOGIC_VECTOR (23 DOWNTO 0);
                  datab   : IN  STD_LOGIC_VECTOR (23 DOWNTO 0);
                  sum     : in  STD_LOGIC_VECTOR(0 DOWNTO 0);
                  result  : OUT STD_LOGIC_VECTOR(47 DOWNTO 0)
  );
  END COMPONENT;

begin
-----------------------------------------------------------------------------
-- assertions
-----------------------------------------------------------------------------
--  assert C_FP32_MANT_WIDTH < 2*G_MULT_SIZE report "currently, only C_FP32_MANT_WIDTH < 2*G_MULT_SIZE is supported" severity failure;
--  assert C_FP32_MANT_WIDTH >= G_MULT_SIZE report "currently, only C_FP32_MANT_WIDTH >= G_MULT_SIZE is supported" severity failure;

-----------------------------------------------------------------------------
-- in/out assignments, exponent, sign, zero
-----------------------------------------------------------------------------

  ExpAReg_DN    <= fp32_getExp(OpA_DI);
  ExpBReg_DN    <= fp32_getExp(OpB_DI);

  ExtMantA_DN   <= (not fp32_isZero(OpA_DI)) & fp32_getMant(OpA_DI);
  ExtMantB_DN   <= (not fp32_isZero(OpB_DI)) & fp32_getMant(OpB_DI);

  Sign_DO       <= SignOutReg_DP(SignOutReg_DP'high);
  Out_DO        <= ShiftOut_DP;

  SignOutReg_DN <= SignOutReg_DP(SignOutReg_DP'high-1 downto 0) & (fp32_getSign(OpA_DI) xor fp32_getSign(OpB_DI));

  ExpSum_DN     <= signed("00" & ExpAReg_DP) + signed("00" & ExpBReg_DP) + to_signed(-C_FP32_BIAS,ExpSum_DN'length);

  ExpLtZero_S   <= ExpSum_DP(ExpSum_DP'high);-- test ExpSum_DP < 0

  ExpGeMax_S    <= '1' when ExpSum_DP >= 2**C_FP32_EXP_WIDTH-1 else
                   '0';

  -- ties the multiplier output to zero
  GateSignal_S  <= '0' when (ExpGeMax_S  = '1') else
                   '0' when (ExpLtZero_S = '1') else
                   '1';

-----------------------------------------------------------------------------
-- muxes
-----------------------------------------------------------------------------
  -- saturate shifts. note that we set the mantissa to zero in case of exponent underflows - so no explicit saturation is needed here...
  ShiftSize_DN                               <= VectScalOR(unsigned(ExpSum_DP(C_FP32_EXP_WIDTH-1 downto 0)), ExpGeMax_S);
  ShiftIn_DN(2*C_FP32_MANT_WIDTH+1)          <= (GateSignal_S and MultOut_D(2*C_FP32_MANT_WIDTH+1));
  ShiftIn_DN(2*C_FP32_MANT_WIDTH)            <= (GateSignal_S and MultOut_D(2*C_FP32_MANT_WIDTH)) or ExpGeMax_S;
  ShiftIn_DN(2*C_FP32_MANT_WIDTH-1 downto 0) <= VectScalAND(unsigned(MultOut_D(2*C_FP32_MANT_WIDTH-1 downto 0)), GateSignal_S);

-----------------------------------------------------------------------------
-- mantissa multiplier
-- (target specific - need to use Altera macro in order to instantiate piped adder)
-----------------------------------------------------------------------------

  g_asicMult : if G_TARGET = 0 generate

    -- Instance of DW02_mult_2_stage
    i_mult : DW02_mult_2_stage
    generic map (
      A_width => C_FP32_MANT_WIDTH + 1,
      B_width => C_FP32_MANT_WIDTH + 1
      )
    port map (
      CLK               => Clk_CI,
      TC                => '0', -- unsigned numbers
      A                 => std_logic_vector(ExtMantA_DP),
      B                 => std_logic_vector(ExtMantB_DP),
      unsigned(PRODUCT) => MultOut_D );

    -- pragma translate_off
    -- only for simulation (such that DW macro is not needed)
    MultOut_DN <= ExtMantA_DP * ExtMantB_DP;

    p_multRegs : process(Clk_CI, Rst_RBI)
    begin
      if Rst_RBI = '0' then
          MultOut_DP <= (others=>'0');
      elsif Clk_CI'event and Clk_CI = '1' then
          MultOut_DP <= MultOut_DN;
      end if;
    end process p_multRegs;

    MultOut_D <= MultOut_DP;
    -- pragma translate_on

  end generate g_asicMult;

  g_alteraMult : if G_TARGET = 1 generate

    i_lpm_mult : lpm_mult
    GENERIC MAP (
            lpm_hint           => "DEDICATED_MULTIPLIER_CIRCUITRY=YES,MAXIMIZE_SPEED=9",
            lpm_pipeline       => 1,
            lpm_representation => "UNSIGNED",
            lpm_type           => "LPM_MULT",
            lpm_widtha         => C_FP32_MANT_WIDTH + 1,
            lpm_widthb         => C_FP32_MANT_WIDTH + 1,
            lpm_widthp         => (C_FP32_MANT_WIDTH + 1) * 2
    )
    PORT MAP (
            aclr             => '0',
            sclr             => '0',
            clken            => '1',
            clock            => Clk_CI,
            sum              => "0",
            dataa            => std_logic_vector(ExtMantA_DP),
            datab            => std_logic_vector(ExtMantB_DP),
            unsigned(result) => MultOut_D

    );

  end generate g_alteraMult;

-----------------------------------------------------------------------------
-- shifter after multiplier. converts the multiplier output to fixed point
-- for the accumulator
-----------------------------------------------------------------------------

  ShiftTmp_D  <= resize(ShiftIn_DP,ShiftTmp_D'length);
  ShiftOut_D  <= shift_left(ShiftTmp_D, to_integer(ShiftSize_DP));
  ShiftOut_DN <= resize(ShiftOut_D(ShiftOut_D'high downto C_FP32_MANT_WIDTH), ShiftOut_DN'length);

-----------------------------------------------------------------------------
-- regs
-----------------------------------------------------------------------------

  p_delRegs : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then
      ExtMantA_DP    <= (others=>'0');
      ExtMantB_DP    <= (others=>'0');
      ExpAReg_DP     <= (others=>'0');
      ExpBReg_DP     <= (others=>'0');
      SignOutReg_DP  <= (others=>'0');
      ExpSum_DP      <= (others=>'0');
      ShiftSize_DP   <= (others=>'0');
      ShiftOut_DP    <= (others=>'0');
      ShiftIn_DP     <= (others=>'0');
    elsif Clk_CI'event and Clk_CI = '1' then

      if Vld_SI = '1' then
        ExtMantA_DP <= ExtMantA_DN;
        ExtMantB_DP <= ExtMantB_DN;
        ExpAReg_DP       <= ExpAReg_DN;
        ExpBReg_DP       <= ExpBReg_DN;
        SignOutReg_DP(0) <= SignOutReg_DN(0);
      end if;

      SignOutReg_DP(SignOutReg_DP'high downto 1)  <= SignOutReg_DN(SignOutReg_DP'high downto 1);

      ExpSum_DP      <= ExpSum_DN;
      ShiftSize_DP   <= ShiftSize_DN;
      ShiftOut_DP    <= ShiftOut_DN;
      ShiftIn_DP     <= ShiftIn_DN;
    end if;
  end process p_delRegs;

end architecture RTL;

