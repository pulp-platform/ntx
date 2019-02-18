// Copyright 2017-2019 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Michael Schaffner (schaffner@iis.ee.ethz.ch)
// Fabian Schuiki (fschuiki@iis.ee.ethz.ch)

#pragma once

// enable emulation
// #define NST_EMULATION_ON

#include <stdint.h>
#include <inttypes.h>
#include "fp32_mac.hpp"
#include <initializer_list>
#include <cassert>

// enables some debug output
#ifndef NST_DEBUG_LEVEL
#define NST_DEBUG_LEVEL          0
#endif

///////////////////////////////////////////////////////////////////////////////
// some constants that are required internally. they must be aligned with
// the SV and VHDL constants. do not change them unless you know what you
// are doing - these are not adjustable parameters.
///////////////////////////////////////////////////////////////////////////////

#define C_NST_BASE_ADDR          0x10204800
#define C_NST_OFFSET             (32<<2)
#define C_NST_BROADCAST_ADDR     0x10204C00

#define C_N_HW_LOOPS             5
#define C_HW_LOOP_WIDTH          16
#define C_N_AGUS                 3
#define C_AGU_ADDR_WIDTH         18
#define C_ADDR_WIDTH             32
#define C_DATA_WIDTH             32
#define C_BYTE_ENABLE_WIDTH      4
#define C_NST_FPU_ALU_CNT_WIDTH  16

// nst register map, use nstReadReg
// note: these are word addresses (gets implicitly
// shifted <<2 due to pointer access onto uint32_t*)
#define C_REG_ADDR_WIDTH         7
#define C_NST_STAT_REG           0x00
#define C_NST_CTRL_REG           0x01
#define C_NST_CMD_REG            0x02
#define C_NST_IRQ_REG            0x03
#define C_NST_LOOP_REGS          0x04
#define C_NST_AGU0_REGS          0x09
#define C_NST_AGU1_REGS          0x0F
#define C_NST_AGU2_REGS          0x15

#define C_NST_OPCODE_WIDTH       4
#define C_NST_LOOP_LEVEL_WIDTH   3
#define C_N_NST_OPCODES          9
#define C_NST_MAC_OP             0
#define C_NST_VADDSUB_OP         1
#define C_NST_VMULT_OP           2
#define C_NST_OUTERP_OP          3
#define C_NST_MAXMIN_OP          4
#define C_NST_THTST_OP           5
#define C_NST_MASK_OP            6
#define C_NST_MASKMAC_OP         7
#define C_NST_COPY_OP            8

#define C_NST_SET_NO_IRQ         0
#define C_NST_SET_CMD_IRQ        1
#define C_NST_SET_WB_IRQ         2

#define C_NST_POS_POLARITY       0
#define C_NST_NEG_POLARITY       1

#define C_NST_INIT_WITH_AGU0     0
#define C_NST_INIT_WITH_AGU1     1
#define C_NST_INIT_WITH_AGU2     2
#define C_NST_INIT_WITH_ZERO     3

#define C_NST_CTRL_PRIO_HI       (0<<1)
#define C_NST_CTRL_PRIO_RR       (1<<1)
#define C_NST_CTRL_PRIO_71       (2<<1)

// aux field values
// for C_NST_MAC_OP, C_NST_VADDSUB_OP, C_NST_VMULT_OP, C_NST_OUTERP_OP
#define C_NST_MAC_AUX_STD        0
#define C_NST_MAC_AUX_RELU       1

// for C_NST_MAXMIN_OP
#define C_NST_MAXMIN_AUX_STD     0
#define C_NST_MAXMIN_AUX_ARG     1

// for C_NST_THTST_OP
#define C_NST_THTST_AUX_CMP_EQ   0
#define C_NST_THTST_AUX_CMP_LT   1
#define C_NST_THTST_AUX_CMP_LE   2
#define C_NST_THTST_AUX_BIN_OUT  4 // can be or'ed with other CMP modes above

// for MASK, MASKMAC
#define C_NST_MASK_AUX_CMP_EQ    0
#define C_NST_MASK_AUX_CMP_LT    1
#define C_NST_MASK_AUX_CMP_LE    2 // can be or'ed with other CMP modes above
#define C_NST_MASK_AUX_CMP_CNT   4

// for copy OP
#define C_NST_COPY_AUX_REPL      0 // uses init load to load a constant or zero to deposit
#define C_NST_COPY_AUX_VECT      1 // copy a vector without using the init cycle

///////////////////////////////////////////////////////////////////////////////
// internal helper datatypes (uses arr1D and arr2D from fp32_mac.h)
///////////////////////////////////////////////////////////////////////////////

typedef void* aguPtrType;
typedef arr1D<aguPtrType, C_N_AGUS>            nst_aguType;
typedef arr1D<uint32_t, C_N_HW_LOOPS>          nst_loopType;
typedef arr2D<int32_t, C_N_HW_LOOPS, C_N_AGUS> nst_strideType;

///////////////////////////////////////////////////////////////////////////////
// NST job type
///////////////////////////////////////////////////////////////////////////////


class nstV2Api {
public:

    // NST address (ignored in emulation, but needed in real app)
    volatile aguPtrType nstAddr = nullptr;

    uint32_t prepNstCmd = 0;
    uint32_t loopLevels = 0;

#ifdef NST_EMULATION_ON
    // for sanity checks only
    aguPtrType tcdmLow  = nullptr;
    aguPtrType tcdmHigh = nullptr;
    bool checkTcdmAddrs = false;

    uint8_t initLevel = 0;
    uint8_t innerLevel = 0;
    uint8_t outerLevel = 0;
    uint8_t opCode = 0;
    uint8_t initSel = 0;
    uint8_t auxFunc = 0;
    uint8_t irqCfg = 0;
    bool    polarity = 0;

    // interrupts
    bool irqReg = false;

    // staging area
    nst_loopType   loopBound;
    nst_aguType    aguOff;
    nst_strideType aguStride;

    // nst state
    nst_aguType    agu;
    fp32_accuType  accuState;
    uint32_t       aluState = 0;
    uint32_t       cntState = 0;
    uint32_t       idxState = 0;
#endif

    // broadcast
    // bool broadcast = false;
    // std::vector<nstV2Api*> otherNsts;
    nstV2Api *broadcast = nullptr;
    nstV2Api *broadcastEnd = nullptr;



    /// Construct an empty NST.
    nstV2Api() {
    }

    /// Construct an NST.
    nstV2Api(uint32_t nstAddr_):
        nstAddr((void*)(size_t)nstAddr_) {
    }

    /// Construct a broadcast alias for other NSTs.
    nstV2Api(uint32_t nstAddr_, nstV2Api *broadcast, nstV2Api *broadcastEnd):
        nstV2Api(nstAddr_) {
        // #ifdef NST_EMULATION_ON
        this->broadcast = broadcast;
        this->broadcastEnd = broadcastEnd;
        // #endif
    }

    inline void
    setNstAddr(uint32_t nstAddr_) {
        nstAddr = (void*)(size_t)nstAddr_;
    }

// functions for NST/CORE interaction on PULP
#ifndef NST_EMULATION_ON

    // read NST regs
    inline uint32_t
    readReg(const uint32_t regOffset) {
        return * ((volatile uint32_t*)nstAddr+regOffset);
    }

    // write NST regs
    inline void
    writeReg(const uint32_t regOffset, const uint32_t value) {
        *((volatile uint32_t*)nstAddr+regOffset) = value;
    }

    // checks whether the NST is idle, and has empty pipeline, and whether no error occurred
    inline bool
    isIdle() {
        return (this->readReg(C_NST_STAT_REG) & 0x1F) == 0x7;
    }

    // checks whether the NST can accept another command
    inline bool
    isReady() {
        return ! (bool)(this->readReg(C_NST_STAT_REG) & 0x10);
    }

    // checks whether the NST has halted due to an invalid command
    // you have to issue a soft reset to unblock it again
    inline void
    softRst() {
        this->writeReg(C_NST_CTRL_REG, 0x01);
    }

    // set the TCDM priority of the NST
    inline void
    setTcdmPrio(uint32_t val) {
        this->writeReg(C_NST_CTRL_REG, val & 0x6);
    }

    // get the TCDM priority of the NST
    inline uint32_t
    getTcdmPrio() {
        return (this->readReg(C_NST_CTRL_REG)) & 0x02;
    }

    // check if there is a pending interrupt
    inline bool
    hasIrq() {
        return this->readReg(C_NST_IRQ_REG);
    }

    // clears all pending IRQs
    inline void
    clrIrq() {
        this->writeReg(C_NST_IRQ_REG, 0xFFFFFFFF);
    }

#else

    // read NST regs
    inline uint32_t
    readReg(const uint32_t regOffset) {
        assert(!broadcast);
        return 0;
    }

    // write NST regs
    inline void
    writeReg(const uint32_t regOffset, const uint32_t value) {
    }

    // checks whether the NST is idle, and has empty pipeline, and whether no error occurred
    inline bool
    isIdle() {
        assert(!broadcast);
        return true;
    }

    // checks whether the NST can accept another command
    inline bool
    isReady() {
        assert(!broadcast);
        return true;
    }

    // checks whether the NST has halted due to an invalid command
    // you have to issue a soft reset to unblock it again
    inline void
    softRst() {
    }

    // set the TCDM priority of the NST
    inline void
    setTcdmPrio(uint32_t val) {
    }

    // get the TCDM priority of the NST
    inline uint32_t
    getTcdmPrio() {
        assert(!broadcast);
        return 0;
    }

    // check if there is a pending interrupt
    inline bool
    hasIrq() {
        assert(!broadcast);
        return irqReg;
    }

    // clears all pending IRQs
    inline void
    clrIrq() {
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->clrIrq();
            return;
        }
        irqReg = false;
    }

#endif


    inline void
    idleWait() {
        while(!isIdle());
    }

    inline void
    readyWait() {
        while(!isReady());
    }

    // translate standard absolute loop bounds (in terms of elements)
    // into incremental formulation suitable for the AGUs
    // note: strides are index strides and not byte address strides
    inline void
    stageLoopNest(
        const uint32_t       & initLevel_,
        const uint32_t       & innerLevel_,
        const uint32_t       & outerLevel_,
        const nst_loopType   & loopBound_,
        const nst_strideType & aguStride_
    ) {
        #ifdef NST_EMULATION_ON
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->stageLoopNest(
                    initLevel_,
                    innerLevel_,
                    outerLevel_,
                    loopBound_,
                    aguStride_
                );
            return;
        }

        // some sanity checks...
        assert(initLevel_  >= innerLevel_);
        assert(outerLevel_ >= innerLevel_);
        assert(outerLevel_ >= initLevel_);
        assert(C_N_HW_LOOPS   >= outerLevel_);

        initLevel    = initLevel_ ;
        innerLevel   = innerLevel_;
        outerLevel   = outerLevel_ ;
        #endif

        // prepare for command word
        loopLevels  = (outerLevel_  & 0x7) << (2*C_NST_LOOP_LEVEL_WIDTH + C_NST_OPCODE_WIDTH);
        loopLevels |= (innerLevel_  & 0x7) << (C_NST_LOOP_LEVEL_WIDTH   + C_NST_OPCODE_WIDTH);
        loopLevels |= (initLevel_   & 0x7) <<  C_NST_OPCODE_WIDTH;

        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->loopLevels = loopLevels;
        }

        for(uint32_t k=0; k< outerLevel_; k++) {
#ifdef NST_EMULATION_ON
            assert(loopBound_[k] < (1ULL << C_HW_LOOP_WIDTH));
            assert(loopBound_[k] > 0);
            loopBound[k] = loopBound_[k]-1;
#else
            this->writeReg(C_NST_LOOP_REGS+k, loopBound_[k]-1);
#endif
        }

        int32_t tmp1, tmp2 = 0;
        for(uint32_t s=0; s<outerLevel_; s++) {
            // convert to word adresses...
            tmp1  = (aguStride_[0][s] - tmp2) << 2;
            tmp2 += (loopBound_[s] - 1) * aguStride_[0][s];
#ifdef NST_EMULATION_ON
            aguStride[0][s] = tmp1;
#else
            this->writeReg(C_NST_AGU0_REGS+1+s, tmp1);
#endif
        }

        tmp2 = 0;
        for(uint32_t s=0; s<outerLevel_; s++) {
            // convert to word adresses...
            tmp1  = (aguStride_[1][s] - tmp2) << 2;
            tmp2 += (loopBound_[s] - 1) * aguStride_[1][s];
#ifdef NST_EMULATION_ON
            aguStride[1][s] = tmp1;
#else
            this->writeReg(C_NST_AGU1_REGS+1+s, tmp1);
#endif
        }

        tmp2 = 0;
        for(uint32_t s=0; s<outerLevel_; s++) {
            // convert to word adresses...
            tmp1  = (aguStride_[2][s] - tmp2) << 2;
            tmp2 += (loopBound_[s] - 1) * aguStride_[2][s];
#ifdef NST_EMULATION_ON
            aguStride[2][s] = tmp1;
#else
            this->writeReg(C_NST_AGU2_REGS+1+s, tmp1);
#endif
        }

    }

    /// configure the AGU offsets (byte addresses!)
    inline void
    stageAguOffs(
        volatile void * aguOff0_,
        volatile void * aguOff1_,
        volatile void * aguOff2_
    ) {
        #ifdef NST_EMULATION_ON
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->stageAguOffs(
                    aguOff0_,
                    aguOff1_,
                    aguOff2_
                );
            return;
        }

        aguOff[0] = (void*)aguOff0_;
        aguOff[1] = (void*)aguOff1_;
        aguOff[2] = (void*)aguOff2_;
        #else
        this->writeReg(C_NST_AGU0_REGS , (uint32_t)(size_t)aguOff0_);
        this->writeReg(C_NST_AGU1_REGS , (uint32_t)(size_t)aguOff1_);
        this->writeReg(C_NST_AGU2_REGS , (uint32_t)(size_t)aguOff2_);
        #endif
    }

    template <uint32_t idx> inline void
    stageAguOff(volatile void * aguOff_) {
        #ifdef NST_EMULATION_ON
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->stageAguOff<idx>(aguOff_);
            return;
        }

        aguOff[idx] = (void*)aguOff_;
        #else
        static const uint32_t addrs[] = {
            C_NST_AGU0_REGS, C_NST_AGU1_REGS, C_NST_AGU2_REGS
        };
        this->writeReg(addrs[idx] , (uint32_t)aguOff_);
        #endif
    }



    /// prepares the command word locally
    /// use issueCmd to write it to the NST and trigger its execution
    inline void
    stageCmd(
        const uint8_t opCode_,
        const uint8_t initSel_,
        const uint8_t auxFunc_,
        const uint8_t irqCfg_,
        const bool    polarity_
    ) {
        #ifdef NST_EMULATION_ON
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->stageCmd(
                    opCode_,
                    initSel_,
                    auxFunc_,
                    irqCfg_,
                    polarity_
                );
            return;
        }

        opCode      = opCode_  ;
        initSel     = initSel_ ;
        auxFunc     = auxFunc_ ;
        irqCfg      = irqCfg_  ;
        polarity    = polarity_;
        #endif

        prepNstCmd  = polarity_;
        prepNstCmd <<= 2;
        prepNstCmd |= irqCfg_  & 0x3;
        prepNstCmd <<= 3;
        prepNstCmd |= auxFunc_ & 0x7;
        prepNstCmd <<= 2;
        prepNstCmd |= initSel_ & 0x3;
        prepNstCmd <<= (3*C_NST_LOOP_LEVEL_WIDTH + C_NST_OPCODE_WIDTH);
        prepNstCmd |= opCode_ | loopLevels;

        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->prepNstCmd = prepNstCmd;
        }
    }


    inline void
    issueCmd() {
        #ifdef NST_EMULATION_ON
        if (broadcast) {
            for (auto nst = broadcast; nst != broadcastEnd; ++nst)
                nst->issueCmd();
            return;
        }
        nstFuncModel();
        irqReg = irqCfg > 0;
        #else
        this->writeReg(C_NST_CMD_REG, prepNstCmd);
        #endif
    }

    // helper functions for emulation
    #ifdef NST_EMULATION_ON

    void
    setTcdmBaseCheck(
        aguPtrType tcdmLow_,
        aguPtrType tcdmHigh_
    ) {
        tcdmLow        = tcdmLow_;
        tcdmHigh       = tcdmHigh_;
        checkTcdmAddrs = true;
    }

    // write a job dump to a txt file
    void
    writeJobDump(
        const char *     fileName,
        const char *     testName,
        const aguPtrType tcdm
    );

    // functional model of the NST
    void nstFuncModel();

    #endif
};
