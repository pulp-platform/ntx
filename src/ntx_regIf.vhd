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

-- register read/write interface of the NTX. contains a register bank that can
-- be used for staging, and a command FIFO. this FIFO is currently degenerate
-- and set to depth 1 due to the large amount of DAG and loop registers. the
-- FIFO holds the currently processed command, which is being popped from the
-- FIFO upon completion. note however, that the design allows to have 2 commands
-- in flight overall (1 being processed, one in the queue), as the staging area
-- acts as a second FIFO entry. the staging area is frozen and marked read-only
-- in if the NTX is still busy and a second command is being commited.
--
-- note: the synchronouos clear does not reset the staging area, but it clears
-- IRQs and the ctrl reg.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ntx_pkg.all;
use work.ntx_tools_pkg.all;

entity ntx_regIf is
  generic (
    -- 0: ASIC, 1: ALTERA
    -- ASIC target assumes synopsys design compiler with designware.
    -- for synthesis, uncomment the DWARE libs above...
    G_TARGET          : natural := 1
    );
  port (
    --------------------------
    Clk_CI            : in  std_logic;
    HalfClk_CI        : in  std_logic;-- phase synchronouos clock with half rate (for core interface)
    Rst_RBI           : in  std_logic;
    -- staging area
    RegReq_SI         : in  std_logic;
    RegAddr_DI        : in  unsigned(C_ADDR_WIDTH-1 downto 0);
    RegType_SI        : in  std_logic;-- 1: read, 0: write
    RegByteEn_SI      : in  std_logic_vector(C_BYTE_ENABLE_WIDTH-1 downto 0); -- currently ignored...
    RegAck_SO         : out std_logic;
    RegWData_DI       : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
    RegRData_DO       : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
    RegRDataVld_SO    : out std_logic;
    -- ctrl/status/irq regs
    NstJobEmpty_SI    : in  std_logic;
    CtrlIdle_SI       : in  std_logic;
    CmdIrq_SI         : in  std_logic;
    InvCmd_SI         : in  std_logic;
    FpuEmpty_SI       : in  std_logic;
    FpuWbIrq_SI       : in  std_logic;
    Priority_SO       : out std_logic_vector(1 downto 0);
    Clr_SO            : out std_logic;
    Interrupt_SO      : out std_logic;
    -- NTX Job Fifo
    NstJob_DO         : out T_NST_JOB;
    NstJobEmpty_SO    : out std_logic;
    NstJobReEn_SI     : in  std_logic
    --------------------------
    );
end entity ntx_regIf;


architecture RTL of ntx_regIf is

    signal Clr_S                          : std_logic;
    signal Sel_S, RegWe_S, RegRe_S        : std_logic;
    signal RegAck_S                       : std_logic;

    signal AddrHotOne_S                   : std_logic_vector(2**C_REG_ADDR_WIDTH-1 downto 0);

    signal RegRDataVld_SN, RegRDataVld_SP : std_logic;
    signal RegAddrShort_D                 : unsigned(C_REG_ADDR_WIDTH-1 downto 0);
	signal RegRData_DN, RegRData_DP       : std_logic_vector(C_DATA_WIDTH-1 downto 0);
    signal NstCmdRegReq_S                 : std_logic;
    signal NstJobIn_D                     : T_NST_JOB;
    signal NstJobInTmp_D                  : std_logic_vector(C_NST_JOB_WIDTH-1 downto 0);
    signal NstJobWrEn_S, NstJobFull_S     : std_logic;
    signal NstJobTmp_D                    : std_logic_vector(C_NST_JOB_WIDTH-1 downto 0);

    -- registers
    signal StatusReg_DN, StatusReg_DP     : unsigned(4 downto 0);
    signal CtrlReg_DN, CtrlReg_DP         : unsigned(2 downto 0);
    signal CmdReg_DN, CmdReg_DP           : std_logic_vector(C_NST_CMD_WIDTH-1 downto 0);
    signal IrqReg_DN, IrqReg_DP           : unsigned(1 downto 0);
    signal LoopEnd_DN, LoopEnd_DP         : T_LOOP_ARRAY(C_N_HW_LOOPS-1 downto 0);
    signal AguBase_DN, AguBase_DP         : T_AGU_ADDRESS_ARRAY(C_N_AGUS-1 downto 0);
    signal AguStride_DN, AguStride_DP     : T_AGU_ADDRESS_ARRAY(C_N_HW_LOOPS*C_N_AGUS-1 downto 0);

    signal IsCommited_SP, IsCommited_SN   : std_logic;

    signal NstJobWrEnToggle_SP, NstJobWrEnToggle_SN : std_logic;
    signal NstJobWrEnSync_SP, NstJobWrEnSync_SN, NstJobWrEnSync_S : std_logic;

begin
----------------------------------------------------------------------------
-- readout mux, selection signals...
----------------------------------------------------------------------------

    Sel_S <= RegReq_SI;

    --    -- generate select signal
    --    Sel_S          <= RegReq_SI when G_NST_BASE_ADDRESS(G_NST_BASE_ADDRESS'high downto C_REG_ADDR_WIDTH+2) = RegAddr_DI(G_NST_BASE_ADDRESS'high downto C_REG_ADDR_WIDTH+2) else
    --                      '0';

    -- internal register address
    RegAddrShort_D <= unsigned(RegAddr_DI(C_REG_ADDR_WIDTH+1 downto 2));
    AddrHotOne_S   <= Hot1EncodeDn (RegAddrShort_D, AddrHotOne_S'length);

    RegWe_S        <= Sel_S and (not RegType_SI);
    RegRe_S        <= Sel_S and RegType_SI;

    -- write may block if the staging area is in commited state...
    RegAck_S       <= '1' when (RegRe_S = '1') else
                      '1' when (RegWe_S = '1') and (IsCommited_SP = '0') else
                      '0';

    -- a write returns immediately, a read takes one cycle...
    RegRDataVld_SO <= RegRDataVld_SP;
    RegRDataVld_SN <= RegAck_S;
    RegAck_SO      <= RegAck_S;

    RegRData_DO    <= RegRData_DP;

    -- readout mux
    p_readMux : process (all)
    begin
        RegRData_DN <= (others=>'0');

        if RegRe_S = '1' then
            if AddrHotOne_S(C_NST_IRQ_REG/4) = '1' then
                RegRData_DN <= std_logic_vector(resize(IrqReg_DP, C_DATA_WIDTH));
            elsif AddrHotOne_S(C_NST_CTRL_REG/4) = '1' then
                RegRData_DN <= std_logic_vector(resize(CtrlReg_DP, C_DATA_WIDTH));
            elsif AddrHotOne_S(C_NST_STAT_REG/4) = '1' then
                RegRData_DN <= std_logic_vector(resize(StatusReg_DP, C_DATA_WIDTH));
            elsif AddrHotOne_S(C_NST_CMD_REG/4) = '1' then
                RegRData_DN <= std_logic_vector(resize(unsigned(CmdReg_DP), C_DATA_WIDTH));
            else

                for k in 0 to C_N_HW_LOOPS-1 loop
                    if AddrHotOne_S(k + C_NST_LOOP_REGS/4) = '1' then
                        RegRData_DN <= std_logic_vector(resize(LoopEnd_DP(k), C_DATA_WIDTH));
                     end if;
                end loop;

                for k in 0 to C_N_AGUS-1 loop
                    if AddrHotOne_S(C_NST_AGU0_REGS/4 + k*(C_N_HW_LOOPS+1)) = '1' then
                        RegRData_DN <= std_logic_vector(resize(AguBase_DP(k), C_DATA_WIDTH));
                     end if;
                end loop;

                for k in 0 to C_N_HW_LOOPS*C_N_AGUS-1 loop
                    if AddrHotOne_S(C_NST_AGU0_REGS/4 +(k/C_N_HW_LOOPS) * (C_N_HW_LOOPS+1) + (k mod C_N_HW_LOOPS)+1) = '1' then
                        RegRData_DN <= std_logic_vector(resize(AguStride_DP(k), C_DATA_WIDTH));
                     end if;
                end loop;

            end if;
        end if;
    end process p_readMux;

----------------------------------------------------------------------------
-- STATUS register (runs on double clock)
----------------------------------------------------------------------------

    StatusReg_DN <= IsCommited_SN &
                    InvCmd_SI     &
                    CtrlIdle_SI   &
                    FpuEmpty_SI   &
                    NstJobEmpty_SI;

----------------------------------------------------------------------------
-- CTRL register
----------------------------------------------------------------------------

   -- control reg
   CtrlReg_DN <= (others=>'0')                            when Clr_S = '1' else
                  unsigned(RegWData_DI(CtrlReg_DN'range)) when AddrHotOne_S(C_NST_CTRL_REG/4) = '1' and RegWe_S = '1' else
                  CtrlReg_DP;

   -- these regs are also cleared to zero upon reset!
   Clr_SO      <= CtrlReg_DP(0);
   Clr_S       <= CtrlReg_DP(0);
   Priority_SO <= std_logic_vector(CtrlReg_DP(2 downto 1));

----------------------------------------------------------------------------
-- IRQ register (runs on double clock)
----------------------------------------------------------------------------

    -- cmd IRQ
    IrqReg_DN (0) <= '0' when Clr_S = '1' else
                     '0' when RegWData_DI(0) = '1' and AddrHotOne_S(C_NST_IRQ_REG/4) = '1' and RegWe_S = '1' else
                     IrqReg_DP(0) or FpuWbIrq_SI;

    -- WB IRQ
    IrqReg_DN (1) <= '0' when Clr_S = '1' else
                     '0' when RegWData_DI(1) = '1' and AddrHotOne_S(C_NST_IRQ_REG/4) = '1' and RegWe_S = '1' else
                     IrqReg_DP(1) or CmdIrq_SI;

    Interrupt_SO  <= VectorOR(IrqReg_DP);

----------------------------------------------------------------------------
-- CMD register
----------------------------------------------------------------------------

    -- write directly into FIFO
    NstJobIn_D.loopEnd   <= LoopEnd_DP;
    NstJobIn_D.aguBase   <= AguBase_DP;
    NstJobIn_D.aguStride <= AguStride_DP;

    NstJobIn_D.nstCmd    <= slv2nstCmd(CmdReg_DP);

    NstCmdRegReq_S       <= '1' when AddrHotOne_S(C_NST_CMD_REG/4) = '1' and RegWe_S = '1' else
                            '0';

    IsCommited_SN        <= (IsCommited_SP or NstCmdRegReq_S) and not NstJobWrEn_S;

    NstJobWrEn_S         <= '1' when IsCommited_SP = '1' and NstJobFull_S = '0' else
                            '0';

    CmdReg_DN            <= (others=>'0')                when Clr_S = '1' else
                            RegWData_DI(CmdReg_DN'range) when NstCmdRegReq_S = '1' and IsCommited_SP = '0' else
                            CmdReg_DP;

    NstJobWrEnToggle_SN <= not NstJobWrEnToggle_SP when NstJobWrEn_S = '1' else
                           NstJobWrEnToggle_SP;

    NstJobWrEnSync_SN   <= NstJobWrEnToggle_SP;

    NstJobWrEnSync_S    <= NstJobWrEnSync_SN xor NstJobWrEnSync_SP;

----------------------------------------------------------------------------
-- LOOP bound registers
----------------------------------------------------------------------------

    g_loopRegs : for k in 0 to C_N_HW_LOOPS-1 generate
    begin
        LoopEnd_DN(k) <= unsigned(RegWData_DI(C_HW_LOOP_WIDTH-1 downto 0)) when AddrHotOne_S(C_NST_LOOP_REGS/4+k) = '1' and RegWe_S = '1' and IsCommited_SP = '0' else
                         LoopEnd_DP(k);
    end generate g_loopRegs;

----------------------------------------------------------------------------
-- AGU Offsets and Strides
----------------------------------------------------------------------------

    -- note: we have to cut off the lower two bits from the input addresses in order to word-align them...
    g_aguOffs : for g in 0 to C_N_AGUS-1 generate
    begin
        AguBase_DN(g) <= unsigned(RegWData_DI(C_AGU_ADDR_WIDTH+2-1 downto 2)) when AddrHotOne_S(C_NST_AGU0_REGS/4 + g*(C_N_HW_LOOPS+1)) = '1' and RegWe_S = '1' and IsCommited_SP = '0' else
                         AguBase_DP(g);
    end generate g_aguOffs;


    g_aguStrides : for k in 0 to C_N_HW_LOOPS*C_N_AGUS-1 generate
    begin
        AguStride_DN(k) <=  unsigned(RegWData_DI(C_AGU_ADDR_WIDTH+2-1 downto 2)) when AddrHotOne_S(C_NST_AGU0_REGS/4 + (k/C_N_HW_LOOPS) * (C_N_HW_LOOPS+1) + (k mod C_N_HW_LOOPS) + 1) = '1' and RegWe_S = '1' and IsCommited_SP = '0' else
                            AguStride_DP(k);
    end generate g_aguStrides;

----------------------------------------------------------------------------
-- NTX JOB FIFO
----------------------------------------------------------------------------

    NstJobInTmp_D <= nstJob2slv(NstJobIn_D);

    i_ntx_job_fifo : entity work.ntx_fifo
    generic map(
        G_DATA_WIDTH            => C_NST_JOB_WIDTH,
        G_FIFO_DEPTH            => C_NST_JOB_FIFO_DEPTH,
        G_ALMOST_FULL_THRESH    => 1,
        G_ALMOST_EMPTY_THRESH   => 1,
        G_FIFO_DESIGNATOR       => "[NTX JOB FIFO]",
        G_TARGET                => G_TARGET
        )
    port map(
        Clk_CI                  => Clk_CI,
        Rst_RBI                 => Rst_RBI,
        SftRst_RI               => Clr_S,

        -- input port
        Data_DI                 => NstJobInTmp_D,
        WrEn_SI                 => NstJobWrEnSync_S,
        Full_SO                 => NstJobFull_S,
        AlmFull_SO              => open,

        -- output port
        Data_DO                 => NstJobTmp_D,
        ReEn_SI                 => NstJobReEn_SI,
        Empty_SO                => NstJobEmpty_SO,
        AlmEmpty_SO             => open
    );

    NstJob_DO <= slv2nstJob(NstJobTmp_D);

----------------------------------------------------------------------------
-- regs
----------------------------------------------------------------------------

    p_halfClk : process(HalfClk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            CtrlReg_DP          <= (others=>'0');
            LoopEnd_DP          <= (others=>(others=>'0'));
            AguBase_DP          <= (others=>(others=>'0'));
            AguStride_DP        <= (others=>(others=>'0'));
            RegRDataVld_SP      <= '0';
            RegRData_DP         <= (others=>'0');
            IsCommited_SP       <= '0';
            CmdReg_DP           <= (others=>'0');
            NstJobWrEnToggle_SP <= '0';
        elsif HalfClk_CI'event and HalfClk_CI = '1' then
            IsCommited_SP       <= IsCommited_SN ;
            CtrlReg_DP          <= CtrlReg_DN  ;
            LoopEnd_DP          <= LoopEnd_DN  ;
            AguBase_DP          <= AguBase_DN  ;
            AguStride_DP        <= AguStride_DN;
            RegRDataVld_SP      <= RegRDataVld_SN;
            RegRData_DP         <= RegRData_DN;
            CmdReg_DP           <= CmdReg_DN;
            NstJobWrEnToggle_SP <= NstJobWrEnToggle_SN;
        end if;
    end process p_halfClk;

    p_clk : process(Clk_CI, Rst_RBI)
    begin
        if Rst_RBI = '0' then
            StatusReg_DP      <= (others=>'0');
            IrqReg_DP         <= (others=>'0');
            NstJobWrEnSync_SP <= '0';
        elsif Clk_CI'event and Clk_CI = '1' then
            StatusReg_DP        <= StatusReg_DN;
            IrqReg_DP           <= IrqReg_DN   ;
            NstJobWrEnSync_SP <= NstJobWrEnSync_SN ;
        end if;
    end process p_clk;

end architecture;
