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

-- Standard show ahead for Altera FPGAs
--
-- The "almost full" and "almost empty" thresholds
-- can be parametrized. Fifo underflows and fifo overflows trigger a failure
-- assertion in the simulation.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.ntx_tools_pkg.all;

entity ntx_fifo_fpga is
  generic (
    G_DATA_WIDTH          : natural := 32;
    G_FIFO_DEPTH          : natural := 16;
    G_ALMOST_FULL_THRESH  : natural := 1;
    G_ALMOST_EMPTY_THRESH : natural := 1;
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
end ntx_fifo_fpga;

architecture RTL of ntx_fifo_fpga is

  COMPONENT scfifo
	GENERIC (
		add_ram_output_register		: STRING;
		almost_empty_value		: NATURAL;
		almost_full_value		: NATURAL;
		intended_device_family		: STRING;
		lpm_hint		: STRING;
		lpm_numwords		: NATURAL;
		lpm_showahead		: STRING;
		lpm_type		: STRING;
		lpm_width		: NATURAL;
		lpm_widthu		: NATURAL;
		overflow_checking		: STRING;
		underflow_checking		: STRING;
		use_eab		: STRING
	);
	PORT (
			aclr	: IN STD_LOGIC ;
			clock	: IN STD_LOGIC ;
			data	: IN STD_LOGIC_VECTOR (G_DATA_WIDTH-1 DOWNTO 0);
			rdreq	: IN STD_LOGIC ;
			sclr	: IN STD_LOGIC ;
			wrreq	: IN STD_LOGIC ;
			almost_empty	: OUT STD_LOGIC ;
			almost_full	: OUT STD_LOGIC ;
			empty	: OUT STD_LOGIC ;
			full	: OUT STD_LOGIC ;
			q	: OUT STD_LOGIC_VECTOR (G_DATA_WIDTH-1 DOWNTO 0);
			usedw	: OUT STD_LOGIC_VECTOR (log2ceil(G_FIFO_DEPTH)-1 DOWNTO 0)
	);
	END COMPONENT;

  signal Rst_R     : std_logic;
  signal Full_S    : std_logic;
  signal Empty_S   : std_logic;

begin
-----------------------------------------------------------------------------
-- sanity checks for simulation
-----------------------------------------------------------------------------

--synopsys translate_off
  assert not ((WrEn_SI='1' and Full_S='1') and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": overflow"                            severity failure;
  --
  assert not ((ReEn_SI='1' and Empty_S='1') and (Clk_CI'event and Clk_CI = '1'))
    report G_FIFO_DESIGNATOR & ": underflow"                           severity failure;
--synopsys translate_on

-----------------------------------------------------------------------------
-- FPGA Fifo instance
-----------------------------------------------------------------------------

  Full_SO  <= Full_S;
  Empty_SO <= Empty_S;
  Rst_R    <= not Rst_RBI;

	scfifo_component : scfifo
	GENERIC MAP (
		add_ram_output_register => "ON",
		almost_empty_value      => G_ALMOST_EMPTY_THRESH+1,--need to adjust this soince we use a different convention (inclusive).
		almost_full_value       => G_ALMOST_FULL_THRESH,
		intended_device_family  => "Stratix IV",
		lpm_hint                => "RAM_BLOCK_TYPE=MLAB",
		lpm_numwords            => G_FIFO_DEPTH,
		lpm_showahead           => "ON",
		lpm_type                => "scfifo",
		lpm_width               => G_DATA_WIDTH,
		lpm_widthu              => log2ceil(G_FIFO_DEPTH),
		overflow_checking       => "ON",
		underflow_checking      => "ON",
		use_eab                 => "ON"
	)
	PORT MAP (
		aclr         => Rst_R,
		clock        => Clk_CI,
		sclr         => SftRst_RI,
		data         => Data_DI,
		wrreq        => WrEn_SI,
		full         => Full_S,
		almost_full  => AlmFull_SO,
		q            => Data_DO,
		rdreq        => ReEn_SI,
		empty        => Empty_S,
		almost_empty => AlmEmpty_SO,
		usedw        => open
	);


end RTL;
