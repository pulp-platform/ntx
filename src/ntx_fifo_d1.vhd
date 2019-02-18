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

-- depth one FIFO that uses a register.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity ntx_fifo_d1 is
  generic (
    G_DATA_WIDTH          : natural := 8;
    G_FIFO_DESIGNATOR     : string  := "[UNNAMED FIFO]"
    );
  port (
    Clk_CI        : in std_logic;
    -- asynchronous reset
    Rst_RBI       : in std_logic;
     -- synch clear
    SftRst_RI     : in std_logic;

    -- input port
    Data_DI       : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);
    WrEn_SI       : in  std_logic;
    Full_SO       : out std_logic; --note: active low!

    -- output port
    Data_DO       : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
    ReEn_SI       : in  std_logic;
    Empty_SO      : out std_logic  --note: active low!
    );
end ntx_fifo_d1;

architecture RTL of ntx_fifo_d1 is

  signal DataReg0_DP, DataReg0_DN : std_logic_vector(G_DATA_WIDTH-1 downto 0);

  signal State_SN, State_SP : std_logic;

  signal DataReg0En_S : std_logic;

begin
-----------------------------------------------------------------------------
-- sanity checks for simulation
-----------------------------------------------------------------------------
--synopsys translate_off
  assert not ((WrEn_SI = '1' and State_SP = '1') and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": overflow"                            severity failure;
  --
  assert not ((ReEn_SI = '1' and State_SP = '0') and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": underflow"                           severity failure;
--synopsys translate_on

-----------------------------------------------------------------------------
-- input / output register connections
-----------------------------------------------------------------------------

  -- connect output registers
  Data_DO        <= DataReg0_DP;

  DataReg0_DN    <= Data_DI;

  Empty_SO       <= not State_SP;

  Full_SO        <= State_SP;

-----------------------------------------------------------------------------
-- logic
-----------------------------------------------------------------------------

  -- possibilities:
  -- state: 0 wr: 0  rd: 0 -> do nothing
  -- state: 0 wr: 1  rd: 0 -> state: 1, reg0: 1
  -- state: 0 wr: 1  rd: 1 -> invalid
  -- state: 0 wr: 0  rd: 1 -> invalid (captured in assertion), do nothing
  -- state: 1 wr: 0  rd: 0 -> do nothing
  -- state: 1 wr: 1  rd: 0 -> invalid (captured in assertion), do nothing
  -- state: 1 wr: 1  rd: 1 -> state: 1, reg0: 1
  -- state: 1 wr: 0  rd: 1 -> state: 0, reg0: 0
  -- note: the state is gray encoded

  DataReg0En_S <= '1' when (WrEn_SI = '1') and (ReEn_SI = '0') and (State_SP = '0') else
                  '1' when (WrEn_SI = '1') and (ReEn_SI = '1') and (State_SP = '1') else
                  '0';



  State_SN <= '1' when (WrEn_SI = '1') and (ReEn_SI = '0') and (State_SP = '0') else
              '1' when (WrEn_SI = '1') and (ReEn_SI = '1') and (State_SP = '1') else
              '0' when (WrEn_SI = '0') and (ReEn_SI = '1') and (State_SP = '1') else
              State_SP;


-----------------------------------------------------------------------------
-- registers
-----------------------------------------------------------------------------

  p_regs : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then

      State_SP      <= '0';
      DataReg0_DP   <= (others=>'0');

    elsif (Clk_CI'event and Clk_CI = '1') then

      State_SP      <= State_SN;

      if DataReg0En_S = '1' then
        DataReg0_DP   <= DataReg0_DN;
      end if;

      if SftRst_RI = '1' then
        State_SP      <= '0';
      end if;

    end if;
  end process p_regs;

end RTL;

