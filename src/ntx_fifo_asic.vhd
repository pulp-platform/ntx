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


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.ntx_tools_pkg.all;

entity ntx_fifo_asic is
  generic (
    G_DATA_WIDTH          : natural := 32;
    G_FIFO_DEPTH          : natural := 16;
    G_ALMOST_FULL_THRESH  : natural := 4;
    G_ALMOST_EMPTY_THRESH : natural := 2;
    G_FIFO_DESIGNATOR     : string  := "[UNNAMED FIFO]"
    );
  port (
    Clk_CI        : in std_logic;
    -- asynchronous reset
    Rst_RBI       : in std_logic;
    -- synchronous reset
    SftRst_RI     : in std_logic;

    -- input port
    Data_DI       : in  std_logic_vector(G_DATA_WIDTH-1 downto 0);
    WrEn_SI       : in  std_logic;
    Full_SO       : out std_logic;
    AlmFull_SO    : out std_logic;

    -- output port
    Data_DO       : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
    ReEn_SI       : in  std_logic;
    Empty_SO      : out std_logic;
    AlmEmpty_SO   : out std_logic
    );
end ntx_fifo_asic;

architecture RTL of ntx_fifo_asic is

  -- calculate number of required address bits
  constant C_ADDR_WIDTH  : natural := log2ceil(G_FIFO_DEPTH);
  constant C_NUMEL_WIDTH : natural := log2ceil(G_FIFO_DEPTH+1);

  -- custom data types
  type DATA_ARRAY_TYPE is array (natural range <>) of std_logic_vector(G_DATA_WIDTH-1 downto 0);
  type FIFO_STATE_TYPE is (EMPTY, IN_BETWEEN, FULL);

  -- registers
  signal RegFile_DP                   : DATA_ARRAY_TYPE(G_FIFO_DEPTH-1  downto 0) := (others=>(others=>'0'));
  signal State_SN, State_SP           : FIFO_STATE_TYPE;
  signal WrPtr_DN, WrPtr_DP           : unsigned(C_ADDR_WIDTH-1 downto 0);
  signal RdPtr_DN, RdPtr_DP           : unsigned(C_ADDR_WIDTH-1 downto 0);
  signal WrEnHot1_S                   : std_logic_vector(G_FIFO_DEPTH-1  downto 0);


  -- datapath signals
  signal Numel_D                      : unsigned(C_NUMEL_WIDTH  downto 0);
  -- this signal needs an additional sign bit
  signal PtrDiff_D                    : signed  (C_ADDR_WIDTH   downto 0);

  -- ctrl signals
  signal Read_S                       : std_logic;
  signal Write_S                      : std_logic;

  signal Full_S                       : std_logic;
  signal Empty_S                      : std_logic;

begin
-----------------------------------------------------------------------------
-- sanity checks for simulation
-----------------------------------------------------------------------------

--synopsys translate_off
  assert not ((WrEn_SI='1' and State_SP=FULL) and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": overflow"                            severity failure;
  --
  assert not ((ReEn_SI='1' and State_SP=EMPTY) and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": underflow"                           severity failure;
  --
  assert ((G_ALMOST_FULL_THRESH > 0) and (G_ALMOST_FULL_THRESH   < G_FIFO_DEPTH))
    report G_FIFO_DESIGNATOR & ": almost full threshold out of range"  severity failure;
  --
  assert ((G_ALMOST_EMPTY_THRESH > 0) and (G_ALMOST_EMPTY_THRESH < G_FIFO_DEPTH))
    report G_FIFO_DESIGNATOR & ": almost empty threshold out of range" severity failure;
  --
  assert (G_FIFO_DEPTH > 2)
    report G_FIFO_DESIGNATOR & ": minimum fifo depth is 3"             severity failure;
--synopsys translate_on

-----------------------------------------------------------------------------
-- I/O
-----------------------------------------------------------------------------

Full_SO  <= Full_S;

Empty_SO <= Empty_S;


-----------------------------------------------------------------------------
-- counters
-----------------------------------------------------------------------------

  -- counter increments
  WrPtr_DN    <= (others => '0') when (WrPtr_DP = G_FIFO_DEPTH-1) and (Write_S = '1') else
                 (WrPtr_DP + 1)  when (Write_S = '1') else
                 WrPtr_DP;

  RdPtr_DN    <= (others => '0') when (RdPtr_DP = G_FIFO_DEPTH-1) and (Read_S = '1') else
                 (RdPtr_DP + 1)  when (Read_S = '1') else
                 RdPtr_DP;

  -- pointer difference
  PtrDiff_D <= signed(resize(WrPtr_DP, PtrDiff_D'length)) - signed(resize(RdPtr_DP, PtrDiff_D'length));

  -- calculate number of elements
  Numel_D   <= unsigned(resize(PtrDiff_D, Numel_D'length)) when ((PtrDiff_D >= 0) and (Full_S = '0')) else
               unsigned(G_FIFO_DEPTH + resize(PtrDiff_D, Numel_D'length));

-----------------------------------------------------------------------------
-- fsm state transition logic
-----------------------------------------------------------------------------

  p_fsm_comb : process(State_SP,
                       WrEn_SI,
                       ReEn_SI,
                       Numel_D)
  begin
    -- default assignment
    State_SN  <= State_SP;
    Write_S   <= '0';
    Read_S    <= '0';
    Full_S    <= '0';
    Empty_S   <= '0';

    case (State_SP) is
      ------
      when EMPTY =>
        Empty_S <= '1';

        if WrEn_SI = '1' then
          Write_S  <= '1';
          State_SN <= IN_BETWEEN;
        end if;
      ------
      when IN_BETWEEN =>

        if (WrEn_SI = '1') and (ReEn_SI = '1') then

          Write_S  <= '1';
          Read_S   <= '1';

        elsif (WrEn_SI = '1') then
          Write_S  <= '1';

          -- go to FULL state if number of elements is G_FIFO_DEPTH-1
          if (G_FIFO_DEPTH-1 = Numel_D) then
            State_SN  <= FULL;
          end if;

        elsif (ReEn_SI = '1') then
          Read_S <= '1';

          -- go to empty state if number of elements is 1
          if (Numel_D = 1) then
            State_SN <= EMPTY;
          end if;

        end if;
      ------
      when FULL =>
        Full_S <= '1';

        if ReEn_SI = '1' then
          Read_S     <= '1';
          State_SN   <= IN_BETWEEN;
        end if;
    end case;

  end process p_fsm_comb;


-----------------------------------------------------------------------------
-- alm full/empty threshs
-----------------------------------------------------------------------------


AlmEmpty_SO  <= '1' when (G_ALMOST_EMPTY_THRESH >= Numel_D) and (Full_S = '0') else
                '0';

AlmFull_SO   <= '1' when (G_ALMOST_FULL_THRESH <= Numel_D) or (Full_S = '1') else
                '0';

-----------------------------------------------------------------------------
-- register file
-----------------------------------------------------------------------------

  --p_regfile : process(Clk_CI)
  --begin
  --  if Clk_CI'event and Clk_CI = '1' then
  --    -- write input data
  --    if Write_S = '1' then
  --      RegFile_DP(to_integer(WrPtr_DP)) <= Data_DI;
  --    end if;
  --  end if;
  --end process p_regfile;

  -- address decode
  WrEnHot1_S <= Hot1EncodeDn(WrPtr_DP,RegFile_DP'length);

  g_regs : for k in RegFile_DP'range generate
  begin

  p_regfile : process(Clk_CI)
  begin
    if Rst_RBI = '0' then
        RegFile_DP(k) <= (others=>'0');
    elsif Clk_CI'event and Clk_CI = '1' then
        -- write input data
        if Write_S = '1' and WrEnHot1_S(k) = '1' then
          RegFile_DP(k) <= Data_DI;
        end if;
    end if;
  end process p_regfile;


  end generate g_regs;


  -- connect to output
  Data_DO        <= RegFile_DP(to_integer(RdPtr_DP));

-----------------------------------------------------------------------------
-- registers
-----------------------------------------------------------------------------

  p_regs : process(Clk_CI, Rst_RBI)
  begin
    if Rst_RBI = '0' then
      State_SP      <= EMPTY;
      RdPtr_DP      <= (others => '0');
      WrPtr_DP      <= (others => '0');
    elsif Clk_CI'event and Clk_CI = '1' then
      if SftRst_RI = '1' then
        State_SP      <= EMPTY;
        RdPtr_DP      <= (others => '0');
        WrPtr_DP      <= (others => '0');
      else
        State_SP     <= State_SN;
        WrPtr_DP     <= WrPtr_DN;
        RdPtr_DP     <= RdPtr_DN;
      end if;
    end if;
  end process p_regs;




end RTL;
