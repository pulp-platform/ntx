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
use ieee.math_real.all;

entity fp32_pcsAdd2 is
  generic (
    G_ACCU_WIDTH      : natural := 100;
    G_N_ACCU_SEGS     : natural := 4;
    G_ACCU_SEG_LEN    : natural := 25
  );
  port (
    -- note: there are carry 2 bits!
    AddAIn_DI         : in  unsigned(G_ACCU_WIDTH-1 downto 0);
    CarryA_DI         : in  unsigned(2*G_N_ACCU_SEGS-1 downto 0);
    AddBIn_DI         : in  unsigned(G_ACCU_WIDTH-1 downto 0);
    CarryB_DI         : in  unsigned(2*G_N_ACCU_SEGS-1 downto 0);
    Sum_DO            : out unsigned(G_ACCU_WIDTH-1 downto 0);
    Carry_DO          : out unsigned(2*G_N_ACCU_SEGS-1 downto 0);
    Overflow_SO       : out std_logic -- overflow carry bit
    );
end fp32_pcsAdd2;



architecture RTL of fp32_pcsAdd2 is

signal AddTmp_D : unsigned(2*G_N_ACCU_SEGS + G_ACCU_WIDTH-1 downto 0);

-- the last segment has the same length as all others in the case where G_ACCU_WIDTH is divisible by G_ACCU_SEG_LEN
constant C_ACCU_LAST_SEG_LEN : integer := G_ACCU_WIDTH - G_ACCU_SEG_LEN*(G_N_ACCU_SEGS-1);


begin
-----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------
assert G_N_ACCU_SEGS > 1             report "G_N_ACCU_SEGS > 1 expected!"             severity failure;
assert C_ACCU_LAST_SEG_LEN > 0       report "C_ACCU_LAST_SEG_LEN is zero or negative" severity failure;
assert G_N_ACCU_SEGS <= G_ACCU_WIDTH report "G_N_ACCU_SEGS > G_ACCU_WIDTH"            severity failure;

-----------------------------------------------------------------------------
-- generate partial carry save adder segments (individual segments may
-- use tool dependent adder synthesis)
-----------------------------------------------------------------------------

Carry_DO(1 downto 0) <= "00";
Overflow_SO <= AddTmp_D(AddTmp_D'high);



g_AccuSegs : for k in 0 to G_N_ACCU_SEGS-1 generate
begin
  ----------------------------------------------
  g_Last : if (k = G_N_ACCU_SEGS-1) generate
  begin

    -- the carry bit is the MSB of the segment...
    AddTmp_D(C_ACCU_LAST_SEG_LEN + 2 + (G_ACCU_SEG_LEN+2)*k - 1 downto (G_ACCU_SEG_LEN+2)*k) <= resize(AddAIn_DI(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k), C_ACCU_LAST_SEG_LEN+2) +
                                                                                                resize(AddBIn_DI(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k), C_ACCU_LAST_SEG_LEN+2) +
                                                                                                resize(CarryA_DI(2*k+1 downto 2*k),C_ACCU_LAST_SEG_LEN+2) +
                                                                                                resize(CarryB_DI(2*k+1 downto 2*k),C_ACCU_LAST_SEG_LEN+2);

    Sum_DO(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k) <= AddTmp_D (C_ACCU_LAST_SEG_LEN + 2 + (G_ACCU_SEG_LEN+2)*k - 3 downto (G_ACCU_SEG_LEN+2)*k);

  end generate g_Last;
  ----------------------------------------------

  ----------------------------------------------
  g_Others : if (k < G_N_ACCU_SEGS-1) generate
  begin

    -- the carry bit is the MSB of the segment...
    AddTmp_D((G_ACCU_SEG_LEN+2)*(k+1) - 1 downto (G_ACCU_SEG_LEN+2)*k) <= resize(AddAIn_DI(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k),G_ACCU_SEG_LEN+2) +
                                                                          resize(AddBIn_DI(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k),G_ACCU_SEG_LEN+2) +
                                                                          resize(CarryA_DI(2*k+1 downto 2*k),G_ACCU_SEG_LEN+2) +
                                                                          resize(CarryB_DI(2*k+1 downto 2*k),G_ACCU_SEG_LEN+2);

    Sum_DO(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k) <= AddTmp_D ((G_ACCU_SEG_LEN+2)*(k+1) - 3 downto (G_ACCU_SEG_LEN+2)*k);

    Carry_DO(2*k+3 downto 2*k+2) <= AddTmp_D((G_ACCU_SEG_LEN+2)*(k+1)-1 downto (G_ACCU_SEG_LEN+2)*(k+1)-2);

  end generate g_Others;
  ----------------------------------------------
end generate g_AccuSegs;


end architecture RTL;






