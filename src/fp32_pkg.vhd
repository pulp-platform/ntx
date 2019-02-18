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

package fp32_pkg is

-----------------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------------

-- standard IEEE fp32 widths, do not change widths!
-- note: denorm numbers are not supported
constant C_FP32_EXP_WIDTH           : natural := 8;
constant C_FP32_MANT_WIDTH          : natural := 23;
constant C_FP32_WIDTH               : natural := 32;
constant C_FP32_BIAS                : natural := 127;
constant C_FP32_MAX_EXP             : natural := 255;
constant C_FP32_MAX_MANT            : natural := 2**23-1;

-- for partial carry-save (PCS) arithmetic
-- total width is 284bit (= 1bit + 23bit + 2^8bit + 4bit, i.e. sign plus
-- mantissa plus range + overflow bits)
constant C_FP32_N_ACCU_OFLOW_BITS : natural  := 4;
-- 129 bit here
constant C_FP32_PCS_INT_WIDTH     : natural  := 1 + 2**(C_FP32_EXP_WIDTH-1); -- 2**(C_FP32_EXP_WIDTH-1)
-- 151 bit here
constant C_FP32_PCS_FRAC_WIDTH    : natural  := 2**(C_FP32_EXP_WIDTH-1)  + C_FP32_MANT_WIDTH;  -- 2**(C_FP32_EXP_WIDTH-1) + C_FP32_MANT_WIDTH
-- 284 bit here
constant C_FP32_PCS_WIDTH         : natural  := C_FP32_PCS_INT_WIDTH     + C_FP32_PCS_FRAC_WIDTH + C_FP32_N_ACCU_OFLOW_BITS;

constant C_FP32_PCS_SEG_LEN       : natural  := 142;
constant C_FP32_PCS_N_SEGS        : natural  := 2; -- note: the normalizer currently assumes exactly two segments, so do not change this

-----------------------------------------------------------------------------
-- Types
-----------------------------------------------------------------------------

type T_FP32_ARRAY is array(natural range <>) of std_logic_vector(C_FP32_WIDTH-1 downto 0);

-- some default values
constant C_FP32_ONE_VAL   : std_logic_vector(C_FP32_WIDTH-1 downto 0) := x"3F800000";
constant C_FP32_ZERO_VAL  : std_logic_vector(C_FP32_WIDTH-1 downto 0) := x"00000000";

-- nans are interpreted as infinities at the moment!
--constant C_FP32_NAN_VAL   : std_logic_vector(C_FP32_WIDTH-1 downto 0) := x"7F800001";
constant C_FP32_INF_VAL   : std_logic_vector(C_FP32_WIDTH-1 downto 0) := x"7F800000";

-----------------------------------------------------------------------------
-- Conversion Functions
-----------------------------------------------------------------------------

function fp32_getSign (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic;

-- unbiased!
function fp32_getExp  (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return unsigned;
function fp32_getMant (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return unsigned;

-- works for +/- values!
--function fp32_isNan  (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0))  return std_logic;
function fp32_isInf  (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0))  return std_logic;
function fp32_isZero (inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0))  return std_logic;

-- pack the fields
function fp32_pack  (s : std_logic;
                     e : unsigned(C_FP32_EXP_WIDTH-1 downto 0);
                     m : unsigned(C_FP32_MANT_WIDTH-1 downto 0) )  return std_logic_vector;

end package fp32_pkg;

package body fp32_pkg is

  function fp32_getSign(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic is
    variable outval : std_logic;
  begin
    outval := inval(inval'high);
    return outval;
  end fp32_getSign;

  function fp32_getExp(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return unsigned is
    variable outval : unsigned(C_FP32_EXP_WIDTH - 1 downto 0);
  begin
    outval := unsigned(inval(inval'high-1 downto inval'high-C_FP32_EXP_WIDTH));
    return outval;
  end fp32_getExp;

  function fp32_getMant(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return unsigned is
    variable outval : unsigned(C_FP32_MANT_WIDTH - 1 downto 0);
  begin
    outval := unsigned(inval(C_FP32_MANT_WIDTH-1 downto 0));
    return outval;
  end fp32_getMant;


  --function fp32_isNan(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic is
  --  variable outval : std_logic;
  --begin
  --  if (fp32_getExp(inval) = C_FP32_MAX_EXP) and (fp32_getMant(inval) /= 0) then
  --    outval := '1';
  --  else
  --    outval := '0';
  --  end if;
  --  return outval;
  --end fp32_isNan;

  -- need to use this when nans are supported as well
  --function fp32_isInf(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic is
  --  variable outval : std_logic;
  --begin
  --  if (fp32_getExp(inval) = C_FP32_MAX_EXP) and (fp32_getMant(inval) = 0) then
  --    outval := '1';
  --  else
  --    outval := '0';
  --  end if;
  --  return outval;
  --end fp32_isInf;

  function fp32_isInf(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic is
    variable outval : std_logic;
  begin
    if (fp32_getExp(inval) = C_FP32_MAX_EXP) then
      outval := '1';
    else
      outval := '0';
    end if;
    return outval;
  end fp32_isInf;

  function fp32_isZero(inval : std_logic_vector(C_FP32_WIDTH - 1 downto 0)) return std_logic is
    variable outval : std_logic;
  begin
    if (fp32_getExp(inval) = 0) and (fp32_getMant(inval) = 0) then
      outval := '1';
    else
      outval := '0';
    end if;
    return outval;
  end fp32_isZero;


  function fp32_pack(s : std_logic; e : unsigned(C_FP32_EXP_WIDTH-1 downto 0); m : unsigned(C_FP32_MANT_WIDTH-1 downto 0)) return std_logic_vector is
    variable outval : std_logic_vector(C_FP32_WIDTH - 1 downto 0);
  begin
    outval := s & std_logic_vector(e) & std_logic_vector(m);
    return outval;
  end fp32_pack;

end fp32_pkg;
