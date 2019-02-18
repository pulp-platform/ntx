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

-- top level of the nst.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ntx_pkg.all;

entity ntx is
  generic (
    -- 0: ASIC, 1: ALTERA
    -- ASIC target assumes synopsys design compiler with designware.
    -- for synthesis, uncomment the DWARE libs above...
    G_TARGET           : natural := 0;
    -- for simulation purposes only
    G_NST_ID           : string  := "NTX";
    G_VERBOSE          : boolean := false
    );
  port (
    --------------------------
    Clk_CI            : in  std_logic;
    HalfClk_CI        : in  std_logic;-- phase synchronouos clock with half rate (for core interface)
    Rst_RBI           : in  std_logic;
    -- TCDM Port 0
    Tcdm0Req_SO       : out std_logic;
    Tcdm0Addr_DO      : out unsigned(C_ADDR_WIDTH-1 downto 0);
    Tcdm0Type_SO      : out std_logic;-- 1: read, 0: write
    Tcdm0ByteEn_SO    : out std_logic_vector(C_BYTE_ENABLE_WIDTH-1 downto 0);
    Tcdm0WriteData_DO : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
    Tcdm0Ack_SI       : in  std_logic;
    Tcdm0RValid_SI    : in  std_logic;
    Tcdm0RData_DI     : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
    -- TCDM Port 1
    Tcdm1Req_SO       : out std_logic;
    Tcdm1Addr_DO      : out unsigned(C_ADDR_WIDTH-1 downto 0);
    Tcdm1Type_SO      : out std_logic;-- 1: read, 0: write
    Tcdm1ByteEn_SO    : out std_logic_vector(C_BYTE_ENABLE_WIDTH-1 downto 0);
    Tcdm1WriteData_DO : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
    Tcdm1Ack_SI       : in  std_logic;
    Tcdm1RValid_SI    : in  std_logic;
    Tcdm1RData_DI     : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
    -- Staging area (running on HalfClk_CI)
    RegReq_SI         : in  std_logic;
    RegAddr_DI        : in  unsigned(C_ADDR_WIDTH-1 downto 0);
    RegType_SI        : in  std_logic;-- 1: read, 0: write
    RegByteEn_SI      : in  std_logic_vector(C_BYTE_ENABLE_WIDTH-1 downto 0); -- currently ignored...
    RegAck_SO         : out std_logic;
    RegWData_DI       : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
    RegRData_DO       : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
    RegRDataVld_SO    : out std_logic;
    -- interrupt line (raised upon completion of a command, if configured to do so)
    Interrupt_SO      : out std_logic;
    -- 00: higher prio than core, 01: RR, 10: 7 cycles to nst, 1 cycle to core
    Priority_SO       : out std_logic_vector(1 downto 0)
    --------------------------
    );
end entity ntx;

architecture RTL of ntx is

    -- internal, synchronous clear signal
    signal Clr_S                : std_logic;

    signal CtrlIdle_S           : std_logic;
    signal InvCmd_S             : std_logic;
    signal CmdIrq_S             : std_logic;

    signal NstJob_D             : T_NST_JOB;
    signal NstJobEmpty_S        : std_logic;
    signal NstJobReEn_S         : std_logic;

    signal CtrlTcdm0RReq_S      : std_logic;
    signal CtrlTcdm0RAck_S      : std_logic;
    signal CtrlTcdm0RAddr_D     : unsigned(C_ADDR_WIDTH-1 downto 0);
    signal CtrlTcdm1RReq_S      : std_logic;
    signal CtrlTcdm1RAck_S      : std_logic;
    signal CtrlTcdm1RAddr_D     : unsigned(C_ADDR_WIDTH-1 downto 0);
    signal CtrlTcdmToggle_SP, CtrlTcdmToggle_SN : std_logic;

    signal WbReq0_S              : std_logic;
    signal WbEn0_S               : std_logic;
    signal WbReq1_S              : std_logic;
    signal WbEn1_S               : std_logic;

    signal Tcdm0TagFifo_S       : std_logic;
    signal Tcdm0Type_S          : std_logic;
    signal Tcdm1TagFifo_S       : std_logic;
    signal Tcdm1Type_S          : std_logic;

    signal FpuEmpty_S           : std_logic;
    signal FpuCmd_D             : T_FPU_CMD;
    signal FpuCmdReEn_S         : std_logic;
    signal FpuCmdWrEn_S         : std_logic;
    signal FpuOpA_D             : std_logic_vector(C_DATA_WIDTH-1 downto 0);
    signal FpuOpAWrEn_S         : std_logic;
    signal FpuOpB_D             : std_logic_vector(C_DATA_WIDTH-1 downto 0);
    signal FpuOpBWrEn_S         : std_logic;
    signal FpuWbAddr_D          : unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
    signal FpuWbAddrWrEn_S      : std_logic;
    signal FpuOut_D             : std_logic_vector(C_DATA_WIDTH-1 downto 0);
    signal FpuOutEmpty_S        : std_logic;
    signal FpuOutAlmEmpty_S     : std_logic;
    signal FpuOutReEn_S         : std_logic;
    signal FpuWbAddrOut_D       : unsigned(C_AGU_ADDR_WIDTH-1 downto 0);
    signal FpuWbAddrEmpty_S     : std_logic;
    signal FpuWbAddrReEn_S      : std_logic;
    signal FpuWbIrq_S           : std_logic;

    signal DagStepEn_S          : std_logic;
    signal DagInit_S            : std_logic;
    signal DagDataAddr_D        : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
    signal DagLoopStartTrig_S   : std_logic_vector(C_N_HW_LOOPS downto 0);
    signal DagLoopEndTrig_S     : std_logic_vector(C_N_HW_LOOPS downto 0);

begin
----------------------------------------------------------------------------
-- TCDM writeback control
----------------------------------------------------------------------------

    -- control ensures that FIFOs will not overflow (using half-full flags...)
    FpuOpA_D          <= Tcdm0RData_DI;
    FpuOpAWrEn_S      <= Tcdm0RValid_SI and Tcdm0TagFifo_S;

    WbEn0_S           <= WbReq0_S and Tcdm0Ack_SI;

    -- writeback is only via port 1
    Tcdm0WriteData_DO <= FpuOut_D;
    Tcdm0Type_S       <= not WbReq0_S;
    Tcdm0Type_SO      <= Tcdm0Type_S;
    Tcdm0ByteEn_SO    <= (others=>(CtrlTcdm0RReq_S or WbReq0_S));
    Tcdm0Req_SO       <= CtrlTcdm0RReq_S or WbReq0_S;
    CtrlTcdm0RAck_S   <= Tcdm0Ack_SI and not WbReq0_S;

    Tcdm0Addr_DO      <= resize(FpuWbAddrOut_D   & "00", C_ADDR_WIDTH) when WbReq0_S = '1' else
                         CtrlTcdm0RAddr_D;

    FpuOpB_D          <= Tcdm1RData_DI;
    FpuOpBWrEn_S      <= Tcdm1RValid_SI and Tcdm1TagFifo_S;

    WbEn1_S           <= WbReq1_S and Tcdm1Ack_SI;

    FpuOutReEn_S      <= WbEn0_S or WbEn1_S;
    FpuWbAddrReEn_S   <= WbEn0_S or WbEn1_S;

    Tcdm1WriteData_DO <= FpuOut_D;
    Tcdm1Type_S       <= not WbReq1_S;
    Tcdm1Type_SO      <= Tcdm1Type_S;
    Tcdm1ByteEn_SO    <= (others=>(CtrlTcdm1RReq_S or WbReq1_S));
    Tcdm1Req_SO       <= CtrlTcdm1RReq_S or WbReq1_S;
    CtrlTcdm1RAck_S   <= Tcdm1Ack_SI and not WbReq1_S;

    Tcdm1Addr_DO      <= resize(FpuWbAddrOut_D   & "00", C_ADDR_WIDTH) when WbReq1_S = '1' else
                         CtrlTcdm1RAddr_D;

    -- WB always uses AGU2 ...
    FpuWbAddr_D       <= DagDataAddr_D(2);

    -- writeback control is self timed (via ports 0/1 in RR manner).
    -- so this is transparent for the main controller. we just have to
    -- generate the correct req/ack signals
    -- NOTE: WB only has prio over reads if there are > C_FPU_WB_THRESH (=1, typically) elems in the FIFO,
    -- otherwise reads have PRIO. this optimizes MAC sequences for convolutions, since the WB gets
    -- interleaved together with the init cycle.
    WbReq0_S           <= '1' when FpuOutEmpty_S = '0'    and FpuWbAddrEmpty_S = '0' and CtrlTcdm0RReq_S = '0' and CtrlTcdm1RReq_S = '1' else
                          '1' when FpuOutAlmEmpty_S = '0' and FpuWbAddrEmpty_S = '0' and CtrlTcdm0RReq_S = '1' and CtrlTcdm1RReq_S = '1' and CtrlTcdmToggle_SP = '0' else
                          '0';

    WbReq1_S           <= '1' when FpuOutEmpty_S = '0'    and FpuWbAddrEmpty_S = '0' and CtrlTcdm1RReq_S = '0' else
                          '1' when FpuOutAlmEmpty_S = '0' and FpuWbAddrEmpty_S = '0' and CtrlTcdm1RReq_S = '1' and CtrlTcdm0RReq_S = '1' and CtrlTcdmToggle_SP = '1' else
                          '0';

    CtrlTcdmToggle_SN <= not CtrlTcdmToggle_SP when ((WbEn1_S and CtrlTcdm1RReq_S) or (WbEn0_S and CtrlTcdm0RReq_S)) = '1' else
                         CtrlTcdmToggle_SP;

    p_clk : process(Clk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            CtrlTcdmToggle_SP <= '0';
        elsif Clk_CI'event and Clk_CI = '1' then
            CtrlTcdmToggle_SP <= CtrlTcdmToggle_SN;
        end if;
    end process p_clk;

----------------------------------------------------------------------------
-- track tcdm port transaction types in order to filter out write responses
----------------------------------------------------------------------------

    i_tag_fifo0 : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => 1,
        G_FIFO_DEPTH            => C_FPU_TCDM_READ_LATENCY+1,
        G_ALMOST_FULL_THRESH    => 1,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX TAG0 FIFO]",
        G_TARGET                => 0 -- always use ASIC implementation for this (due to low latency)
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_S,

        -- input port
        Data_DI(0)              => Tcdm0Type_S,
        WrEn_SI                 => Tcdm0Ack_SI,
        Full_SO                 => open,
        AlmFull_SO              => open,

        -- output port
        Data_DO(0)              => Tcdm0TagFifo_S,
        ReEn_SI                 => Tcdm0RValid_SI,
        Empty_SO                => open,
        AlmEmpty_SO             => open
    );

    i_tag_fifo1 : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => 1,
        G_FIFO_DEPTH            => C_FPU_TCDM_READ_LATENCY+1,
        G_ALMOST_FULL_THRESH    => 1,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX TAG1 FIFO]",
        G_TARGET                => 0 -- always use ASIC implementation for this (due to low latency)
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_S,

        -- input port
        Data_DI(0)              => Tcdm1Type_S,
        WrEn_SI                 => Tcdm1Ack_SI,
        Full_SO                 => open,
        AlmFull_SO              => open,

        -- output port
        Data_DO(0)              => Tcdm1TagFifo_S,
        ReEn_SI                 => Tcdm1RValid_SI,
        Empty_SO                => open,
        AlmEmpty_SO             => open
    );

----------------------------------------------------------------------------
-- instantiate subunits
----------------------------------------------------------------------------

    i_ntx_regIf : entity work.ntx_regIf
    generic map(
        G_TARGET           => G_TARGET
        )
    port map(
        Clk_CI              => Clk_CI,
        HalfClk_CI          => HalfClk_CI,
        Rst_RBI             => Rst_RBI,
        RegReq_SI           => RegReq_SI,
        RegAddr_DI          => RegAddr_DI,
        RegType_SI          => RegType_SI,
        RegByteEn_SI        => RegByteEn_SI,
        RegAck_SO           => RegAck_SO,
        RegWData_DI         => RegWData_DI,
        RegRData_DO         => RegRData_DO,
        RegRDataVld_SO      => RegRDataVld_SO,
        NstJobEmpty_SI      => NstJobEmpty_S,
        CtrlIdle_SI         => CtrlIdle_S,
        InvCmd_SI           => InvCmd_S,
        CmdIrq_SI           => CmdIrq_S,
        FpuEmpty_SI         => FpuEmpty_S,
        FpuWbIrq_SI         => FpuWbIrq_S,
        Priority_SO         => Priority_SO,
        Clr_SO              => Clr_S,
        Interrupt_SO        => Interrupt_SO,
        NstJob_DO           => NstJob_D,
        NstJobEmpty_SO      => NstJobEmpty_S,
        NstJobReEn_SI       => NstJobReEn_S
        );

    i_ntx_ctrl : entity work.ntx_ctrl
    generic map(
        G_NST_ID            => G_NST_ID,
        G_VERBOSE           => G_VERBOSE,
        G_TARGET            => G_TARGET
        )
    port map(
        Clk_CI              => Clk_CI,
        Rst_RBI             => Rst_RBI,
        Clr_SI              => Clr_S,
        Idle_SO             => CtrlIdle_S,
        CmdIrq_SO           => CmdIrq_S,
        InvCmd_SO           => InvCmd_S,
        NstJob_DI           => NstJob_D,
        NstJobEmpty_SI      => NstJobEmpty_S,
        NstJobReEn_SO       => NstJobReEn_S,
        Tcdm0RReq_SO        => CtrlTcdm0RReq_S,
        Tcdm0RAck_SI        => CtrlTcdm0RAck_S,
        Tcdm0RAddr_DO       => CtrlTcdm0RAddr_D,
        Tcdm1RReq_SO        => CtrlTcdm1RReq_S,
        Tcdm1RAck_SI        => CtrlTcdm1RAck_S,
        Tcdm1RAddr_DO       => CtrlTcdm1RAddr_D,
        FpuCmd_DO           => FpuCmd_D,
        FpuCmdReEn_SI       => FpuCmdReEn_S,
        FpuCmdWrEn_SO       => FpuCmdWrEn_S,
        FpuWbAddrWrEn_SO    => FpuWbAddrWrEn_S,
        DagDataAddr_DI      => DagDataAddr_D,
        DagStepEn_SO        => DagStepEn_S,
        DagInit_SO          => DagInit_S,
        DagLoopStartTrig_SI => DagLoopStartTrig_S,
        DagLoopEndTrig_SI   => DagLoopEndTrig_S
    );

    i_ntx_dag : entity work.ntx_dag
    port map(
        Clk_CI              => Clk_CI,
        Rst_RBI             => Rst_RBI,
        Clr_SI              => Clr_S,
        StepEn_SI           => DagStepEn_S,
        Init_SI             => DagInit_S,
        NstJob_DI           => NstJob_D,
        DataAddr_DO         => DagDataAddr_D,
        LoopStartTrig_SO    => DagLoopStartTrig_S,
        LoopEndTrig_SO      => DagLoopEndTrig_S
    );

    i_ntx_fpu : entity work.ntx_fpu
    generic map(
        G_TARGET            => G_TARGET
    )
    port map(
        Clk_CI              => Clk_CI,
        Rst_RBI             => Rst_RBI,
        Clr_SI              => Clr_S,
        FpuEmpty_SO         => FpuEmpty_S,
        FpuWbIrq_SO         => FpuWbIrq_S,
        Cmd_SI              => FpuCmd_D,
        CmdFull_SO          => open,
        CmdAlmFull_SO       => open,
        CmdReEn_SO          => FpuCmdReEn_S,
        CmdWrEn_SI          => FpuCmdWrEn_S,
        OpA_DI              => FpuOpA_D,
        OpAFull_SO          => open,
        OpAAlmFull_SO       => open,
        OpAWrEn_SI          => FpuOpAWrEn_S,
        OpB_DI              => FpuOpB_D,
        OpBFull_SO          => open,
        OpBAlmFull_SO       => open,
        OpBWrEn_SI          => FpuOpBWrEn_S,
        WbAddr_DI           => FpuWbAddr_D,
        WbAddrFull_SO       => open,
        WbAddrAlmFull_SO    => open,
        WbAddrWrEn_SI       => FpuWbAddrWrEn_S,
        Out_DO              => FpuOut_D,
        OutEmpty_SO         => FpuOutEmpty_S,
        OutAlmEmpty_SO      => FpuOutAlmEmpty_S,
        OutReEn_SI          => FpuOutReEn_S,
        WbAddr_DO           => FpuWbAddrOut_D,
        WbAddrEmpty_SO      => FpuWbAddrEmpty_S,
        WbAddrAlmEmpty_SO   => open,
        WbAddrReEn_SI       => FpuWbAddrReEn_S
    );


end architecture;
