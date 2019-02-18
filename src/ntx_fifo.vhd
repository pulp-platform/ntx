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

-- NOTE: FIFOs with depth 1 or 2 have a register implementation in both the
-- ASIC and FPGA case, and do not support almost full/empty flags.

library ieee;
use ieee.std_logic_1164.all;

entity ntx_fifo is
  generic (
    G_DATA_WIDTH          : natural := 32;
    G_FIFO_DEPTH          : natural := 16;
    G_ALMOST_FULL_THRESH  : natural := 1;
    G_ALMOST_EMPTY_THRESH : natural := 1;
    G_FIFO_DESIGNATOR     : string  := "[UNNAMED FIFO]";
    G_TARGET              : natural := 1; -- 0: ASIC, 1: ALTERA STRATIX IV
    G_OREGS               : natural := 0  -- only effective for ASIC FIFOs with depth >2
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
end ntx_fifo;

architecture rtl of ntx_fifo is

  signal Empty_S, Full_S : std_logic;

  component ntx_fifo_fpga
  generic (
    G_DATA_WIDTH          : natural;
    G_FIFO_DEPTH          : natural;
    G_ALMOST_FULL_THRESH  : natural;
    G_ALMOST_EMPTY_THRESH : natural;
    G_FIFO_DESIGNATOR     : string
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
  end component ntx_fifo_fpga;

  component ntx_fifo_asic
  generic (
    G_DATA_WIDTH          : natural;
    G_FIFO_DEPTH          : natural;
    G_ALMOST_FULL_THRESH  : natural;
    G_ALMOST_EMPTY_THRESH : natural;
    G_FIFO_DESIGNATOR     : string
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
  end component ntx_fifo_asic;

  component ntx_fifo_asic_oregs
  generic (
    G_DATA_WIDTH          : natural;
    G_FIFO_DEPTH          : natural;
    G_ALMOST_FULL_THRESH  : natural;
    G_ALMOST_EMPTY_THRESH : natural;
    G_FIFO_DESIGNATOR     : string
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
  end component ntx_fifo_asic_oregs;

  component ntx_fifo_d1
  generic (
    G_DATA_WIDTH          : natural;
    G_FIFO_DESIGNATOR     : string
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

    -- output port
    Data_DO       : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
    ReEn_SI       : in  std_logic;
    Empty_SO      : out std_logic
    );
  end component ntx_fifo_d1;


  component ntx_fifo_d2
  generic (
    G_DATA_WIDTH          : natural;
    G_FIFO_DESIGNATOR     : string
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

    -- output port
    Data_DO       : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
    ReEn_SI       : in  std_logic;
    Empty_SO      : out std_logic
    );
  end component ntx_fifo_d2;



begin
-----------------------------------------------------------------------------
-- Concurrent
-----------------------------------------------------------------------------

  Full_SO     <= Full_S;
  Empty_SO    <= Empty_S;

-----------------------------------------------------------------------------
-- d1 Fifo
-----------------------------------------------------------------------------

  g_d1Fifo : if G_FIFO_DEPTH = 1 generate
  begin

    i_fifo_d1 : ntx_fifo_d1
      generic map(
        G_DATA_WIDTH          => G_DATA_WIDTH,
        G_FIFO_DESIGNATOR     => G_FIFO_DESIGNATOR
        )
      port map(
        Clk_CI        => Clk_CI,
        -- asynchronous reset
        Rst_RBI       => Rst_RBI,
        -- synchronous reset
        SftRst_RI     => SftRst_RI,

        -- input port
        Data_DI       => Data_DI,
        WrEn_SI       => WrEn_SI,
        Full_SO       => Full_S,

        -- output port
        Data_DO       => Data_DO,
        ReEn_SI       => ReEn_SI,
        Empty_SO      => Empty_S
        );

      AlmFull_SO  <= Full_S;
      AlmEmpty_SO <= Empty_S;

  end generate g_d1Fifo;

-----------------------------------------------------------------------------
-- d2 Fifo
-----------------------------------------------------------------------------

  g_d2Fifo : if G_FIFO_DEPTH = 2 generate
  begin

    i_fifo_d1 : ntx_fifo_d2
      generic map(
        G_DATA_WIDTH          => G_DATA_WIDTH,
        G_FIFO_DESIGNATOR     => G_FIFO_DESIGNATOR
        )
      port map(
        Clk_CI        => Clk_CI,
        -- asynchronous reset
        Rst_RBI       => Rst_RBI,
        -- synchronous reset
        SftRst_RI     => SftRst_RI,

        -- input port
        Data_DI       => Data_DI,
        WrEn_SI       => WrEn_SI,
        Full_SO       => Full_S,

        -- output port
        Data_DO       => Data_DO,
        ReEn_SI       => ReEn_SI,
        Empty_SO      => Empty_S
        );

      AlmFull_SO  <= Full_S;
      AlmEmpty_SO <= Empty_S;

  end generate g_d2Fifo;


-----------------------------------------------------------------------------
-- Altera FPGAs
-----------------------------------------------------------------------------

  g_fpga : if G_TARGET = 1 and G_FIFO_DEPTH > 2 generate
  begin

    i_fifo_fpga : ntx_fifo_fpga
      generic map(
        G_DATA_WIDTH          => G_DATA_WIDTH,
        G_FIFO_DEPTH          => G_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => G_ALMOST_FULL_THRESH,
        G_ALMOST_EMPTY_THRESH => G_ALMOST_EMPTY_THRESH,
        G_FIFO_DESIGNATOR     => G_FIFO_DESIGNATOR
        )
      port map(
        Clk_CI        => Clk_CI,
        -- asynchronous reset
        Rst_RBI       => Rst_RBI,
        -- synchronous reset
        SftRst_RI     => SftRst_RI,

        -- input port
        Data_DI       => Data_DI,
        WrEn_SI       => WrEn_SI,
        Full_SO       => Full_S,
        AlmFull_SO    => AlmFull_SO,

        -- output port
        Data_DO       => Data_DO,
        ReEn_SI       => ReEn_SI,
        Empty_SO      => Empty_S,
        AlmEmpty_SO   => AlmEmpty_SO
        );


  end generate g_fpga;

-----------------------------------------------------------------------------
-- ASIC implementation
-----------------------------------------------------------------------------

  g_asic : if G_TARGET = 0 and G_FIFO_DEPTH > 2 and G_OREGS = 0 generate
  begin

    i_fifo_asic : ntx_fifo_asic
      generic map(
        G_DATA_WIDTH          => G_DATA_WIDTH,
        G_FIFO_DEPTH          => G_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => G_ALMOST_FULL_THRESH,
        G_ALMOST_EMPTY_THRESH => G_ALMOST_EMPTY_THRESH,
        G_FIFO_DESIGNATOR     => G_FIFO_DESIGNATOR
        )
      port map(
        Clk_CI        => Clk_CI,
        -- asynchronous reset
        Rst_RBI       => Rst_RBI,
        -- synchronous reset
        SftRst_RI     => SftRst_RI,

        -- input port
        Data_DI       => Data_DI,
        WrEn_SI       => WrEn_SI,
        Full_SO       => Full_S,
        AlmFull_SO    => AlmFull_SO,

        -- output port
        Data_DO       => Data_DO,
        ReEn_SI       => ReEn_SI,
        Empty_SO      => Empty_S,
        AlmEmpty_SO   => AlmEmpty_SO
        );

  end generate g_asic;

-----------------------------------------------------------------------------
-- ASIC implementation with output regs
-----------------------------------------------------------------------------

  g_asic_oregs : if G_TARGET = 0 and G_FIFO_DEPTH > 2 and G_OREGS = 1 generate
  begin

    i_fifo_asic_oregs : ntx_fifo_asic_oregs
      generic map(
        G_DATA_WIDTH          => G_DATA_WIDTH,
        G_FIFO_DEPTH          => G_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => G_ALMOST_FULL_THRESH,
        G_ALMOST_EMPTY_THRESH => G_ALMOST_EMPTY_THRESH,
        G_FIFO_DESIGNATOR     => G_FIFO_DESIGNATOR
        )
      port map(
        Clk_CI        => Clk_CI,
        -- asynchronous reset
        Rst_RBI       => Rst_RBI,
        -- synchronous reset
        SftRst_RI     => SftRst_RI,

        -- input port
        Data_DI       => Data_DI,
        WrEn_SI       => WrEn_SI,
        Full_SO       => Full_S,
        AlmFull_SO    => AlmFull_SO,

        -- output port
        Data_DO       => Data_DO,
        ReEn_SI       => ReEn_SI,
        Empty_SO      => Empty_S,
        AlmEmpty_SO   => AlmEmpty_SO
        );

  end generate g_asic_oregs;



end rtl;
