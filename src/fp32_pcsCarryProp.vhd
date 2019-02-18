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

entity fp32_pcsCarryProp is
  generic (
    G_NUM_ADDERS    : natural := C_FP32_PCS_N_SEGS
    );
  port (
    Clk_CI      : in  std_logic;
    Rst_RBI     : in  std_logic;
    Clr_SI      : in  std_logic;
    -- input
    SumIn_DI    : in  unsigned(C_FP32_PCS_WIDTH-1 downto 0);
    CarryIn_DI  : in  unsigned(C_FP32_PCS_N_SEGS-1 downto 0);
    Vld_SI      : in  std_logic;

    -- ouptut
    SumOut_DO   : out unsigned(C_FP32_PCS_WIDTH-1 downto 0);
    Vld_SO      : out std_logic
    );
end fp32_pcsCarryProp;

architecture RTL of fp32_pcsCarryProp is

  type T_SUM_ARRAY is array(natural range <>)  of unsigned(C_FP32_PCS_WIDTH-1 downto 0);
  type T_CARRY_ARRAY is array(natural range <>) of unsigned(C_FP32_PCS_N_SEGS-1 downto 0);

  signal CarryRegs_DN, CarryRegs_DP : T_CARRY_ARRAY(G_NUM_ADDERS-1 downto 0);
  signal SumRegs_DN, SumRegs_DP     : T_SUM_ARRAY(G_NUM_ADDERS-1 downto 0);

  signal EnRegs_DN, EnRegs_DP       : std_logic_vector(G_NUM_ADDERS-1 downto 0);

begin
-----------------------------------------------------------------------------
-- I/O
-----------------------------------------------------------------------------

  EnRegs_DN <= EnRegs_DP(EnRegs_DP'high-1 downto 0) & Vld_SI;
  SumOut_DO <= SumRegs_DP(SumRegs_DP'high);
  Vld_SO    <= EnRegs_DP(EnRegs_DP'high);

-----------------------------------------------------------------------------
-- adders
-----------------------------------------------------------------------------

  g_adders : for k in 0 to G_NUM_ADDERS - 1 generate
  begin

    g_first : if k = 0 generate
    begin

      i_fp32_pcsAdd : entity work.fp32_pcsAdd
      generic map(
        G_ACCU_WIDTH      => C_FP32_PCS_WIDTH,
        G_N_ACCU_SEGS     => C_FP32_PCS_N_SEGS,
        G_ACCU_SEG_LEN    => C_FP32_PCS_SEG_LEN,
        G_CARRY_PROP_ONLY => true
      )
      port map(
        AddIn_DI          => (others=>'0'),
        Carry_DI          => CarryIn_DI,
        Accu_DI           => SumIn_DI,
        Accu_DO           => SumRegs_DN(k),
        Carry_DO          => CarryRegs_DN(k),
        Overflow_SO       => open
      );
    end generate g_first;

    g_others : if k > 0 generate
    begin

      i_fp32_pcsAdd : entity work.fp32_pcsAdd
      generic map(
        G_ACCU_WIDTH      => C_FP32_PCS_WIDTH,
        G_N_ACCU_SEGS     => C_FP32_PCS_N_SEGS,
        G_ACCU_SEG_LEN    => C_FP32_PCS_SEG_LEN,
        G_CARRY_PROP_ONLY => true
      )
      port map(
        AddIn_DI          => (others=>'0'),
        Carry_DI          => CarryRegs_DP(k-1),
        Accu_DI           => SumRegs_DP(k-1),
        Accu_DO           => SumRegs_DN(k),
        Carry_DO          => CarryRegs_DN(k),
        Overflow_SO       => open
      );

    end generate g_others;


    p_regs : process(Clk_CI, Rst_RBI)
    begin
      if Rst_RBI = '0' then
        CarryRegs_DP(k)  <= (others=>'0');
        SumRegs_DP(k)    <= (others=>'0');
        EnRegs_DP(k)     <= '0';
      elsif Clk_CI'event and Clk_CI = '1' then

        if Clr_SI = '1' then
          EnRegs_DP(k)     <= '0';
        else
          EnRegs_DP(k)     <= EnRegs_DN(k);
        end if;

        if EnRegs_DN(k) = '1' then
          CarryRegs_DP(k)  <= CarryRegs_DN(k);
          SumRegs_DP(k)    <= SumRegs_DN(k);
        end if;
      end if;
    end process p_regs;

  end generate g_adders;
-----------------------------------------------------------------------------
-- regs
-----------------------------------------------------------------------------



end architecture RTL;






