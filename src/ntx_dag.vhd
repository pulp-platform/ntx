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

-- data address generator (DAG) for the NSTs. contains the HW loops, as well as
-- the address generation units (AGUs).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ntx_pkg.all;
use work.ntx_tools_pkg.all;

entity ntx_dag is
  port (
    --------------------------
    Clk_CI            : in  std_logic;
    Rst_RBI           : in  std_logic;
    Clr_SI            : in  std_logic;
    --
    StepEn_SI         : in  std_logic;
    Init_SI           : in  std_logic;
    -- loop bounds are always inclusive [0, LoopEnd]
    -- strides are grouped together: DAG0[S0-S4], DAG1[S0-S4], DAG2[S0-S4]
    NstJob_DI         : in  T_NST_JOB;
    --
    DataAddr_DO       : out T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
    -- asserted if loop starts in current step
    LoopStartTrig_SO  : out std_logic_vector(C_N_HW_LOOPS downto 0);
    -- asserted if loop ends in current step
    LoopEndTrig_SO    : out std_logic_vector(C_N_HW_LOOPS downto 0)
    --------------------------
    );
end entity ntx_dag;

architecture RTL of ntx_dag is

  signal Loop_DN, Loop_DP       : T_LOOP_ARRAY(C_N_HW_LOOPS-1 downto 0);
  signal LoopClr_S              : std_logic_vector(C_N_HW_LOOPS-1 downto 0);
  signal LoopLast_S             : std_logic_vector(C_N_HW_LOOPS-1 downto 0);
  signal LoopEnMasked_S         : std_logic_vector(C_N_HW_LOOPS-1 downto 0);
  signal LoopEn_S               : std_logic_vector(C_N_HW_LOOPS downto 0);
  signal LoopEn_SN, LoopEn_SP   : std_logic_vector(C_N_HW_LOOPS downto 0);
  signal Agu_DN, Agu_DP         : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
  signal AguIncr_D              : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);

  type T_AGU_ADDRESS_ARRAY_TMP is array(natural range <>) of unsigned(C_N_AGUS*C_AGU_ADDR_WIDTH-1 downto 0);
  signal AguStrideTmp_D         : T_AGU_ADDRESS_ARRAY_TMP(C_N_HW_LOOPS-1 downto 0);
  signal AguStrideMux_D         : unsigned(C_N_AGUS*C_AGU_ADDR_WIDTH-1 downto 0);
  signal StrideIdx_D            : unsigned(log2ceil(C_N_HW_LOOPS)-1 downto 0);

begin
----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------

----------------------------------------------------------------------------
-- HW Loops
----------------------------------------------------------------------------

  g_loops : for k in 0 to C_N_HW_LOOPS-1 generate
  begin
    Loop_DN(k)    <= (others=>'0')   when (LoopClr_S(k) = '1' and StepEn_SI = '1') or Init_SI = '1' else
                     Loop_DP(k) + 1  when (LoopEn_S(k)  = '1' and StepEn_SI = '1') else
                     Loop_DP(k);

    LoopLast_S(k) <= to_std_logic(Loop_DP(k) = NstJob_DI.loopEnd(k),false);
    LoopClr_S(k)  <= (LoopLast_S(k) and LoopEn_S(k));
  end generate g_loops;

  -- enable innermost loop in every step...
  LoopEn_S(0) <= '1';
  g_loopEns : for k in 1 to C_N_HW_LOOPS generate
  begin
    -- carry over
    LoopEn_S(k)    <= LoopClr_S(k-1);
  end generate g_loopEns;

  -- store this mask to generate loop entry flags. loop exit flags are equal to LoopEn_S.
  LoopEn_SN <= (others=>'1') when Init_SI = '1'   else
               LoopEn_S      when StepEn_SI = '1' else
               LoopEn_SP;

  LoopStartTrig_SO <= LoopEn_SP;
  LoopEndTrig_SO   <= LoopEn_S;

----------------------------------------------------------------------------
-- AGUs
----------------------------------------------------------------------------

  g_addrTmp : for k in 0 to C_N_HW_LOOPS*C_N_AGUS-1 generate
  begin
    -- bunch together the strides triggered by the same loop (i.e. all S0's)
    -- and assign them to an array for indexing
    -- note the loop reversal such that we can use a lzc to determine the index
    AguStrideTmp_D(C_N_HW_LOOPS-1-(k mod C_N_HW_LOOPS))(((k / C_N_HW_LOOPS) + 1)*C_AGU_ADDR_WIDTH-1 downto (k / C_N_HW_LOOPS)*C_AGU_ADDR_WIDTH) <= NstJob_DI.aguStride(k);
  end generate g_addrTmp;

  -- determine the index of the stride to add depending on most significant counter that overflows
  -- note: we have to mask the currently unused loops away...
  LoopEnMasked_S <= LoopEn_S(C_N_HW_LOOPS-1 downto 0) and ThermEncodeDn(NstJob_DI.nstCmd.outerLevel, C_N_HW_LOOPS, true);

  i_lzc : entity work.ntx_lzc
  generic map(
    G_VECTORLEN  => C_N_HW_LOOPS,
    G_FLIPVECTOR => true
    )
  port map(
    Vector_DI      => LoopEnMasked_S,-- note: lowest bit is always one...
    FirstOneIdx_DO => StrideIdx_D,
    NoOnes_SO      => open
    );

  -- actual stride mux
  AguStrideMux_D <= AguStrideTmp_D(to_integer(StrideIdx_D));

  g_agus : for k in 0 to C_N_AGUS-1 generate
  begin
    Agu_DN(k)   <= NstJob_DI.aguBase(k)   when Init_SI   = '1' else
                   Agu_DP(k) + AguIncr_D(k) when StepEn_SI = '1' else
                   Agu_DP(k);

    -- get currently selected stride
    AguIncr_D(k)    <= AguStrideMux_D((k+1)*C_AGU_ADDR_WIDTH-1 downto k*C_AGU_ADDR_WIDTH);

    -- output
    DataAddr_DO(k) <= Agu_DP(k);

  end generate g_agus;

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

  p_clk : process(Clk_CI, Rst_RBI)
  begin
      if Rst_RBI = '0' then
        Loop_DP   <= (others=>(others=>'0'));
        Agu_DP    <= (others=>(others=>'0'));
        LoopEn_SP <= (others=>'0');
      elsif Clk_CI'event and Clk_CI = '1' then
        if Clr_SI = '1' then
          Loop_DP   <= (others=>(others=>'0'));
          Agu_DP    <= (others=>(others=>'0'));
          LoopEn_SP <= (others=>'0');
        else
          Loop_DP   <= Loop_DN;
          LoopEn_SP <= LoopEn_SN;
          Agu_DP    <= Agu_DN;
        end if;
      end if;
  end process p_clk;

end architecture;













