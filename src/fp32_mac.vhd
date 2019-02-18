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

-- overall latency is 2*C_FP32_PCS_N_SEGS + 6 cycles.
-- for 2 segments this amounts to 10 cycles.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

entity fp32_mac is
  generic (
    G_TARGET    : natural := 1 -- 0: ASIC, 1: ALTERA
    -- ASIC target assumes synopsys design compiler with designware.
    -- for synthesis, uncomment the DWARE libs above...
    );
  port (
    --------------------------
    Clk_CI            : in  std_logic;
    Rst_RBI           : in  std_logic;
    Clr_SI            : in  std_logic;

    OpA_DI            : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OpB_DI            : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);

    AccuEn_SI         : in  std_logic;
    AccuSel_SI        : in  std_logic; -- 0: AccuReg, 1: FP ZERO
    SubEn_SI          : in  std_logic; -- 0: Accu += A*B, 1: Accu -= A*B
    NormEn_SI         : in  std_logic; -- enables output normalizer

    ResZ_DO           : out std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OutVld_SO         : out std_logic
    --------------------------
    );
end entity fp32_mac;

architecture RTL of fp32_mac is

  constant C_MULT_LAT               : natural := 4;

  signal AccuEn_SN, AccuEn_SP       : std_logic_vector(C_MULT_LAT-1 downto 0);
  signal AccuSel_SN, AccuSel_SP     : std_logic_vector(C_MULT_LAT-1 downto 0);
  signal SubEn_SN,  SubEn_SP        : std_logic_vector(C_MULT_LAT-1 downto 0);

  signal MultSign_D                 : std_logic;
  signal Invert_S                   : std_logic;

  signal MultOutPcs_D               : unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  signal AddIn_D                    : unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  signal AccuOut_D                  : unsigned(C_FP32_PCS_WIDTH-1 downto 0);


  signal AccuMux_D                  : unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  signal AccuReg_DN, AccuReg_DP     : unsigned(C_FP32_PCS_WIDTH-1 downto 0);

  signal Overflow_S                 : std_logic;
  signal CarryOut_D                 : unsigned(C_FP32_PCS_N_SEGS-1 downto 0);
  signal CarryMux_D                 : unsigned(C_FP32_PCS_N_SEGS-1 downto 0);
  signal CarryReg_DN, CarryReg_DP   : unsigned(C_FP32_PCS_N_SEGS-1 downto 0);

  signal OutVld_SN, OutVld_SP       : std_logic_vector(C_MULT_LAT downto 0);

begin
----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------

----------------------------------------------------------------------------
-- inputs / shimming registers
----------------------------------------------------------------------------

  AccuSel_SN  <= AccuSel_SP(AccuSel_SP'high-1 downto 0) & AccuSel_SI;
  AccuEn_SN   <= AccuEn_SP(AccuEn_SP'high-1 downto 0)   & AccuEn_SI;
  SubEn_SN    <= SubEn_SP(SubEn_SP'high-1 downto 0)     & SubEn_SI;
  OutVld_SN   <= OutVld_SP(OutVld_SP'high-1 downto 0)   & NormEn_SI;

----------------------------------------------------------------------------
-- FP multiplier with PCS output
----------------------------------------------------------------------------

  -- multiplier / postshifter = latency 4
  i_fp32_pcsMult : entity work.fp32_pcsMult
    generic map(
      G_TARGET    => G_TARGET
      )
    port map(
      Clk_CI      => Clk_CI,
      Rst_RBI     => Rst_RBI,
      Vld_SI      => AccuEn_SI,
      -- multiplier input
      OpA_DI      => OpA_DI,
      OpB_DI      => OpB_DI,
      -- multiplier output (ready for pcsAdd input)
      Sign_DO     => MultSign_D,
      Out_DO      => MultOutPcs_D
      );

  -- invert if required
  Invert_S       <= SubEn_SP(SubEn_SP'high) xor MultSign_D;
  AddIn_D        <= VectScalXOR(MultOutPcs_D, Invert_S);

----------------------------------------------------------------------------
-- PCS accumulator, note: do not clear with Clr_SI, since the accumulator is
-- cleared with an init step anyway
----------------------------------------------------------------------------

  CarryMux_D  <= VectScalAND(CarryReg_DP(CarryReg_DP'high downto 1), not AccuSel_SP(AccuSel_SP'high)) & Invert_S;

  AccuMux_D   <= VectScalAND(AccuReg_DP, not AccuSel_SP(AccuSel_SP'high));

  CarryReg_DN <= CarryOut_D when AccuEn_SP(AccuEn_SP'high) = '1' else
                 CarryReg_DP;

  AccuReg_DN  <= AccuOut_D   when AccuEn_SP(AccuEn_SP'high) = '1' else
                 AccuReg_DP;

  i_fp32_pcsAdd : entity work.fp32_pcsAdd
    generic map(
      G_ACCU_WIDTH      => C_FP32_PCS_WIDTH,
      G_N_ACCU_SEGS     => C_FP32_PCS_N_SEGS,
      G_ACCU_SEG_LEN    => C_FP32_PCS_SEG_LEN,
      G_CARRY_PROP_ONLY => false
    )
    port map(
      AddIn_DI     => AddIn_D,
      Accu_DI      => AccuMux_D,
      Carry_DI     => CarryMux_D,
      Accu_DO      => AccuOut_D,
      Carry_DO     => CarryOut_D,
      Overflow_SO  => Overflow_S
      );

----------------------------------------------------------------------------
-- normalizer (no rounding) and output assignments
----------------------------------------------------------------------------

  -- latency: 2*C_FP32_PCS_N_SEGS + 1
  i_fp32_norm : entity work.fp32_norm
  port map(
    Clk_CI      => Clk_CI,
    Rst_RBI     => Rst_RBI,
    Clr_SI      => Clr_SI,

    -- minuend input (from de norm)
    Val_DI      => AccuReg_DP,
    Carry_DI    => CarryReg_DP,
    Overflow_SI => Overflow_S,
    NormEn_SI   => OutVld_SP(OutVld_SP'high),-- used for silencing

    -- floating point output
    FpRes_DO    => ResZ_DO,
    Vld_SO      => OutVld_SO
    );

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

  p_clk : process(Clk_CI, Rst_RBI)
  begin
      if Rst_RBI = '0' then
        AccuReg_DP   <= (others=>'0');
		    CarryReg_DP  <= (others=>'0');
        AccuEn_SP    <= (others=>'0');
        AccuSel_SP   <= (others=>'0');
        SubEn_SP     <= (others=>'0');
        OutVld_SP    <= (others=>'0');
      elsif Clk_CI'event and Clk_CI = '1' then

        AccuReg_DP   <= AccuReg_DN;
        CarryReg_DP  <= CarryReg_DN;
        AccuEn_SP    <= AccuEn_SN;
        AccuSel_SP   <= AccuSel_SN;
        SubEn_SP     <= SubEn_SN;
        OutVld_SP    <= OutVld_SN;

        if Clr_SI = '1' then
          -- accu and carry reg are reset implicitly, see above...
          AccuEn_SP    <= (others=>'0');
          OutVld_SP    <= (others=>'0');
        end if;
      end if;
  end process p_clk;

end architecture;













