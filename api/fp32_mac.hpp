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

#include <algorithm>
#include <cstdint>
#include <cstddef>

// enables some debug output
// #define FP32_DEBUG_ON
// #define WIN64

///////////////////////////////////////////////////////////////////////////////
// some constants that are required internally. they must be aligned with
// the SV and VHDL constants. do not change them unless you know what you
// are doing - these are not adjustable parameters.
///////////////////////////////////////////////////////////////////////////////

#define C_FP32_N_ACCU_OFLOW_BITS     4
#define C_FP32_N_ACCU_WORDS          5
#define C_FP32_ZERO_VAL              0x00000000
#define C_FP32_ONE_VAL               0x3F800000
#define C_FP32_INF_VAL               0x7F800000
#define C_FP32_EXP_WIDTH             8
#define C_FP32_MANT_WIDTH            23
#define C_FP32_EXP_MASK              0x7F800000
#define C_FP32_EXP_MASK_ALIGNED      0x000000FF
#define C_FP32_MANT_MASK             0x007FFFFF
#define C_FP32_MANT_MASK_EXT         0x00FFFFFF
#define C_FP32_SIGN_MASK             0x80000000
#define C_FP32_BIAS                  127
#define C_FP32_PCS_WIDTH             (1 + (1<<C_FP32_EXP_WIDTH) + C_FP32_MANT_WIDTH + C_FP32_N_ACCU_OFLOW_BITS)

///////////////////////////////////////////////////////////////////////////////
// internal helper datatypes
///////////////////////////////////////////////////////////////////////////////

template <typename T, size_t D1> class arr1D
{
    public:
    T w[D1];
    arr1D() : w{0} {}

    template <typename... TT>
    arr1D(TT... ts) : w{(T)ts...} {
    }

    T& operator [](size_t idx) {
        return w[idx];
    }
    const T& operator [](size_t idx) const {
        return w[idx];
    }

    void clear() {
        std::fill(w, w+D1, (T)0);
    }

    void set(const arr1D & other) {
        std::copy(other.w, other.w+D1, w);
    }
};

template <typename T, size_t D1, size_t D2> class arr2D
{
    public:
    T w[D2][D1];
    arr2D() : w{0} {}

    template <typename... TT>
    arr2D(TT... ts) : w{(T)ts...} {
    }

    T* operator [](size_t idx) {
        return w[idx];
    }
    const T* operator [](size_t idx) const {
        return w[idx];
    }

    void clear() {
        std::fill((T*)w, (T*)w+D1*D2, (T)0);
    }

    void set(const arr2D & other) {
        std::copy(other.w, other.w+D1*D2, w);
    }
};

// we need to emulate the 284bit (= 1bit + 23bit + 2^8bit + 4bit, i.e. sign plus
// mantissa plus range + overflow bits) accumulator with 5 uint 64 words.
// this is also called "pcs" format in the following , which stems from the
// fact that this
// accumulator is implemented using partial carry save arithmetic in HW.
// note however, that we do not use carry save arithmetic in this emulation -
// we just have to split the overlong 280bit word into several subwords...
typedef arr1D<uint64_t, C_FP32_N_ACCU_WORDS> fp32_accuType;
typedef uint32_t fp32;

///////////////////////////////////////////////////////////////////////////////
// main FP MAC model
///////////////////////////////////////////////////////////////////////////////

extern "C" uint32_t pcsMac (const uint32_t    opA,
                            const uint32_t    opB,
                            const uint8_t     accuSel,
                            const uint8_t     subEn,
                            const uint8_t     normEn,
                            fp32_accuType   & accuState,
                                  uint32_t  & res);


///////////////////////////////////////////////////////////////////////////////
// some helper functions
///////////////////////////////////////////////////////////////////////////////

bool inline fp32_isZero(const fp32 & input)
{
    return ((~C_FP32_SIGN_MASK) & input) == C_FP32_ZERO_VAL;
}

// only checks for maximum exponent. note: we do not support NANs...
bool inline fp32_isInf(const fp32 & input)
{
    return (input & C_FP32_EXP_MASK) == C_FP32_EXP_MASK;
}

uint32_t inline fp32_getMant(const fp32 & input)
{
    return C_FP32_MANT_MASK & input;
}

uint32_t inline fp32_getMantFull(const fp32 & input)
{
    return fp32_getMant(input) | (1 << C_FP32_MANT_WIDTH);
}

bool inline fp32_getSign(const fp32 & input)
{
    return (input & C_FP32_SIGN_MASK) > 0;
}

int32_t inline fp32_getExp(const fp32 & input)
{
    return (int)(C_FP32_EXP_MASK_ALIGNED & (input >> C_FP32_MANT_WIDTH));
}

int32_t inline fp32_getExpUnbiased(const fp32 & input)
{
    return fp32_getExp(input) - C_FP32_BIAS;
}

float inline fp32ToFloat(fp32 in)
{
    union {fp32 i; float f;} tmp;
    tmp.i = in;
    return tmp.f;
}

fp32 inline floatTofp32(float in)
{
    union {fp32 i; float f;} tmp;
    tmp.f = in;
    return tmp.i;
}


///////////////////////////////////////////////////////////////////////////////
// sign inversion of the accumulator
///////////////////////////////////////////////////////////////////////////////
void pcsInv (const fp32_accuType & in,
                   fp32_accuType & out);

///////////////////////////////////////////////////////////////////////////////
// used to convert the extended multipler output to the accumulator
// representation
// note: the accumulator width is 284bit (= 1bit + 23bit + 2^8bit + 4bit).
// i.e. sign plus mantissa plus range plus overflow bits.
// we use the full multiplier output, which is 2.46 bit, but we have to cut
// away 23bits at the bottom if the exponent is below 23.
///////////////////////////////////////////////////////////////////////////////
void extFp32ToPcs (const bool     & sign,
                   const int32_t  & exponent,
                   const uint64_t & mantissa,
                   fp32_accuType  & output);

///////////////////////////////////////////////////////////////////////////////
// converts the fp32 representation to the pcs format used in the accumulator
///////////////////////////////////////////////////////////////////////////////
void fp32ToPcs (const    fp32  & input,
                fp32_accuType  & output);

///////////////////////////////////////////////////////////////////////////////
// backwards conversion to fp32 datatype
///////////////////////////////////////////////////////////////////////////////
void pcsToFp32 (const fp32_accuType & input,
                fp32                & output);

///////////////////////////////////////////////////////////////////////////////
// addition routine on accumulator datatypes
///////////////////////////////////////////////////////////////////////////////
void pcsAdd (const fp32_accuType & opA,
             const fp32_accuType & opB,
                   fp32_accuType & out);
