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

-- Standard show ahead fifo based on a register file.
--
-- The "almost full" and "almost empty" thresholds
-- can be parametrized. Fifo underflows and fifo overflows trigger a failure
-- assertion in the simulation.
--
-- Similar to fifo_asic, but with registered output and almost* flags

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.ntx_tools_pkg.all;

entity ntx_fifo_asic_oregs is
  generic (
    G_DATA_WIDTH          : natural := 2;
    G_FIFO_DEPTH          : natural := 2;
    G_ALMOST_FULL_THRESH  : natural := 1;
    G_ALMOST_EMPTY_THRESH : natural := 1;
    G_FIFO_DESIGNATOR     : string  := "[UNNAMED FIFO]"
    );
  port (
    Clk_CI        : in std_logic;
    -- asynchronous reset
    Rst_RBI       : in std_logic;
    -- synchronous clear. resets the fsm and control signal registers
    SftRst_RI     : in std_logic;

    -- input port
    Data_DI       : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);
    -- ctrl
    WrEn_SI       : in  std_logic;
    Full_SO       : out std_logic;
    AlmFull_SO    : out std_logic;

    -- output port
    Data_DO        : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
    -- ctrl
    ReEn_SI        : in  std_logic;
    Empty_SO       : out std_logic;
    AlmEmpty_SO    : out std_logic
    );
end ntx_fifo_asic_oregs;

architecture RTL of ntx_fifo_asic_oregs is

  type DataArray_Type is array (natural range <>) of std_logic_vector(G_DATA_WIDTH-1 downto 0);
  type FifoState_Type is (EMPTY, IN_BETWEEN, FULL);

  -- regs
  signal DataRegs_DN   : std_logic_vector(G_DATA_WIDTH-1 downto 0);
  signal DataRegs_DP   : DataArray_Type(G_FIFO_DEPTH-1 downto 0);
  signal DataOutReg_DN : std_logic_vector(G_DATA_WIDTH-1 downto 0);
  signal DataOutReg_DP : std_logic_vector(G_DATA_WIDTH-1 downto 0);

  signal FifoState_DN : FifoState_Type;
  signal FifoState_DP : FifoState_Type;

  signal WrPtr_DN : unsigned(log2ceil(G_FIFO_DEPTH)-1 downto 0);
  signal WrPtr_DP : unsigned(log2ceil(G_FIFO_DEPTH)-1 downto 0);

  signal RdPtr_DN : unsigned(log2ceil(G_FIFO_DEPTH)-1 downto 0);
  signal RdPtr_DP : unsigned(log2ceil(G_FIFO_DEPTH)-1 downto 0);

  signal Empty_SN       : std_logic;
  signal Empty_SP       : std_logic;
  signal AlmostEmpty_SN : std_logic;
  signal AlmostEmpty_SP : std_logic;
  signal AlmostFull_SN  : std_logic;
  signal AlmostFull_SP  : std_logic;
  signal Full_SN        : std_logic;
  signal Full_SP        : std_logic;


  -- ctrl signals
  signal WrPtrIncs_S     : std_logic;
  signal RdPtrIncs_S     : std_logic;
  signal PtrDifference_D : signed(log2ceil(G_FIFO_DEPTH)+1 downto 0);
  signal NoOfElements_D  : unsigned(log2ceil(G_FIFO_DEPTH) downto 0);

  signal FifoRen_S       : std_logic;
  signal OutMu_Sel_S     : std_logic;
  signal FifoWren_S      : std_logic;

begin

-----------------------------------------------------------------------------
-- sanity checks for simulation
-----------------------------------------------------------------------------
--synopsys translate_off
  assert not (((WrEn_SI and Full_SP) = '1') and (Clk_CI'event and Clk_CI = '1'))   report G_FIFO_DESIGNATOR & ": overflow" severity failure;
  assert not (((ReEn_SI and Empty_SP) = '1') and (Clk_CI'event and Clk_CI = '1'))  report G_FIFO_DESIGNATOR & ": underflow" severity failure;
  assert ((G_ALMOST_FULL_THRESH >= 0) and (G_ALMOST_FULL_THRESH   < G_FIFO_DEPTH)) report G_FIFO_DESIGNATOR & ": almost full threshold out of range" severity failure;
  assert ((G_ALMOST_EMPTY_THRESH > 0) and (G_ALMOST_EMPTY_THRESH <= G_FIFO_DEPTH)) report G_FIFO_DESIGNATOR & ": almost empty threshold out of range" severity failure;
  assert (G_FIFO_DEPTH > 1)                                                        report G_FIFO_DESIGNATOR & ": mimimum fifo depth is 2" severity failure;
--synopsys translate_on
-----------------------------------------------------------------------------
-- inputs and outputs
-----------------------------------------------------------------------------

  -- input
  DataRegs_DN <= Data_DI;

  -- output mux
  DataOutReg_DN <= DataRegs_DP(to_integer(RdPtr_DN)) when OutMu_Sel_S = '0' else
                   DataRegs_DN;

  -- outputs
  Data_DO        <= DataOutReg_DP;
  Empty_SO       <= Empty_SP;
  Full_SO        <= Full_SP;
  AlmEmpty_SO <= AlmostEmpty_SP;
  AlmFull_SO  <= AlmostFull_SP;


-----------------------------------------------------------------------------
-- counters
-----------------------------------------------------------------------------

  -- counter increments
  WrPtr_DN <= (others => '0') when (WrPtr_DP = G_FIFO_DEPTH-1) else
              (WrPtr_DP + 1);

  RdPtr_DN <= (others => '0') when (RdPtr_DP = G_FIFO_DEPTH-1) else
              (RdPtr_DP + 1);

  PtrDifference_D <= signed(resize(WrPtr_DP, PtrDifference_D'length)) - signed(resize(RdPtr_DP, PtrDifference_D'length));

  NoOfElements_D <= unsigned(resize(PtrDifference_D, NoOfElements_D'length)) when ((PtrDifference_D >= 0) and (FifoState_DP /= FULL)) else
                    unsigned(resize((G_FIFO_DEPTH + PtrDifference_D), NoOfElements_D'length));

-----------------------------------------------------------------------------
-- fsm
-----------------------------------------------------------------------------

  fsm_comb_p : process(FifoState_DP,
                       WrEn_SI,
                       ReEn_SI,
                       NoOfElements_D)
  begin


    -- default assignments
    WrPtrIncs_S <= '0';
    RdPtrIncs_S <= '0';

    Full_SN        <= '0';
    AlmostFull_SN  <= '0';
    Empty_SN       <= '0';
    AlmostEmpty_SN <= '0';

    FifoWren_S      <= '0';
    OutMu_Sel_S     <= '0';
    FifoRen_S       <= '0';

    FifoState_DN <= FifoState_DP;

    case (FifoState_DP) is
      ----------------------------------------------------------------------------------------------------------------------
      when EMPTY =>
        Empty_SN        <= '1';
        AlmostEmpty_SN  <= '1';
        OutMu_Sel_S <= '1';

        -- check almost full threshold
        if (G_ALMOST_FULL_THRESH <= 0 ) then
          AlmostFull_SN <= '1';
        end if;

        -- go to IN_BETWEEN state
        if WrEn_SI = '1' then
          FifoWren_S   <= '1';
          WrPtrIncs_S  <= '1';
          Empty_SN     <= '0';
          FifoState_DN <= IN_BETWEEN;
          FifoRen_S    <= '1';

          -- check if almost empty threshold has to be asserted if there is one element more
          if (G_ALMOST_EMPTY_THRESH >= 1) then
            AlmostEmpty_SN <= '1';
          else
            AlmostEmpty_SN <= '0';
          end if;

          -- check if almost full threshold has to be asserted if there is one element more
          if (G_ALMOST_FULL_THRESH <= 1) then
            AlmostFull_SN <= '1';
          end if;
        end if;
      ----------------------------------------------------------------------------------------------------------------------
      when IN_BETWEEN =>

        -- check almost empty threshold
        if (G_ALMOST_EMPTY_THRESH >= NoOfElements_D) then
          AlmostEmpty_SN <= '1';
        end if;

        -- check almost full threshold
        if (G_ALMOST_FULL_THRESH <= NoOfElements_D) then
          AlmostFull_SN <= '1';
        end if;

        -- this is only needed if exactly one element is in the fifo buffer
        if (1 = NoOfElements_D) then
          OutMu_Sel_S <= '1';
        end if;

        -----------------------------------------
        if ((WrEn_SI = '1') and (ReEn_SI = '1')) then
          FifoWren_S  <= '1';
          WrPtrIncs_S <= '1';
          RdPtrIncs_S <= '1';
          FifoRen_S   <= '1';
        -----------------------------------------
        elsif WrEn_SI = '1' then
          FifoWren_S  <= '1';
          WrPtrIncs_S <= '1';

          -- check if almost empty threshold has to be asserted if there is one element more
          if (G_ALMOST_EMPTY_THRESH-1 >= NoOfElements_D) then
            AlmostEmpty_SN <= '1';
          end if;

          -- check if almost full threshold has to be asserted if there is one element more
          if (G_ALMOST_FULL_THRESH-1 <= NoOfElements_D) then
            AlmostFull_SN <= '1';
          end if;

          -- go to FULL state if number of elements is G_FIFO_DEPTH-1
          if (G_FIFO_DEPTH-1 = NoOfElements_D) then
            FifoState_DN  <= FULL;
            Full_SN       <= '1';
            AlmostFull_SN <= '1';
          end if;
        -----------------------------------------
        elsif ReEn_SI = '1' then
          RdPtrIncs_S <= '1';
          FifoRen_S   <= '1';
          -- check if almost empty threshold has to be asserted if there is one element less
          if (G_ALMOST_EMPTY_THRESH+1 >= NoOfElements_D) then
            AlmostEmpty_SN <= '1';
          end if;

          -- check if almost full threshold has to be asserted if there is one element less
          if (G_ALMOST_FULL_THRESH+1 <= NoOfElements_D) then
            AlmostFull_SN <= '1';
          end if;

          -- go to empty state if number of elements is 1
          if (1 = NoOfElements_D) then
            FifoState_DN   <= EMPTY;
            Empty_SN       <= '1';
            AlmostEmpty_SN <= '1';
            FifoRen_S      <= '0';
          end if;
        -----------------------------------------
        end if;

      ----------------------------------------------------------------------------------------------------------------------
      when FULL =>
        Full_SN       <= '1';
        AlmostFull_SN <= '1';

        -- check almost empty threshold
        if (G_ALMOST_EMPTY_THRESH = G_FIFO_DEPTH) then
          AlmostEmpty_SN <= '1';
        end if;

        -- go to IN_BETWEEN state
        if ReEn_SI = '1' then
          RdPtrIncs_S  <= '1';
          Full_SN      <= '0';
          FifoState_DN <= IN_BETWEEN;
          FifoRen_S    <= '1';

          -- check if almost empty threshold has to be asserted if there is one element less
          if (G_ALMOST_EMPTY_THRESH >= to_unsigned(G_FIFO_DEPTH-1, NoOfElements_D'length)) then
            AlmostEmpty_SN <= '1';
          end if;

          -- check if almost full threshold has to be asserted if there is one element less
          if (G_ALMOST_FULL_THRESH <= to_unsigned(G_FIFO_DEPTH-1, NoOfElements_D'length)) then
            AlmostFull_SN <= '1';
          else
            AlmostFull_SN <= '0';
          end if;
        end if;
    ----------------------------------------------------------------------------------------------------------------------
    end case;


  end process fsm_comb_p;


-----------------------------------------------------------------------------
-- registers
-----------------------------------------------------------------------------

  regs_p : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then
      DataRegs_DP   <= (others => (others => '0'));
      DataOutReg_DP <= (others => '0');
      RdPtr_DP      <= (others => '0');
      WrPtr_DP      <= (others => '0');
      FifoState_DP  <= EMPTY;

      Empty_SP       <= '1';
      AlmostEmpty_SP <= '1';
      AlmostFull_SP  <= '0';
      Full_SP        <= '0';

    elsif Clk_CI'event and Clk_CI = '1' then

      Empty_SP       <= Empty_SN;
      AlmostEmpty_SP <= AlmostEmpty_SN;
      AlmostFull_SP  <= AlmostFull_SN;
      Full_SP        <= Full_SN;

      -- fifo state type
      FifoState_DP <= FifoState_DN;

      -- peters
      if WrPtrIncs_S = '1' then
        WrPtr_DP <= WrPtr_DN;
      end if;

      if RdPtrIncs_S = '1' then
        RdPtr_DP <= RdPtr_DN;
      end if;

      -- register file
      if FifoWren_S = '1' then
        DataRegs_DP(to_integer(WrPtr_DP)) <= DataRegs_DN;
      end if;

      -- output register
      if FifoRen_S = '1' then
        DataOutReg_DP <= DataOutReg_DN;
      end if;

      -- soft reset (only reset fsm and ctrl regs)
      if SftRst_RI = '1' then
        RdPtr_DP     <= (others => '0');
        WrPtr_DP     <= (others => '0');
        FifoState_DP <= EMPTY;

        Empty_SP       <= '1';
        AlmostEmpty_SP <= '1';
        AlmostFull_SP  <= '0';
        Full_SP        <= '0';
      end if;


    end if;
  end process regs_p;

end RTL;

