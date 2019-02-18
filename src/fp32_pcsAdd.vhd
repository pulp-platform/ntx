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
use ieee.math_real.all;
use work.fp32_pkg.all;
use work.ntx_tools_pkg.all;

entity fp32_pcsAdd is
  generic (
    G_ACCU_WIDTH      : natural := 100;
    G_N_ACCU_SEGS     : natural := 4;
    G_ACCU_SEG_LEN    : natural := 25;
    G_CARRY_PROP_ONLY : boolean := false
  );
  port (
    -- value to add to the accumulator state
    AddIn_DI    : in  unsigned(G_ACCU_WIDTH-1 downto 0);
    -- accumulated state input
    Accu_DI      : in  unsigned(G_ACCU_WIDTH-1 downto 0);
    Carry_DI     : in  unsigned(G_N_ACCU_SEGS-1 downto 0);-- lsb can be used as carry in for the lowest bit...
    -- accumulated state ouput
    Accu_DO      : out unsigned(G_ACCU_WIDTH-1 downto 0);
    Carry_DO     : out unsigned(G_N_ACCU_SEGS-1 downto 0);
    Overflow_SO  : out std_logic -- overflow carry bit
    );
end fp32_pcsAdd;

architecture RTL of fp32_pcsAdd is

signal AccuTmp_D : unsigned(G_N_ACCU_SEGS + G_ACCU_WIDTH-1 downto 0);

-- the last segment has the same length as all others in the case where G_ACCU_WIDTH is divisible by G_ACCU_SEG_LEN
constant C_ACCU_LAST_SEG_LEN : natural := (G_ACCU_SEG_LEN - G_ACCU_SEG_LEN*G_N_ACCU_SEGS + G_ACCU_WIDTH) * (1 - isDiv(G_ACCU_WIDTH,G_ACCU_SEG_LEN)) +
                                          (G_ACCU_SEG_LEN * isDiv(G_ACCU_WIDTH,G_ACCU_SEG_LEN));

begin
-----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------
--synopsys translate_off
assert G_N_ACCU_SEGS > 1             report "G_N_ACCU_SEGS > 1 expected!"             severity failure;
assert C_ACCU_LAST_SEG_LEN > 0       report "C_ACCU_LAST_SEG_LEN is zero or negative" severity failure;
assert G_N_ACCU_SEGS <= G_ACCU_WIDTH report "G_N_ACCU_SEGS > G_ACCU_WIDTH"            severity failure;
--synopsys translate_on
-----------------------------------------------------------------------------
-- generate partial carry save adder segments (individual segments may
-- use tool dependent adder synthesis)
-----------------------------------------------------------------------------

Carry_DO(0) <= '0';
Overflow_SO <= AccuTmp_D(AccuTmp_D'high);


g_AccuSegs : for k in 0 to G_N_ACCU_SEGS-1 generate
begin

  ----------------------------------------------
   g_Last : if (k = G_N_ACCU_SEGS-1) generate
   begin


     g_addIn : if (G_CARRY_PROP_ONLY = false) generate
     begin
       -- the carry bit is the MSB of the segment...
       AccuTmp_D(C_ACCU_LAST_SEG_LEN + 1 + (G_ACCU_SEG_LEN+1)*k - 1 downto (G_ACCU_SEG_LEN+1)*k) <= resize(AddIn_DI(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k),C_ACCU_LAST_SEG_LEN+1) +
                                                                                                    resize(Accu_DI(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k),C_ACCU_LAST_SEG_LEN+1) +
                                                                                                    resize(Carry_DI(k downto k),C_ACCU_LAST_SEG_LEN+1);
     end generate g_addIn;

     g_noAddIn : if (G_CARRY_PROP_ONLY = true) generate
     begin
       -- the carry bit is the MSB of the segment...
       AccuTmp_D(C_ACCU_LAST_SEG_LEN + 1 + (G_ACCU_SEG_LEN+1)*k - 1 downto (G_ACCU_SEG_LEN+1)*k) <= resize(Accu_DI(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k),C_ACCU_LAST_SEG_LEN+1) +
                                                                                                    resize(Carry_DI(k downto k),C_ACCU_LAST_SEG_LEN+1);
     end generate g_noAddIn;


     Accu_DO(C_ACCU_LAST_SEG_LEN + G_ACCU_SEG_LEN*k - 1 downto G_ACCU_SEG_LEN*k) <= AccuTmp_D (C_ACCU_LAST_SEG_LEN + 1 + (G_ACCU_SEG_LEN+1)*k - 2 downto (G_ACCU_SEG_LEN+1)*k);


   end generate g_Last;
   ----------------------------------------------

   ----------------------------------------------
   g_Others : if (k < G_N_ACCU_SEGS-1) generate
   begin

     g_addIn : if (G_CARRY_PROP_ONLY = false) generate
     begin
       -- the carry bit is the MSB of the segment...
       AccuTmp_D((G_ACCU_SEG_LEN+1)*(k+1) - 1 downto (G_ACCU_SEG_LEN+1)*k) <= resize(AddIn_DI(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k),G_ACCU_SEG_LEN+1) +
                                                                              resize(Accu_DI(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k),G_ACCU_SEG_LEN+1) +
                                                                              resize(Carry_DI(k downto k),G_ACCU_SEG_LEN+1);
     end generate g_addIn;

     g_noAddIn : if (G_CARRY_PROP_ONLY = true) generate
     begin
       -- the carry bit is the MSB of the segment...
       AccuTmp_D((G_ACCU_SEG_LEN+1)*(k+1) - 1 downto (G_ACCU_SEG_LEN+1)*k) <= resize(Accu_DI(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k),G_ACCU_SEG_LEN+1) +
                                                                              resize(Carry_DI(k downto k),G_ACCU_SEG_LEN+1);
     end generate g_noAddIn;


     Accu_DO(G_ACCU_SEG_LEN*(k+1) - 1 downto G_ACCU_SEG_LEN*k) <= AccuTmp_D ((G_ACCU_SEG_LEN+1)*(k+1) - 2 downto (G_ACCU_SEG_LEN+1)*k);

     Carry_DO(k+1) <= AccuTmp_D((G_ACCU_SEG_LEN+1)*(k+1)-1);

   end generate g_Others;
   ----------------------------------------------

end generate g_AccuSegs;


end architecture RTL;






