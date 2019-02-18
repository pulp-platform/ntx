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

-- converts FP32 representation to an unnormalized fixed point format for the
-- PCS accumulator.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

entity fp32_toPcs is
  port (
    Clk_CI      : in  std_logic;
    Rst_RBI     : in  std_logic;
    -- floating point input
    Fp_DI       : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    -- PCS output
    PcsSign_DO  : out std_logic;
    PcsRes_DO   : out unsigned(C_FP32_PCS_WIDTH - 1  downto 0)
    );
end fp32_toPcs;

architecture RTL of fp32_toPcs is

  signal ExtMant_D                : unsigned(C_FP32_MANT_WIDTH downto 0);
  signal Exp_D                    : unsigned(C_FP32_EXP_WIDTH-1 downto 0);
  signal SignReg_DN, SignReg_DP   : std_logic;
  signal ShiftTmp_D               : unsigned(C_FP32_PCS_WIDTH - 1  downto 0);
  signal PcsRes_DN, PcsRes_DP     : unsigned(C_FP32_PCS_WIDTH - 1  downto 0);

begin
-----------------------------------------------------------------------------
-- assertions
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- in/out assignments
-----------------------------------------------------------------------------

  ExtMant_D   <= VectScalAND("1" & VectScalAND(fp32_getMant(Fp_DI), not fp32_isInf(Fp_DI)), not fp32_isZero(Fp_DI));

  Exp_D       <= fp32_getExp(Fp_DI);

  SignReg_DN  <= fp32_getSign(Fp_DI);

  PcsSign_DO  <= SignReg_DP;

-----------------------------------------------------------------------------
-- barrel shifter
-----------------------------------------------------------------------------

  ShiftTmp_D <= resize(ExtMant_D,ShiftTmp_D'length);
  PcsRes_DN  <= shift_left(ShiftTmp_D, to_integer(Exp_D));
  PcsRes_DO  <= PcsRes_DP;

-----------------------------------------------------------------------------
-- regs
-----------------------------------------------------------------------------

  p_delRegs : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then
      SignReg_DP     <= '0';
      PcsRes_DP      <= (others=>'0');
    elsif Clk_CI'event and Clk_CI = '1' then
      SignReg_DP     <= SignReg_DN;
      PcsRes_DP      <= PcsRes_DN;
    end if;
  end process p_delRegs;

end architecture RTL;






