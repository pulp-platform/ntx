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

-- streaming FPU for NTX

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fp32_pkg.all;
use work.ntx_pkg.all;
use work.ntx_tools_pkg.all;

entity ntx_fpu is
  generic (
    G_TARGET           : natural := 0 -- 0: ASIC, 1: ALTERA
    -- ASIC target assumes synopsys design compiler with designware.
    -- for synthesis, uncomment the DWARE libs above...
    );
  port (
    --------------------------
    Clk_CI             : in  std_logic;
    Rst_RBI            : in  std_logic;
    Clr_SI             : in  std_logic;
    --------------------------
    -- status
    FpuEmpty_SO        : out std_logic;
    FpuWbIrq_SO        : out std_logic;
    -- generic FIFO input interfaces
    Cmd_SI             : in  T_FPU_CMD;
    CmdFull_SO         : out std_logic;
    CmdAlmFull_SO      : out std_logic;
    CmdReEn_SO         : out std_logic;-- used for credit-based backpressure
    CmdWrEn_SI         : in  std_logic;

    OpA_DI             : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OpAFull_SO         : out std_logic;
    OpAAlmFull_SO      : out std_logic;
    OpAWrEn_SI         : in  std_logic;

    OpB_DI             : in  std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OpBFull_SO         : out std_logic;
    OpBAlmFull_SO      : out std_logic;
    OpBWrEn_SI         : in  std_logic;

    WbAddr_DI          : in  unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
    WbAddrFull_SO      : out std_logic;
    WbAddrAlmFull_SO   : out std_logic;
    WbAddrWrEn_SI      : in  std_logic;
    --------------------------
    -- generic FIFO output interfaces
    Out_DO             : out std_logic_vector(C_FP32_WIDTH-1 downto 0);
    OutEmpty_SO        : out std_logic;
    OutAlmEmpty_SO     : out std_logic;
    OutReEn_SI         : in  std_logic;

    WbAddr_DO          : out unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
    WbAddrEmpty_SO     : out std_logic;
    WbAddrAlmEmpty_SO  : out std_logic;
    WbAddrReEn_SI      : in  std_logic
    --------------------------
    );
end entity ntx_fpu;

architecture RTL of ntx_fpu is

    signal ExecuteCommand_S                 : std_logic;
    signal PipeInFlight_DN, PipeInFlight_DP : unsigned(log2ceil(C_FPU_OUTPUT_FIFO_DEPTH) downto 0);
    signal MacInFlight_DN, MacInFlight_DP   : unsigned(log2ceil(C_FPU_OUTPUT_FIFO_DEPTH) downto 0);

    signal CmdTmp_S                   : std_logic_vector(C_FPU_CMD_WDITH-1 downto 0);
    signal Cmd_S                      : T_FPU_CMD;
    signal CmdEmpty_S                 : std_logic;
    signal CmdReEn_S                  : std_logic;

    signal OpA_D                      : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal OpAEmpty_S                 : std_logic;
    signal OpAReEn_S                  : std_logic;

    signal OpB_D                      : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal OpBEmpty_S                 : std_logic;
    signal OpBReEn_S                  : std_logic;

    signal WbAddr_D                   : std_logic_vector(C_AGU_ADDR_WIDTH-1 downto 0);
    signal WbAddrReEn_S               : std_logic;
    signal WbAddrEmpty_S              : std_logic;
    signal WbAddrWrEn_S               : std_logic;

    signal Out_D                      : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal OutWrEn_S                  : std_logic;

    signal MacOpBSel_S                : std_logic_vector(1 downto 0);
    signal MacAccuEn_S                : std_logic;
    signal MacAccuSel_S               : std_logic;
    signal MacSubEn_S                 : std_logic;
    signal MacNormEn_S                : std_logic;
    signal MacReLuEn_SN, MacReLuEn_SP : std_logic_vector(C_FP32_MAC_LAT-1 downto 0);

    signal AluCntEqEn_S               : std_logic;
    signal AluLtEqSel_S               : std_logic_vector(1 downto 0);
    signal AluInvRes_S                : std_logic;
    signal AluAccuCntEn_S             : std_logic;
    signal AluAccuEn_S                : std_logic;
    signal AluAccuSet_S               : std_logic;
    signal AluRegMuxSel_S             : std_logic_vector(1 downto 0);
    signal AluOutMuxSel_S             : std_logic;
    signal AluOutVld_S                : std_logic;

    signal MacCondEn_S                : std_logic;

    signal AluCompRes_S               : std_logic;

    signal AluOut_D                   : std_logic_vector(C_FP32_WIDTH-1 downto 0);

    signal MacOut_D                   : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal ReLuOut_D                  : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal MacOutVld_S                : std_logic;

    signal AluAccuReg_D               : std_logic_vector(C_FP32_WIDTH-1 downto 0);
    signal MacOpBMux_D                : std_logic_vector(C_FP32_WIDTH-1 downto 0);

    -- used for interrupt request bypass within WbAddrFifo...
    signal FpuWbIrq_S                 : std_logic;
    signal TmpWbAddrIn_D              : std_logic_vector(C_AGU_ADDR_WIDTH downto 0);
    signal TmpWbAddrOut_D             : std_logic_vector(C_AGU_ADDR_WIDTH downto 0);

    signal MacEmpty_SP, MacEmpty_SN   : std_logic;
    signal PipeEmpty_SP, PipeEmpty_SN : std_logic;
    signal PipeFull_SP, PipeFull_SN   : std_logic;

begin
----------------------------------------------------------------------------
-- assertions
----------------------------------------------------------------------------

----------------------------------------------------------------------------
-- input FIFOs
-- (note: they have assertions that trigger when writing/reading
-- to a full/empty fifo internally!)
----------------------------------------------------------------------------

    i_cmd_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => C_FPU_CMD_WDITH,
        G_FIFO_DEPTH            => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH    => C_FPU_INPUT_FIFO_ALM_FULL,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX FPU CMD FIFO]",
        G_TARGET                => G_TARGET
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_SI,

        -- input port
        Data_DI                 => fpuCmd2slv(Cmd_SI),
        WrEn_SI                 => CmdWrEn_SI,
        Full_SO                 => CmdFull_SO,
        AlmFull_SO              => CmdAlmFull_SO,

        -- output port
        Data_DO                 => CmdTmp_S,
        ReEn_SI                 => CmdReEn_S,
        Empty_SO                => CmdEmpty_S,
        AlmEmpty_SO             => open
    );

    Cmd_S      <= slv2fpuCmd(CmdTmp_S);
    CmdReEn_SO <= CmdReEn_S;

    i_opA_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH          => C_FP32_WIDTH,
        G_FIFO_DEPTH          => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => C_FPU_INPUT_FIFO_ALM_FULL,
        G_ALMOST_EMPTY_THRESH => 1,
        G_FIFO_DESIGNATOR     => "[NTX OP A FIFO]",
        G_TARGET              => G_TARGET
        )
    port map(
        Clk_CI                => Clk_CI,
        Rst_RBI               => Rst_RBI,
        SftRst_RI             => Clr_SI,

        -- input port
        Data_DI               => OpA_DI,
        WrEn_SI               => OpAWrEn_SI,
        Full_SO               => OpAFull_SO,
        AlmFull_SO            => OpAAlmFull_SO,

        -- output port
        Data_DO               => OpA_D,
        ReEn_SI               => OpAReEn_S,
        Empty_SO              => OpAEmpty_S,
        AlmEmpty_SO           => open
    );

    i_opB_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH          => C_FP32_WIDTH,
        G_FIFO_DEPTH          => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => C_FPU_INPUT_FIFO_ALM_FULL,
        G_ALMOST_EMPTY_THRESH => 1,
        G_FIFO_DESIGNATOR     => "[NTX OP B FIFO]",
        G_TARGET              => G_TARGET
        )
    port map(
        Clk_CI                => Clk_CI,
        Rst_RBI               => Rst_RBI,
        SftRst_RI             => Clr_SI,

        -- input port
        Data_DI               => OpB_DI,
        WrEn_SI               => OpBWrEn_SI,
        Full_SO               => OpBFull_SO,
        AlmFull_SO            => OpBAlmFull_SO,

        -- output port
        Data_DO               => OpB_D,
        ReEn_SI               => OpBReEn_S,
        Empty_SO              => OpBEmpty_S,
        AlmEmpty_SO           => open
    );

    i_wbAddr_input_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH          => C_AGU_ADDR_WIDTH,
        G_FIFO_DEPTH          => C_FPU_INPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => C_FPU_INPUT_FIFO_ALM_FULL,
        G_ALMOST_EMPTY_THRESH => 1,
        G_FIFO_DESIGNATOR     => "[NTX WB ADDR INPUT FIFO]",
        G_TARGET              => G_TARGET
        )
    port map(
        Clk_CI                => Clk_CI,
        Rst_RBI               => Rst_RBI,
        SftRst_RI             => Clr_SI,

        -- input port
        Data_DI               => std_logic_vector(WbAddr_DI),
        WrEn_SI               => WbAddrWrEn_SI,
        Full_SO               => WbAddrFull_SO,
        AlmFull_SO            => WbAddrAlmFull_SO,

        -- output port
        Data_DO               => WbAddr_D,
        ReEn_SI               => WbAddrReEn_S,
        Empty_SO              => WbAddrEmpty_S,
        AlmEmpty_SO           => open
    );

----------------------------------------------------------------------------
-- output FIFOs
-- (note: they have assertions that trigger when writing/reading
-- to a full/empty fifo internally!)
----------------------------------------------------------------------------

    -- store the interrupt request here together with the writeback address
    TmpWbAddrIn_D <= FpuWbIrq_S & WbAddr_D;
    WbAddr_DO     <= unsigned(TmpWbAddrOut_D(TmpWbAddrOut_D'high-1 downto 0));

    i_wbAddr_output_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH          => C_AGU_ADDR_WIDTH+1,
        G_FIFO_DEPTH          => C_FPU_OUTPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => 1,
        G_ALMOST_EMPTY_THRESH => C_FPU_WB_THRESH,
        G_FIFO_DESIGNATOR     => "[NTX WB ADDR OUTPUT FIFO]",
        G_TARGET              => G_TARGET,
        G_OREGS               => 0-- for ASIC FIFOs. need to register the outputs due to TCDM
        )
    port map(
        Clk_CI                => Clk_CI,
        Rst_RBI               => Rst_RBI,
        SftRst_RI             => Clr_SI,

        -- input port
        Data_DI               => TmpWbAddrIn_D,
        WrEn_SI               => WbAddrWrEn_S,
        Full_SO               => open,
        AlmFull_SO            => open,

        -- output port
        Data_DO               => TmpWbAddrOut_D,
        ReEn_SI               => WbAddrReEn_SI,
        Empty_SO              => WbAddrEmpty_SO,
        AlmEmpty_SO           => WbAddrAlmEmpty_SO
    );

    i_output_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH          => C_FP32_WIDTH,
        G_FIFO_DEPTH          => C_FPU_OUTPUT_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH  => 1,
        G_ALMOST_EMPTY_THRESH => C_FPU_OUTPUT_FIFO_DEPTH/2,
        G_FIFO_DESIGNATOR     => "[NTX OUTPUT FIFO]",
        G_TARGET              => G_TARGET,
        G_OREGS               => 0-- for ASIC FIFOs. need to register the outputs due to TCDM
        )
    port map(
        Clk_CI                => Clk_CI,
        Rst_RBI               => Rst_RBI,
        SftRst_RI             => Clr_SI,

        -- input port
        Data_DI               => Out_D,
        WrEn_SI               => OutWrEn_S,
        Full_SO               => open,
        AlmFull_SO            => open,

        -- output port
        Data_DO               => Out_DO,
        ReEn_SI               => OutReEn_SI,
        Empty_SO              => OutEmpty_SO,
        AlmEmpty_SO           => OutAlmEmpty_SO
    );

----------------------------------------------------------------------------
-- FP MAC Unit
----------------------------------------------------------------------------

    MacOpBMux_D <= OpB_D           when MacOpBSel_S = "00" else
                   AluAccuReg_D    when MacOpBSel_S = "01" else
                   C_FP32_ZERO_VAL when MacOpBSel_S = "10" else
                   C_FP32_ONE_VAL;

    i_fp32_mac : entity work.fp32_mac
    generic map(
        G_TARGET => G_TARGET
    )
    port map (
        --------------------------
        Clk_CI            => Clk_CI,
        Rst_RBI           => Rst_RBI,
        Clr_SI            => Clr_SI,
        -- input
        OpA_DI            => OpA_D,
        OpB_DI            => MacOpBMux_D,
        AccuEn_SI         => MacAccuEn_S,
        AccuSel_SI        => MacAccuSel_S,
        SubEn_SI          => MacSubEn_S,
        NormEn_SI         => MacNormEn_S,
        -- output
        ResZ_DO           => MacOut_D,
        OutVld_SO         => MacOutVld_S
        --------------------------
    );

----------------------------------------------------------------------------
-- Other datapath units
----------------------------------------------------------------------------

    -- ReLu set to 0.0 if enabled...
    ReLuOut_D <= C_FP32_ZERO_VAL when MacReLuEn_SP(MacReLuEn_SP'high) = '1' and MacOut_D(MacOut_D'high) = '1' else
                 MacOut_D;

    -- output mux
    -- note that the credit-based control ensures
    -- that no collision between Alu and Mac can occur at this point...
    Out_D     <= ReLuOut_D when MacOutVld_S = '1' else
                 AluOut_D;

    i_ntx_fpu_alu : entity work.ntx_fpu_alu
    port map(
      --------------------------
      Clk_CI             => Clk_CI,
      Rst_RBI            => Rst_RBI,
      Clr_SI             => Clr_SI,
      -- input operands
      OpA_DI             => OpA_D,
      OpB_DI             => OpB_D,
      CntEqEn_SI         => AluCntEqEn_S,
      LtEqSel_SI         => AluLtEqSel_S,
      InvRes_SI          => AluInvRes_S,
      AccuCntEn_SI       => AluAccuCntEn_S,
      AccuEn_SI          => AluAccuEn_S,
      AccuSet_SI         => AluAccuSet_S,
      RegMuxSel_SI       => AluRegMuxSel_S,
      OutMuxSel_SI       => AluOutMuxSel_S,
      -- output
      Out_DO             => AluOut_D,
      AccuReg_DO         => AluAccuReg_D, -- used as temporary operand storage for MAC, can be used for efficient outer products...
      CompRes_SO         => AluCompRes_S
      --------------------------
      );

----------------------------------------------------------------------------
-- Control
----------------------------------------------------------------------------

    -- we need to make sure that we do not write into full fifos / read from empty fifos
    -- so add simple control which ensures this
    ExecuteCommand_S <= '0' when (Cmd_S.opAReEn    = '1' and OpAEmpty_S = '1')      else -- wait for input operand A
                        '0' when (Cmd_S.opBReEn    = '1' and OpBEmpty_S = '1')      else -- wait for input operand B
                        '0' when ((Cmd_S.macNormEn or Cmd_S.aluOutVld) = '1' and WbAddrEmpty_S = '1')   else -- wait for writeback address
                        '0' when PipeFull_SP       = '1' else -- wait until output FIFO has more space
                        '0' when (Cmd_S.aluOutVld  = '1') and (MacEmpty_SP = '0') else  -- wait until the MAC pipeline is empty to ensure in-order WB
                        not CmdEmpty_S;

    -- pop the command upon execution
    CmdReEn_S       <= ExecuteCommand_S;

    -- backpressure from output fifo through MAC is handled using "credit" counters, i.e., we keep track of the amount
    -- of elements that are in flight (within the MAC), and make sure they do not exceed the FIFO depth.
    -- most operations are reductions anyway, which means that we do not need an output FIFO that is able to catch as many elements
    -- as could fit into the pipeline (10 in this case)
    PipeInFlight_DN <= PipeInFlight_DP     when (MacNormEn_S = '1' or AluOutVld_S = '1') and (OutReEn_SI = '1') else -- do nothing if an element is pushed and popped at the same time
                       PipeInFlight_DP + 1 when (MacNormEn_S = '1' or AluOutVld_S = '1') else -- increment
                       PipeInFlight_DP - 1 when (OutReEn_SI = '1') else -- decrement
                       PipeInFlight_DP;

    MacInFlight_DN  <= MacInFlight_DP     when (MacNormEn_S = '1') and (MacOutVld_S = '1') else -- do nothing if an element is pushed and popped at the same time
                       MacInFlight_DP + 1 when (MacNormEn_S = '1') else -- increment
                       MacInFlight_DP - 1 when (MacOutVld_S = '1') else -- decrement
                       MacInFlight_DP;

    -- gate all control signals that trigger a write or read with the execution signal
    OpAReEn_S      <= Cmd_S.opAReEn      and ExecuteCommand_S;
    OpBReEn_S      <= Cmd_S.opBReEn      and ExecuteCommand_S;
    WbAddrReEn_S   <= (Cmd_S.macNormEn or Cmd_S.aluOutVld) and ExecuteCommand_S;

    -- MAC control
    MacOpBSel_S    <= Cmd_S.macOpBSel;
    MacAccuSel_S   <= Cmd_S.macAccuSel;
    MacSubEn_S     <= Cmd_S.macSubEn;

    -- enable conditional MAC / WB
    MacAccuEn_S    <= Cmd_S.macAccuEn and AluCompRes_S and ExecuteCommand_S when MacCondEn_S = '1' else
                      Cmd_S.macAccuEn and ExecuteCommand_S;

    MacNormEn_S    <= Cmd_S.macNormEn and AluCompRes_S and ExecuteCommand_S when MacCondEn_S = '1' else
                      Cmd_S.macNormEn and ExecuteCommand_S;

    WbAddrWrEn_S   <= MacNormEn_S or AluOutVld_S;

    -- the immediate ReLu is chained after the MAC, and therefore we need to add shimming regs
    MacReLuEn_SN   <= MacReLuEn_SP(MacReLuEn_SP'high-1 downto 0) & Cmd_S.macReLuEn;

    -- ALU control
    AluCntEqEn_S   <= Cmd_S.aluCntEqEn;
    AluLtEqSel_S   <= Cmd_S.aluLtEqSel;
    AluInvRes_S    <= Cmd_S.aluInvRes;
    AluAccuCntEn_S <= Cmd_S.aluAccuCntEn     and ExecuteCommand_S;
    AluAccuEn_S    <= Cmd_S.aluAccuEn        and ExecuteCommand_S;
    AluAccuSet_S   <= Cmd_S.aluAccuSet       and ExecuteCommand_S;
    AluRegMuxSel_S <= Cmd_S.aluRegMuxSel;
    AluOutMuxSel_S <= Cmd_S.aluOutMuxSel;
    AluOutVld_S    <= Cmd_S.aluOutVld        and ExecuteCommand_S;

    -- conditional MACs and WBs, interrupt request
    MacCondEn_S    <= Cmd_S.macCondEn;
    FpuWbIrq_S     <= Cmd_S.fpuWbIrq;

    -- determines when to write to the output fifo
    OutWrEn_S      <= MacOutVld_S or AluOutVld_S;

    MacEmpty_SN    <= to_std_logic(MacInFlight_DN = 0,false);
    PipeEmpty_SN   <= to_std_logic(PipeInFlight_DN = 0,false);
    PipeFull_SN    <= to_std_logic(PipeInFlight_DN = C_FPU_OUTPUT_FIFO_DEPTH,false);

    -- check if pipeline is empty...
    FpuEmpty_SO <= PipeEmpty_SP  and
                   WbAddrEmpty_S and
                   OpBEmpty_S    and
                   OpAEmpty_S    and
                   CmdEmpty_S;

    -- trigger interrupt if requested.
    -- note that in the case of conditional writebacks,
    -- we have to raise the interrupt immediately if no
    -- words are to be written in this cycle.
    FpuWbIrq_SO <= '1' when TmpWbAddrOut_D(TmpWbAddrOut_D'high) = '1' and WbAddrReEn_SI = '1' else
                   '1' when FpuWbIrq_S = '1' and WbAddrReEn_S = '1'   and WbAddrWrEn_S = '0' else
                   '0';

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

    p_clk : process(Clk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            MacEmpty_SP     <= '0';
            PipeEmpty_SP    <= '0';
            PipeFull_SP     <= '0';
            MacReLuEn_SP    <= (others=>'0');
            PipeInFlight_DP <= (others=>'0');
            MacInFlight_DP  <= (others=>'0');
        elsif Clk_CI'event and Clk_CI = '1' then
            MacEmpty_SP     <= MacEmpty_SN;
            PipeFull_SP     <= PipeFull_SN;
            PipeEmpty_SP    <= PipeEmpty_SN;
            if Clr_SI = '1' then
                MacReLuEn_SP    <= (others=>'0');
                PipeInFlight_DP <= (others=>'0');
                MacInFlight_DP  <= (others=>'0');
            else
                MacInFlight_DP  <= MacInFlight_DN;
                MacReLuEn_SP    <= MacReLuEn_SN;
                PipeInFlight_DP <= PipeInFlight_DN;
            end if;
        end if;
    end process p_clk;

end architecture;













