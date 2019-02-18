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
#include <cassert>
#include <functional>

#define NTX_EMULATION_ON

#include "ntx_api.hpp"
#include "fp32_mac.hpp"


#ifdef NTX_EMULATION_ON

///////////////////////////////////////////////////////////////////////////////
// definition of internal emulation functions
///////////////////////////////////////////////////////////////////////////////


class nstInternalOp {
    public:
    ntx_api * ntx;

    nstInternalOp(ntx_api * nst_){
        ntx = nst_;
    }

    virtual void init() = 0;
    virtual void execute() = 0;
    virtual void store() = 0;

};

struct nstMacOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstVAddSubOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstVMultOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstOuterPOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstMaxMinOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstThTstOp : nstInternalOp{
    bool tst;
    uint32_t *opB;
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstMaskOp : nstInternalOp{
    bool tst;
    uint32_t *opA;
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstMaskMacOp : nstInternalOp{
    bool tst;
    uint32_t *opA;
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

struct nstCopyOp : nstInternalOp{
    using nstInternalOp::nstInternalOp;
    virtual void init();
    virtual void execute();
    virtual void store();
};

///////////////////////////////////////////////////////////////////////////////
// ntx emulation functions
///////////////////////////////////////////////////////////////////////////////

void
ntx_api::writeJobDump(const char *      fileName,
                       const char *      testName,
                       const aguPtrType  tcdmBase) {

    FILE * fid = fopen(fileName,"w");
    if(fid == NULL) {
         throw("error opening file");
    }

    fprintf(fid,"%s\n", testName);

    fprintf(fid,"%08X\n", prepNstCmd );

    // fprintf(fid,"%u\n", opCode     );
    // fprintf(fid,"%u\n", initLevel  );
    // fprintf(fid,"%u\n", innerLevel );
    // fprintf(fid,"%u\n", outerLevel );
    // fprintf(fid,"%u\n", initSel );
    // fprintf(fid,"%u\n", (uint32_t)auxFunc);
    // fprintf(fid,"%u\n", (uint32_t)irqCfg);
    // fprintf(fid,"%u\n", (uint32_t)polarity);

    for(uint32_t k=0; k<C_N_HW_LOOPS; k++)
        fprintf(fid,"%u ", loopBound[k]);

    fprintf(fid,"\n");

    for(uint32_t k=0; k<C_N_AGUS; k++)
        fprintf(fid,"%u ", (uint32_t)((size_t) aguOff[k] - (size_t)tcdmBase));

    fprintf(fid,"\n");

    for(uint32_t k=0; k<C_N_AGUS; k++){
        for(uint32_t s=0; s<C_N_HW_LOOPS; s++)
            fprintf(fid,"%d ",aguStride[k][s]);
        fprintf(fid,"\n");
    }

    fclose(fid);
    return;
}


void
ntx_api::nstFuncModel ()
{

    // some sanity checks...
    assert(initLevel  >= innerLevel);
    assert(outerLevel >= innerLevel);
    assert(outerLevel >= initLevel);
    assert(C_N_HW_LOOPS   >= outerLevel);
    assert(C_N_NTX_OPCODES > opCode);
    for(uint32_t k=0; k< C_N_HW_LOOPS; k++)
        assert(loopBound[k] < (1ULL << C_HW_LOOP_WIDTH));

    // AGU init
    memcpy(&agu, &aguOff, sizeof(nst_aguType));

    //select corresponding fpu Operation
    nstInternalOp * op;
    switch (opCode) {
        case C_NTX_MAC_OP:
            op = new nstMacOp(this);
            break;
        case C_NTX_VADDSUB_OP:
            op = new nstVAddSubOp(this);
            break;
        case C_NTX_VMULT_OP:
            op = new nstVMultOp(this);
            break;
        case C_NTX_OUTERP_OP:
            op = new nstOuterPOp(this);
            break;
        case C_NTX_MAXMIN_OP:
            op = new nstMaxMinOp(this);
            break;
        case C_NTX_THTST_OP:
            op = new nstThTstOp(this);
            break;
        case C_NTX_MASK_OP:
            op = new nstMaskOp(this);
            break;
        case C_NTX_MASKMAC_OP:
            op = new nstMaskMacOp(this);
            break;
        case C_NTX_COPY_OP:
            op = new nstCopyOp(this);
            break;
        default:
            assert(0);
    }

    // define resursive function for NTX loops...
    std::function<void(uint32_t, nstInternalOp&, bool)> nstLooper;
    nstLooper = [this, &nstLooper](uint32_t level, nstInternalOp & op, bool isLast) {

    // do some sanity checks onn AGUs in order to detect malicious configurations
    if(checkTcdmAddrs) {
        assert(agu[0] >= tcdmLow && agu[0] <= tcdmHigh);
        assert(agu[1] >= tcdmLow && agu[1] <= tcdmHigh);
        assert(agu[2] >= tcdmLow && agu[2] <= tcdmHigh);
    }

#if NTX_DEBUG_LEVEL > 0
    for(uint32_t k=level; k<outerLevel;k++)
        printf("---");

    printf("level %d\n", level);
#endif

    // check whether init is required
    if (initLevel == level)
        op.init();

    // execution of the command only happens in the body of the innermost loop...
    if (level == 0) {
        op.execute();
    } else {
        // otherwise, do another loop. note the inclusive bounds!!
        for(uint32_t k=0; k <= loopBound.w[level-1]; k++)
            nstLooper(level-1, op, (k == loopBound.w[level-1]));
    }

    // check whether writeback is required
    if (innerLevel == level)
        op.store();

    // AGU update
    if((level<C_N_HW_LOOPS) && !isLast) {
 #if NTX_DEBUG_LEVEL > 0
            printf("level %d AGU update (isLast = %d)\n", level, (int)isLast);
 #endif
        for(uint32_t o=0; o < C_N_AGUS; o++) {
            agu[o] = ((char*)agu[o] + aguStride[o][level]);
        }
    }

    };

    // call the loop
    nstLooper(outerLevel, *op, true);

  return;
}


///////////////////////////////////////////////////////////////////////////////
// NTX_MAC
///////////////////////////////////////////////////////////////////////////////

void
nstMacOp::init() {

    if(ntx->initSel >= 3) {
        ntx->accuState.clear();
#if NTX_DEBUG_LEVEL > 1
        printf("NTX_MAC: init accu with zero\n");
#endif
    }
    else {
        uint32_t * res = (uint32_t *)ntx->agu[ntx->initSel];
        pcsMac ((*res),
                C_FP32_ONE_VAL,
                1,
                0,
                0,
                ntx->accuState,
                (*res));
#if NTX_DEBUG_LEVEL > 1
        printf("init accu with res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
#endif
    }

#if NTX_DEBUG_LEVEL > 1
            printf("op: NTX_MAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstMacOp::execute() {

    uint32_t res;
    uint32_t * opA = (uint32_t *)ntx->agu[0];
    uint32_t * opB = (uint32_t *)ntx->agu[1];

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opA = %f (0x%08X), opB = %f (0x%08X)\n",fp32ToFloat(*opA), *opA, fp32ToFloat(*opB), *opB);
    printf("op: NTX_MAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    // call the bittrue model
    pcsMac ((*opA),
            (*opB),
            0,
            ntx->polarity,
            0,
            ntx->accuState,
            res);

}

void
nstMacOp::store() {

    uint32_t * res = (uint32_t *)ntx->agu[2];

    // call the bittrue model
    pcsMac (C_FP32_ZERO_VAL,
            C_FP32_ZERO_VAL,
            0,
            0,
            1,
            ntx->accuState,
            (*res));

    // apply ReLu if required
    if(ntx->auxFunc && fp32_getSign((*res))) {
        (*res) = C_FP32_ZERO_VAL;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_MAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

///////////////////////////////////////////////////////////////////////////////
// vector addition, subtraction and multiply
///////////////////////////////////////////////////////////////////////////////

void
nstVAddSubOp::init() {
    if(ntx->initSel >= 3) {
        ntx->accuState.clear();
#if NTX_DEBUG_LEVEL > 1
        printf("NTX_ADDSUB: init accu with zero\n");
#endif
    }
    else {
        uint32_t * res = (uint32_t *)ntx->agu[ntx->initSel];
        pcsMac ((*res),
                C_FP32_ONE_VAL,
                1,
                ntx->polarity,
                0,
                ntx->accuState,
                (*res));
#if NTX_DEBUG_LEVEL > 1
        printf("init accu with res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
#endif
    }

#if NTX_DEBUG_LEVEL > 1
            printf("op: NTX_ADDSUB (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstVAddSubOp::execute() {
    uint32_t res;
    uint32_t * opA = (uint32_t *)ntx->agu[0];

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opA = %f\n",fp32ToFloat(*opA));
    printf("op: NTX_VADDSUB (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    // call the bittrue model
    pcsMac ((*opA),
            C_FP32_ONE_VAL,
            0,
            0,
            0,
            ntx->accuState,
            res);
}

void
nstVAddSubOp::store() {

    uint32_t * res = (uint32_t *)ntx->agu[2];

    // call the bittrue model
    pcsMac (C_FP32_ZERO_VAL,
            C_FP32_ZERO_VAL,
            0,
            0,
            1,
            ntx->accuState,
            (*res));

    // apply ReLu if required
    if(ntx->auxFunc && fp32_getSign((*res))) {
        (*res) = C_FP32_ZERO_VAL;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_VADDSUB (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}


void
nstVMultOp::init() {
#if NTX_DEBUG_LEVEL > 1
    printf("no init\n");
    printf("op: NTX_VMULT (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif
}

void
nstVMultOp::execute() {

    uint32_t res;
    uint32_t * opA = (uint32_t *)ntx->agu[0];
    uint32_t * opB = (uint32_t *)ntx->agu[1];

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opA = %f, opB = %f\n",fp32ToFloat(*opA),fp32ToFloat(*opB));
    printf("op: NTX_VMULT (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    // call the bittrue model
    pcsMac ((*opA),
            (*opB),
            1,
            ntx->polarity,
            0,
            ntx->accuState,
            res);
}

void
nstVMultOp::store() {

    uint32_t * res = (uint32_t *)ntx->agu[2];

    // call the bittrue model
    pcsMac (C_FP32_ZERO_VAL,
            C_FP32_ZERO_VAL,
            0,
            0,
            1,
            ntx->accuState,
            (*res));

    // apply ReLu if required
    if(ntx->auxFunc && fp32_getSign((*res))) {
        (*res) = C_FP32_ZERO_VAL;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_VMULT (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}


///////////////////////////////////////////////////////////////////////////////
// outer products
///////////////////////////////////////////////////////////////////////////////

void
nstOuterPOp::init() {
    if(ntx->initSel >= 3) {
        ntx->aluState = C_FP32_ZERO_VAL;
    }
    else {
        ntx->aluState = *(uint32_t *)ntx->agu[ntx->initSel];
    }

    // clear accu
    ntx->accuState.clear();

#if NTX_DEBUG_LEVEL > 1
    printf("init accu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("op: NTX_OUTERP (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstOuterPOp::execute() {

    uint32_t * opA = (uint32_t *)ntx->agu[0];
    uint32_t res;

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opA = %f (0x%08X)\n",fp32ToFloat(*opA), *opA);
    printf("op: NTX_OUTERP (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    // call the bittrue model
    pcsMac ((*opA),
            ntx->aluState,
            1,
            ntx->polarity,
            0,
            ntx->accuState,
            res);
}

void
nstOuterPOp::store() {

    uint32_t * res = (uint32_t *)ntx->agu[2];

    // call the bittrue model
    pcsMac (C_FP32_ZERO_VAL,
            C_FP32_ZERO_VAL,
            0,
            0,
            1,
            ntx->accuState,
            (*res));

    // apply ReLu if required
    if(ntx->auxFunc && fp32_getSign((*res))) {
        (*res) = C_FP32_ZERO_VAL;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_OUTERP (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

///////////////////////////////////////////////////////////////////////////////
// (A)MAX and (A)MIN
///////////////////////////////////////////////////////////////////////////////

void
nstMaxMinOp::init() {
    if(ntx->initSel >= 3) {
        ntx->aluState = C_FP32_ZERO_VAL;
    }
    else {
        ntx->aluState = *(uint32_t *)ntx->agu[ntx->initSel];
    }

    ntx->cntState = 0;

#if NTX_DEBUG_LEVEL > 1
    printf("init accu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("op: NTX_MAXMIN (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstMaxMinOp::execute() {
    uint32_t * opB = (uint32_t *)ntx->agu[1];

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opB = %f (0x%08X)\n",fp32ToFloat(*opB), *opB);
    printf("op: NTX_MAXMIN (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif
    // negative polarity means MIN
    bool tst = (fp32ToFloat(ntx->aluState) > fp32ToFloat(*opB)) ^ !ntx->polarity;

    if(tst) {
        ntx->aluState = *opB;
        ntx->idxState  = ntx->cntState;
    }

    ntx->cntState++;
}

void
nstMaxMinOp::store() {
    uint32_t * res = (uint32_t *)ntx->agu[2];

    if(ntx->auxFunc) {
        *res = ntx->idxState;
    }
    else {
        *res = ntx->aluState;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_MAXMIN (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}


///////////////////////////////////////////////////////////////////////////////
// THTST
///////////////////////////////////////////////////////////////////////////////

void
nstThTstOp::init() {
    if(ntx->initSel >= 3) {
        ntx->aluState = C_FP32_ZERO_VAL;
    }
    else {
        ntx->aluState = *(uint32_t *)ntx->agu[ntx->initSel];
    }

#if NTX_DEBUG_LEVEL > 1
    printf("init alu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("op: NTX_THTST (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstThTstOp::execute() {

    opB = (uint32_t *)ntx->agu[1];

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opB = %f (0x%08X)\n",fp32ToFloat(*opB), *opB);
    printf("op: NTX_THTST (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    switch(ntx->auxFunc & 0x3) {
        case C_NTX_THTST_AUX_CMP_EQ:
            tst = (fp32ToFloat(ntx->aluState) == fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_MASK_AUX_CMP_LT:
            tst = (fp32ToFloat(ntx->aluState) > fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_THTST_AUX_CMP_LE:
            tst = (fp32ToFloat(ntx->aluState) >= fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        default:
            tst = 0;
            break;
    }
}

void
nstThTstOp::store() {
    uint32_t * res = (uint32_t *)ntx->agu[2];

    // binary output
    if(ntx->auxFunc & 0x4){
        *res = tst ? C_FP32_ONE_VAL : C_FP32_ZERO_VAL;
    }
    // thresholding output
    else {
        *res = tst ? *opB : ntx->aluState;
    }

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_THTST (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

///////////////////////////////////////////////////////////////////////////////
// conditional masking operation
///////////////////////////////////////////////////////////////////////////////

void
nstMaskOp::init() {
    if(ntx->initSel >= 3) {
        ntx->aluState = C_FP32_ZERO_VAL;
    }
    else {
        ntx->aluState = *(uint32_t *)ntx->agu[ntx->initSel];
    }

    ntx->cntState = 0;

#if NTX_DEBUG_LEVEL > 1
    printf("init alu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("op: NTX_MASK (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstMaskOp::execute() {

    opA = (uint32_t *)ntx->agu[0];
    uint32_t * opB = (uint32_t *)ntx->agu[1];


#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opB = %f (0x%08X)\n",fp32ToFloat(*opB), *opB);
    printf("op: NTX_MASK (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif


    switch(ntx->auxFunc) {
        case C_NTX_THTST_AUX_CMP_EQ:
            tst = (fp32ToFloat(ntx->aluState) == fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_MASK_AUX_CMP_LT:
            tst = (fp32ToFloat(ntx->aluState) > fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_THTST_AUX_CMP_LE:
            tst = (fp32ToFloat(ntx->aluState) >= fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_THTST_AUX_BIN_OUT:
            // compare with counter
            tst = ntx->cntState == ntx->aluState;
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        default:
            tst = 0;
            break;
    }

    ntx->cntState++;
}

void
nstMaskOp::store() {
    uint32_t * res = (uint32_t *)ntx->agu[2];


    // mask output
    *res = tst ? *opA : C_FP32_ZERO_VAL;


#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_MASK (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}


///////////////////////////////////////////////////////////////////////////////
// masked mac operation
///////////////////////////////////////////////////////////////////////////////

void
nstMaskMacOp::init() {

    // load two values
    if(ntx->initSel >= 3) {
        ntx->aluState = C_FP32_ZERO_VAL;
    }
    else {
        ntx->aluState = *(uint32_t *)ntx->agu[1];
    }

    uint32_t * res = (uint32_t *)ntx->agu[0];
    pcsMac ((*res),
            C_FP32_ONE_VAL,
            1,
            0,
            0,
            ntx->accuState,
            (*res));

    ntx->cntState = 0;

#if NTX_DEBUG_LEVEL > 1
    printf("init alu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("init accu with %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_MASKMAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstMaskMacOp::execute() {

    // load read-modify-write vector (result)
    opA = (uint32_t *)ntx->agu[2];

    uint32_t * opB = opA;
    if(!(ntx->auxFunc & 0x4)) {

        opB = (uint32_t *)ntx->agu[1];

#if NTX_DEBUG_LEVEL > 1
        printf("fetching: opB = %f (0x%08X)\n",fp32ToFloat(*opB), *opB);
#endif
    }

    switch(ntx->auxFunc) {
        case C_NTX_THTST_AUX_CMP_EQ:
            tst = (fp32ToFloat(ntx->aluState) == fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_MASK_AUX_CMP_LT:
            tst = (fp32ToFloat(ntx->aluState) > fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_THTST_AUX_CMP_LE:
            tst = (fp32ToFloat(ntx->aluState) >= fp32ToFloat(*opB));
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        case C_NTX_THTST_AUX_BIN_OUT:
            // compare with counter
            tst = ntx->cntState == ntx->aluState;
            // invert if necessary
            tst ^=  ntx->polarity;
            break;
        default:
            tst = 0;
            break;
    }

    ntx->cntState++;

#if NTX_DEBUG_LEVEL > 1
    printf("fetching: opA = %f (0x%08X)\n",fp32ToFloat(*opA), *opA);
    printf("op: NTX_MASKMAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstMaskMacOp::store() {
    uint32_t * res = (uint32_t *)ntx->agu[2];


    // conditionally accumulate and WB
    if(tst) {
        // call the bittrue model
        pcsMac ((*opA),
                C_FP32_ONE_VAL,
                0,
                0,
                1,
                ntx->accuState,
                (*res));

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_MASKMAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

    }
    else {
#if NTX_DEBUG_LEVEL > 1
    printf("not storing since comparison returned false\n");
    printf("op: NTX_MASKMAC (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif
    }

}


///////////////////////////////////////////////////////////////////////////////
// copy operation
///////////////////////////////////////////////////////////////////////////////

void
nstCopyOp::init() {

    if(!(ntx->auxFunc & 0x1)) {
        if(ntx->initSel >= 3) {
            ntx->aluState = C_FP32_ZERO_VAL;
        }
        else {
            ntx->aluState = *(uint32_t *)ntx->agu[ntx->initSel];
        }
    }

#if NTX_DEBUG_LEVEL > 1
    printf("init alu with %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
    printf("op: NTX_COPY");
#endif

}

void
nstCopyOp::execute() {

    if(ntx->auxFunc & 0x1) {
        ntx->aluState = *(uint32_t *)ntx->agu[0];

#if NTX_DEBUG_LEVEL > 1
        printf("fetching: aluState = %f (0x%08X)\n",fp32ToFloat(ntx->aluState), ntx->aluState);
#endif

    }

#if NTX_DEBUG_LEVEL > 1
    printf("op: NTX_COPY (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}

void
nstCopyOp::store() {
    uint32_t * res = (uint32_t *)ntx->agu[2];

    *res = ntx->aluState;

#if NTX_DEBUG_LEVEL > 1
    printf("storing: res = %f (0x%08X)\n",fp32ToFloat(*res), *res);
    printf("op: NTX_COPY (init: 0x%X, polarity: %u, auxFunc: %X)\n", ntx->initSel, ntx->polarity, ntx->auxFunc);
#endif

}


#endif
