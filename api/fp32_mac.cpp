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

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <inttypes.h>

#include "fp32_mac.hpp"

///////////////////////////////////////////////////////////////////////////////
// main FP MAC model
///////////////////////////////////////////////////////////////////////////////
uint32_t  pcsMac ( const uint32_t    opA,
                   const uint32_t    opB,
                   const uint8_t     accuSel,
                   const uint8_t     subEn,
                   const uint8_t     normEn,
                   fp32_accuType   & accuState,
                   uint32_t        & res)
{
    bool     signTmp;
    int32_t  expTmp;
    uint64_t mantTmp;
    fp32_accuType tmp1;

#ifdef FP32_DEBUG_ON
    printf("----------------------------------------------\n");
    printf("pcsMac called with args:\n");
    printf("opA: %08X (interpreted: %e)\n", opA, fp32ToFloat(opA));
    printf("opB: %08X (interpreted: %e)\n", opB, fp32ToFloat(opB));
    printf("accuSel: %d\n", accuSel);
    printf("subEn: %d\n", subEn);
    printf("normEn: %d\n", normEn);
    for(int32_t k = C_FP32_N_ACCU_WORDS-1; k>=0; k--)
        printf("accuState.w[%d]: %016lX\n",k,accuState.w[k]);
    fflush(stdout);
#endif


    // multiplication
    expTmp  = fp32_getExp(opA) + fp32_getExp(opB) - C_FP32_BIAS;
    mantTmp = ((uint64_t) fp32_getMantFull(opA)) *
              ((uint64_t) fp32_getMantFull(opB));
    signTmp = fp32_getSign(opA) ^ fp32_getSign(opB);

    if(fp32_isZero(opA) || fp32_isZero(opB)) {
        mantTmp = 0ULL;
        expTmp  = 0;
    }

#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("after multiplication:\n");
    printf("signTmp: %d\n", signTmp);
    printf("expTmp: %02X\n", expTmp);
    printf("mant: %016lX\n", mantTmp);
    fflush(stdout);
#endif

    // convert this to fixed point representation
    extFp32ToPcs(signTmp ^ (bool)subEn, expTmp, mantTmp, tmp1);

#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("after conversion of mult out:\n");
    for(int32_t k = C_FP32_N_ACCU_WORDS-1; k>=0; k--)
        printf("tmp1.w[%d]: %016lX\n",k,tmp1.w[k]);
    fflush(stdout);
#endif


    // use operand C if this is set
    if(accuSel) {
        memcpy(accuState.w, tmp1.w, sizeof(uint64_t) * C_FP32_N_ACCU_WORDS);
    } else {
        // accumulation mode
        pcsAdd(tmp1, accuState, accuState);
    }


#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("after accumulator:\n");
    for(int32_t k = C_FP32_N_ACCU_WORDS-1; k>=0; k--)
        printf("accuState.w[%d]: %016llX\n",k,accuState.w[k]);
    fflush(stdout);
#endif


    // normalize the format only if needed
    if(normEn)
        pcsToFp32(accuState, res);

#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("after norm:\n");
    printf("res: %08X (interpreted: %e)\n", res, fp32ToFloat(res));
    printf("----------------------------------------------\n");
    fflush(stdout);
#endif

    return 0;
}


///////////////////////////////////////////////////////////////////////////////
// sign inversion of the accumulator
///////////////////////////////////////////////////////////////////////////////
void pcsInv (const fp32_accuType & in,
                   fp32_accuType & out)
{
    uint64_t tmp;
    uint64_t carryIn = 1ULL;

    for(int32_t k = 0; k<C_FP32_N_ACCU_WORDS; k++)
    {
        tmp = (~in.w[k]) + carryIn;

        // check if we have to carry over
        if((tmp < (~in.w[k])) || (tmp < carryIn))
        {
            carryIn = 1ULL;
        }
        else
        {
            carryIn = 0ULL;
        }

        out.w[k] = tmp;
    }

    return;
}

///////////////////////////////////////////////////////////////////////////////
// used to convert the extended multipler output to the accumulator
// representation
// note: the accumulator width is 280bit (= 1bit + 23bit + 2^8bit). i.e. sign
// plus mantissa plus range.
// we use the full multiplier output, which is 2.46 bit, but we have to cut
// away 23bits at the bottom if the exponent is below 23.
///////////////////////////////////////////////////////////////////////////////
void extFp32ToPcs (const bool     & sign,
                   const int32_t  & exponent,
                   const uint64_t & mantissa,
                   fp32_accuType  & output)
{

    memset(output.w, 0, sizeof(uint64_t) * C_FP32_N_ACCU_WORDS);

    int32_t  tmpExp  = exponent;
    uint64_t tmpMant = mantissa;

    if(tmpExp < 0) {
            return;
    } else if(tmpExp >= C_FP32_EXP_MASK_ALIGNED) {
        // models the same behavior as HW
        tmpExp = C_FP32_EXP_MASK_ALIGNED;
        tmpMant = (1ULL << (C_FP32_MANT_WIDTH*2));
    }

    int32_t shiftSize = tmpExp - C_FP32_MANT_WIDTH;

    if(shiftSize<0) {
        output.w[0] = tmpMant >> -shiftSize;
    } else {
        // determine 64bit word offset before shifting
        int32_t off = shiftSize >> 6;// /64
        shiftSize &= 0x3F;// %64

        output.w[off] = tmpMant << shiftSize;

        // upper part may spill over into the next 64bit word...
        if((shiftSize + (2 + 2*C_FP32_MANT_WIDTH)) > 64) {
            output.w[off+1] = tmpMant >> (64-shiftSize);
        }
    }

    // invert sign if needed
    if(sign)
        pcsInv(output, output);

    return;
}

///////////////////////////////////////////////////////////////////////////////
// converts the fp32 representation to the pcs format used in the accumulator
///////////////////////////////////////////////////////////////////////////////
void fp32ToPcs (const    fp32  & input,
                fp32_accuType  & output)
{
    const bool sign         = fp32_getSign(input);
    const int32_t  exponent = fp32_getExp(input);
    // need this in the same format as the multiplier output, which is 2.46 bit
    const uint64_t mantissa = fp32_isZero(input) ? 0ULL : ((uint64_t)fp32_getMantFull(input)) << C_FP32_MANT_WIDTH;

    // convert to pcs format
    extFp32ToPcs(sign,
                 exponent,
                 mantissa,
                 output);

    return;
}

///////////////////////////////////////////////////////////////////////////////
// backwards conversion to fp32 datatype
///////////////////////////////////////////////////////////////////////////////
void pcsToFp32 (const fp32_accuType & input,
                fp32                & output)
{

    int32_t  tmpExp, off, lzCnt;
    fp32_accuType tmpIn;
    output = 0;

    // check sign bit and invert if necessary
    if(input.w[C_FP32_N_ACCU_WORDS-1] >> 63) {
        output  = C_FP32_SIGN_MASK;
        pcsInv(input, tmpIn);
    } else {
        memcpy(tmpIn.w, input.w, sizeof(uint64_t) * C_FP32_N_ACCU_WORDS);
    }

#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("pcsToFp32:\n");
#endif

#ifdef FP32_DEBUG_ON
    for(int32_t k = C_FP32_N_ACCU_WORDS-1; k>=0; k--)
        printf("accuState.w[%d]: %016llX\n",k,tmpIn.w[k]);
    fflush(stdout);
#endif

    // determine exponent
    tmpExp = C_FP32_N_ACCU_WORDS * 64 - C_FP32_MANT_WIDTH -1;

#ifdef FP32_DEBUG_ON
    printf("tmpExp[init] = %d\n",tmpExp);
#endif

    lzCnt  = 0;
    for(int32_t k = C_FP32_N_ACCU_WORDS-1; k>= 0; k--) {
        off = k;

        if(tmpIn.w[k]) {

            lzCnt = __builtin_clzll(tmpIn.w[k]);
            // lzCnt = __builtin_clzl(tmpIn.w[k]);

            tmpExp -= lzCnt;

#ifdef FP32_DEBUG_ON
            printf("lzCnt[k=%d]  = %d\n",k,lzCnt);
            printf("tmpExp[k=%d] = %d\n",k,tmpExp);
#endif

            break;
        } else {
            tmpExp -= 64;
        }
    }

#ifdef FP32_DEBUG_ON
    printf("tmpExp[end] = %d\n",tmpExp);
#endif

    // extract mantissa
    if(tmpExp < 0) {
        output |= C_FP32_ZERO_VAL;
    } else if(tmpExp >= C_FP32_EXP_MASK_ALIGNED) {
        output |= C_FP32_INF_VAL;
    } else {
        // pack exponent
        output |= tmpExp<<C_FP32_MANT_WIDTH;

        // in this case this accumulator word completely contains the mantissa
        lzCnt = 64-1-C_FP32_MANT_WIDTH-lzCnt;
        if (lzCnt >= 0) {
            // cut the MSB away and pack
            output |= (tmpIn.w[off] >> lzCnt) & C_FP32_MANT_MASK;
        } else { // in this case we have to assemble the mantissa...
            // cut the MSB away and pack
            output |= (tmpIn.w[off] << -lzCnt) & C_FP32_MANT_MASK;
            output |= (tmpIn.w[off-1] >> (64 + lzCnt));
        }
    }
    return;
}


///////////////////////////////////////////////////////////////////////////////
// addition routine on accumulator datatypes
///////////////////////////////////////////////////////////////////////////////
void pcsAdd (const fp32_accuType & opA,
             const fp32_accuType & opB,
                   fp32_accuType & out)
{
    uint64_t tmp;
    int64_t tmp2;
    uint64_t carryIn = 0ULL, carryOut;

    for(int32_t k = 0; k<C_FP32_N_ACCU_WORDS; k++) {

        tmp = opA.w[k] + opB.w[k];

        // check if we have to carry over
        if((tmp < opA.w[k]) || (tmp < opB.w[k])) {
            carryOut = 1ULL;
        } else if ((carryIn == 1ULL) && (tmp == 0xFFFFFFFFFFFFFFFFULL)){
            carryOut = 1ULL;
        } else {
            carryOut = 0ULL;
        }

        tmp += carryIn;

#ifdef FP32_DEBUG_ON
    printf("--\n");
    printf("pcsAdd:\n");
    printf("out[%d]: %016lX = opA.w + opB.w + carryIn = %016lX  + %016lX + %lu, carryOut: %lu\n", k, tmp, opA.w[k], opB.w[k], carryIn, carryOut);
    fflush(stdout);
#endif

        carryIn  = carryOut;
        out.w[k] = tmp;
    }

    // we need to accurately model overflows in the HW that were
    // not detected due to insufficient amount of guard bits
    // so mask away all bits above the overflow guard bits
    tmp = 64 - (C_FP32_PCS_WIDTH & 0x3F);
    tmp2 = out.w[C_FP32_N_ACCU_WORDS-1] << tmp;
    // and sign extend this again (note: use signed number to implement arithmetic shift)
    out.w[C_FP32_N_ACCU_WORDS-1] = tmp2 >> tmp;

    return;
}

