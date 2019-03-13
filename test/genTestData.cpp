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
#include <random>

#define NTX_EMULATION_ON

#include "ntx_api.hpp"

#define C_TCDM_MEMSIZE (1024*128)

/////////////////////////////
// enable tests
/////////////////////////////

#define ENABLE_1D_MAC_TEST
#define ENABLE_2D_MAC_TEST
#define ENABLE_3D_MAC_TEST
#define ENABLE_VADDSUB_TEST
#define ENABLE_VMULT_TEST
#define ENABLE_OUTERP_TEST
#define ENABLE_MAXMIN_TEST
#define ENABLE_THTST_TEST
#define ENABLE_MASK0_TEST
#define ENABLE_MASK1_TEST
#define ENABLE_MASKMAC0_TEST
#define ENABLE_MASKMAC1_TEST
#define ENABLE_COPY_TEST0
#define ENABLE_COPY_TEST1

/////////////////////////////
//
/////////////////////////////

void
writeMemDump(const char *     fileName,
             const uint32_t * array) {
    FILE * fid = fopen(fileName,"w");
    if(fid == NULL) {
         throw("error opening file\n");
    }
    for(uint32_t k = 0; k< C_TCDM_MEMSIZE; k++) {
        fprintf(fid,"0x%08x 0x%08x\n", k<<2, array[k]);
    }
    fclose(fid);
    return;
}

int
main(int argc, char ** argv) {

    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTDIR\n", argv[0]);
        return 1;
    }
    const char *outdir = argv[1];

    try {

        // 2D/2D convolution example
        uint32_t * tcdm = new uint32_t[C_TCDM_MEMSIZE];

        std::random_device rd;
        //std::mt19937 re(rd());
        //std::knuth_b re(rd());
        std::default_random_engine re(rd()) ;
        std::uniform_real_distribution<> dist(-1.0, 1.0);

        ntx_api ntx(0x00000000);
        ntx.setTcdmBaseCheck(tcdm, tcdm+C_TCDM_MEMSIZE-1);

        uint32_t * opA, * opB, * res;
        uint32_t vectorLen1, vectorLen2;
        uint32_t cnt;
        char * str1 = new char[300];
        char * str2 = new char[300];

        cnt = 0;

        //////////////////////////////////////////////////////////
        // fixed vector length tests
        //////////////////////////////////////////////////////////

        /////////////////////////////
        // 1D MAC reduction kernel
        // variants
        // with/without init,
        // with/without ReLu
        // addititive/subtractive accumulation
        /////////////////////////////

#ifdef ENABLE_1D_MAC_TEST

        for(int k = 0; k < 8; k++) {

            vectorLen1 = 100;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 3*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,1,1,
                              {vectorLen1,0U,0U,0U,0U},
                              {1,0,0,0,0,
                               1,0,0,0,0,
                               0,0,0,0,0});

            ntx.stageAguOffs(opA,
                             opB,
                             res);

            ntx.stageCmd(C_NTX_MAC_OP,                     // opCode
                         C_NTX_INIT_WITH_AGU2 + (0x1 & k), // initSel
                         (0x1 & (k >> 1)),                 // auxFunc
                         C_NTX_SET_CMD_IRQ,                // irqCfg
                         (0x1 & (k >> 2)));                // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"1D_reduction_NTX_MAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // 2D reduction kernels
        // variants
        // with/without init,
        // with/without ReLu
        // addititive/subtractive accumulation
        /////////////////////////////

#ifdef ENABLE_2D_MAC_TEST

        for(int k = 0; k < 8; k++) {

            vectorLen1 = 10;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + 10;
            opB = tcdm + 2*vectorLen1*vectorLen1 + 10;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1*vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(2,2,2,
                               {vectorLen1,vectorLen1,0U,0U,0U},
                               {1,(int32_t)vectorLen1,0,0,0,
                                1,(int32_t)vectorLen1,0,0,0,
                                0,0,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MAC_OP,                     // opCode
                         C_NTX_INIT_WITH_AGU2 + (0x1 & k), // initSel
                         (0x1 & (k >> 1)),                 // auxFunc
                         C_NTX_SET_CMD_IRQ,                // irqCfg
                         (0x1 & (k >> 2)));                // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"2D_reduction_NTX_MAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // 3D reduction kernels with 2D strides (uses all loops)
        // variants
        // with/without init,
        // with/without ReLu
        // addititive/subtractive accumulation
        /////////////////////////////

#ifdef ENABLE_3D_MAC_TEST
        for(int k = 0; k < 8; k++) {

            // generate two 20x20 tiles with 10 channels
            vectorLen1 = 10*20*20;
            // a 3D convolution with 2D stride will then generate a 10x10 output

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 2*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(3,3,5,
                               {10U,10U,10U,10U,10U},
                               {1,20,20*20,1,20,
                                1,20,20*20,1,20,
                                0,0,0,1,10});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MAC_OP,                     // opCode
                         C_NTX_INIT_WITH_ZERO - (0x1 & k), // initSel
                         (0x1 & (k >> 1)),                 // auxFunc
                         C_NTX_SET_CMD_IRQ,                // irqCfg
                         (0x1 & (k >> 2)));                // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"3D_reduction_2D_stride_NTX_MAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif


        /////////////////////////////
        // 1D vector addsub
        // with/without ReLu
        // addition/subtraction
        /////////////////////////////

#ifdef ENABLE_VADDSUB_TEST

        for(int k = 0; k < 4; k++) {

            vectorLen1 = 100;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 3*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(0,0,1,
                               {vectorLen1,0U,0U,0U,0U},
                               {1,0,0,0,0,
                                1,0,0,0,0,
                                1,0,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_VADDSUB_OP,      // opCode
                         C_NTX_INIT_WITH_AGU1,  // initSel
                         (0x1 & k),             // auxFunc
                         C_NTX_SET_CMD_IRQ,     // irqCfg
                         (0x1 & (k >> 1)));     // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"1D_vector_C_NTX_VADDSUB_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // 1D vector mult
        // with/without ReLu
        // addition/subtraction
        /////////////////////////////

#ifdef ENABLE_VMULT_TEST

        for(int k = 0; k < 4; k++) {

            vectorLen1 = 100;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 3*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(0,0,1,
                               {vectorLen1,0U,0U,0U,0U},
                               {1,0,0,0,0,
                                1,0,0,0,0,
                                1,0,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_VMULT_OP,      // opCode
                         C_NTX_INIT_WITH_AGU1,     // initSel
                         (0x1 & k),  // auxFunc
                         C_NTX_SET_CMD_IRQ, // irqCfg
                         (0x1 & (k >> 1))); // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"1D_vector_C_NTX_VMULT_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // outer product
        /////////////////////////////

#ifdef ENABLE_OUTERP_TEST

        for(int k = 0; k < 4; k++) {

            // 20x20 outerproduct
            vectorLen1 = 20;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm +   vectorLen1*vectorLen1+10;
            opB = tcdm + 2*vectorLen1*vectorLen1+10;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                               {20U,20U,0U,0U,0U},
                               {1,0,0,0,0,
                                0,1,0,0,0,
                                1,20,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_OUTERP_OP,      // opCode
                         C_NTX_INIT_WITH_AGU1, // initSel: opB
                         (0x1 & (k>>1)),       // auxFunc
                         C_NTX_SET_CMD_IRQ,    // irqCfg
                         (0x1 & k));           // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"outer_product_C_NTX_OUTERP_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // 1D MAXMIN reduction kernel
        // variants
        // with/without init,
        // with/without ReLu
        // addititive/subtractive accumulation
        /////////////////////////////

#ifdef ENABLE_MAXMIN_TEST
        for(int k = 0; k < 4; k++) {

            vectorLen1 = 100;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 3*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
                *(opB+n) = floatTofp32(dist(re));
            }

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,1,1,
                               {vectorLen1,0U,0U,0U,0U},
                               {0,0,0,0,0,
                                1,0,0,0,0,// maxmin works on agu 1
                                0,0,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MAXMIN_OP,   // opCode
                         C_NTX_INIT_WITH_AGU1, // initSel
                         (0x1 & k),         // auxFunc
                         C_NTX_SET_CMD_IRQ, // irqCfg
                         (0x1 & (k >> 1))); // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"1D_reduction_NTX_MAXMIN_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // test/thresholding
        // variants
        /////////////////////////////

#ifdef ENABLE_THTST_TEST

        for(int k = 0; k < 32; k++) {

            // loop over 10 vectors of length 100
            vectorLen1 = 100*10;
            // produces 10*100 output values

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 2*vectorLen1;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opB+n) = floatTofp32(dist(re));
            }

            for (uint32_t n = 0; n < 10; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }

            // for equality tests
            *(opB+2) = floatTofp32(0.0);
            *(opA+1) = *(opB+15);

            *(res+0) = floatTofp32(dist(re));

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                               {100U,10U,0U,0U,0U},
                               {0,1,0,0,0,
                                1,100,0,0,0,
                                1,100,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_THTST_OP,    // opCode
                         C_NTX_INIT_WITH_ZERO - 3*(0x1 & k),   // initSel: zero or opA
                         (0x7 & (k >> 1)),  // auxFunc
                         C_NTX_SET_CMD_IRQ, // irqCfg
                         (0x1 & (k >> 4))); // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"vector_mask_NTX_THTST_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // masking
        // variants
        /////////////////////////////

#ifdef ENABLE_MASK0_TEST
        for(int k = 0; k < 8; k++) {

            // loop over 10 vectors of length 100
            vectorLen1 = 100*10;
            // produces 10*100 output values

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 2*vectorLen1+50;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opB+n) = floatTofp32(dist(re));
                *(opA+n) = floatTofp32(dist(re));
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(2,0,2,
                               {100U,10U,0U,0U,0U},
                               {1,100,0,0,0,
                                1,100,0,0,0,
                                1,100,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MASK_OP,        // opCode
                         C_NTX_INIT_WITH_ZERO, // initSel: zero
                         (0x3 & k),            // auxFunc
                         C_NTX_SET_CMD_IRQ,    // irqCfg
                         (0x1 & (k >> 2)));    // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"vector_mask_NTX_MASKMAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // masking
        // variants
        // with internal counters
        /////////////////////////////

#ifdef ENABLE_MASK1_TEST
        for(int k = 0; k < 2; k++) {

            // loop over 10 vectors of length 100
            vectorLen1 = 100*10;
            // produces 10*100 output values

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1;
            opB = tcdm + 2*vectorLen1+50;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }

            for (uint32_t n = 0; n < 10; ++n) {
                *(opB+n) = fmax(round(50.0*dist(re)+49.0),0.0f);
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                               {100U,10U,0U,0U,0U},
                               {1,100,0,0,0,
                                0,1,0,0,0,
                                1,100,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MASK_OP,          // opCode
                         C_NTX_INIT_WITH_AGU1,   // initSel: opB
                         C_NTX_MASK_AUX_CMP_CNT, // auxFunc
                         C_NTX_SET_CMD_IRQ,      // irqCfg
                         (0x1 & k));             // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"internal_counter_NTX_MASKMAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // masking
        // variants
        // with internal counters
        /////////////////////////////

#ifdef ENABLE_MASKMAC0_TEST
        for(int k = 0; k < 8; k++) {

            // 10 vectors of length 100, stored at the res position
            // each vector has an associated vector with nonzero entries
            // and an offset in opA to be added to the argmax position
            vectorLen1 = 100;
            vectorLen2 = 10;
            // produces 10*100 output values

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1*vectorLen2 + 10;
            opB = tcdm + vectorLen1*vectorLen2 + vectorLen2 + 20;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1*vectorLen2; ++n) {
                *(res+n) = floatTofp32(dist(re));
            }

            // generate some random data
            for (uint32_t n = 0; n < vectorLen2; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }
            // generate Argmax indices
            for (uint32_t n = 0; n < vectorLen1*vectorLen2; ++n) {
                *(opB+n) = floatTofp32(1.0 * (dist(re) >= 0.0));
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                               {vectorLen1,vectorLen2,0U,0U,0U},
                               {0,1,0,0,0,
                                1,(int)vectorLen1,0,0,0,
                                1,(int)vectorLen1,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MASKMAC_OP,     // opCode
                         C_NTX_INIT_WITH_ZERO, // initSel: set to zero
                         (0x3 & k),            // auxFunc
                         C_NTX_SET_CMD_IRQ,    // irqCfg
                         (0x1 & (k >> 2)));    // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"internal_counter_NTX_MASKMAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // masking
        // variants
        // with internal counters
        /////////////////////////////

#ifdef ENABLE_MASKMAC1_TEST
        for(int k = 0; k < 2; k++) {

            // 10 vectors of length 100, stored at the res position
            // each vector has an associated argmax position in opB,
            // and an offset in opA to be added to the argmax position
            vectorLen1 = 100;
            vectorLen2 = 10;
            // produces 10*100 output values

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1*vectorLen2 + 10;
            opB = tcdm + vectorLen1*vectorLen2 + vectorLen2 + 20;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1*vectorLen2; ++n) {
                *(res+n) = floatTofp32(dist(re));
            }

            // generate some random data
            for (uint32_t n = 0; n < vectorLen2; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }
            // generate Argmax indices
            for (uint32_t n = 0; n < vectorLen2; ++n) {
                *(opB+n) = fmax(round(vectorLen1/2 * dist(re) + vectorLen1/2 - 1),0.0f);
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                               {vectorLen1,vectorLen2,0U,0U,0U},
                               {0,1,0,0,0,
                                0,1,0,0,0,
                                1,(int)vectorLen1,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_MASKMAC_OP,       // opCode
                         C_NTX_INIT_WITH_AGU1,   // initSel: opB (the argmax locations)
                         C_NTX_MASK_AUX_CMP_CNT, // auxFunc:
                         C_NTX_SET_CMD_IRQ,      // irqCfg
                         (0x1 & k));             // polarity

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"internal_counter_NTX_MASKMAC_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif
        /////////////////////////////
        // copy variant with init cycle
        /////////////////////////////

#ifdef ENABLE_COPY_TEST0
        for(int k = 0; k < 2; k++) {

            // replicate 100 values from opA (100 vector) to res (10x100 matrix)
            vectorLen1 = 100;
            vectorLen2 = 10;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1*vectorLen2 + 10;
            opB = tcdm;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(1,0,2,
                              {vectorLen1,vectorLen2,0U,0U,0U},
                              {0,1,0,0,0,
                               0,0,0,0,0,
                               1,(int)vectorLen1,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_COPY_OP,          // opCode
                         (k) ? C_NTX_INIT_WITH_AGU0 : C_NTX_INIT_WITH_ZERO, // initSel: AGU0 or ZERO
                         C_NTX_COPY_AUX_REPL,    // auxFunc: use init cycle to replicate this value
                         C_NTX_SET_CMD_IRQ,      // irqCfg
                         C_NTX_POS_POLARITY);    // polarity (unused here)

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"replicate_NTX_COPY_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif

        /////////////////////////////
        // copy variant with vector
        /////////////////////////////

#ifdef ENABLE_COPY_TEST1
        for(int k = 0; k < 1; k++) {

            // copy 100x10 matrix from opA to res
            vectorLen1 = 100;
            vectorLen2 = 10;

            memset(tcdm, 0x55, sizeof(uint32_t)*C_TCDM_MEMSIZE);

            opA = tcdm + vectorLen1*vectorLen2 + 10;
            opB = tcdm;
            res = tcdm + 0;

            // generate some random data
            for (uint32_t n = 0; n < vectorLen1*vectorLen2; ++n) {
                *(opA+n) = floatTofp32(dist(re));
            }

            // dump memroy initialization
            sprintf(str1,"%s/ini%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            ntx.stageLoopNest(0,0,2,
                              {vectorLen1,vectorLen2,0U,0U,0U},
                              {1,(int)vectorLen1,0,0,0,
                               0,0,0,0,0,
                               1,(int)vectorLen1,0,0,0});

            ntx.stageAguOffs(opA, opB, res);

            ntx.stageCmd(C_NTX_COPY_OP,          // opCode
                         C_NTX_INIT_WITH_ZERO,   // initSel: AGU0 or ZERO
                         C_NTX_COPY_AUX_VECT,    // auxFunc: use init cycle to replicate this value
                         C_NTX_SET_CMD_IRQ,      // irqCfg
                         C_NTX_POS_POLARITY);    // polarity (unused here)

            // dump nst job
            sprintf(str1,"%s/job%04d.txt", outdir, cnt);
            sprintf(str2,"vector_NTX_COPY_OP_%d",k);
            ntx.writeJobDump(str1, str2, tcdm);

            // call golden model
            ntx.issueCmd();

            // dump expected memory state
            sprintf(str1,"%s/exp%04d.txt", outdir, cnt);
            writeMemDump(str1, tcdm);

            printf("generating job %u: %s\n", cnt, str2);
            cnt++;
        }
#endif




        delete [] str1;
        delete [] str2;

    } catch(std::bad_alloc&) {
        fprintf(stderr, "Out of memory");
    } catch(const char* p) {
        fprintf(stderr, p);
    } catch(...) {
        fprintf(stderr,"Unknown exception caught");
    }
    return 0;
}



