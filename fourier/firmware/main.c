// Vitis 2024.2 standalone Cortex-A9 application. No FPGA-side training.
#include <stdint.h>
#include <stdio.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xiltimer.h"
#include "sleep.h"
#include "xparameters.h"
#include "xuartps_hw.h"
#include "golden.h"
#include "model_data.h"
#define CTRL 0x43c00000U
#define RAM  0x40000000U
#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif
static uint64_t ticks(void){XTime t;XTime_GetTime(&t);return (uint64_t)t;}
static uint32_t micros(uint64_t t){return (uint32_t)(t*1000000U/COUNTS_PER_SECOND);}
static int spi(int read_op,int two,uint8_t addr,uint8_t data,uint16_t *result) {
    uint64_t t=ticks();uint32_t status;
    Xil_Out32(CTRL+0x40,0x80000000U|((uint32_t)data<<16)|(two?256U:0U)|(read_op?128U:0U)|addr);
    do {
        status=Xil_In32(CTRL+0x44);
        if(micros(ticks()-t)>5000U)return -1;
    }while(!(status&(1U<<17)) || (status&(1U<<16)));
    *result=(uint16_t)status;return 0;
}
static int write_reg(uint8_t a,uint8_t v){uint16_t ignored;return spi(0,0,a,v,&ignored);}
static int sensor_init(void) {
    uint16_t id,check;uint8_t sample_divider;
    if(spi(1,0,0x75,0,&id))return -1;
    printf("WHO_AM_I,0x%02x,supported,0x70|0x71\r\n",id);
    if(id==0x70){puts("SENSOR_MODEL,MPU-6500");sample_divider=3;}
    else if(id==0x71){puts("SENSOR_MODEL,MPU-9250");sample_divider=0;}
    else return -1; // Do not silently accept an unknown or disconnected device.
    if(write_reg(0x6b,0x80))return -1;
    usleep(100000);
    if(write_reg(0x6b,0x01))return -1;
    usleep(100000);
    // Disable I2C interface, leave SPI active; wake all accel axes, +/-2g.
    if(write_reg(0x6a,0x10)||write_reg(0x6c,0)||write_reg(0x19,sample_divider)||write_reg(0x1b,0)||
       write_reg(0x1a,1)||write_reg(0x1c,0)||write_reg(0x1d,1)||write_reg(0x37,0)||write_reg(0x38,1))return -1;
    usleep(20000);
    if(spi(1,0,0x1c,0,&check)||check!=0)return -1;
    if(spi(1,0,0x1d,0,&check)||check!=1)return -1;
    if(spi(1,0,0x19,0,&check)||check!=sample_divider)return -1;
    return 0;
}
static int acquire(int16_t x[64],uint32_t dt[64]) {
    unsigned n;uint16_t status,raw;uint64_t previous=0,deadline,now;
    if(spi(1,0,0x3a,0,&status))return -1; // clear stale data-ready status
    for(n=0;n<64;n++) {
        deadline=ticks();
        do {
            if(spi(1,0,0x3a,0,&status))return -1;
            if(micros(ticks()-deadline)>5000U)return -1;
        }while(!(status&1));
        now=ticks();dt[n]=n?micros(now-previous):0;previous=now;
        if(n && (dt[n]<700 || dt[n]>1300)) {
            printf("TIMING_ERROR,%u,%lu\r\n",n,(unsigned long)dt[n]);
            return -2; // discarded window, no silent timing gaps
        }
        if(spi(1,1,0x3b,0,&raw))return -1;
        x[n]=(int16_t)(raw<32768?raw:(int32_t)raw-65536);
    }
    return 0;
}
static int run_window(const char *source,const int16_t x[64]) {
    unsigned n;int match=1;inference_result golden;
    uint64_t t=ticks();uint32_t cpu_us,elapsed,status,plcycles,ncycles;
    infer_integer(x,&golden);cpu_us=micros(ticks()-t);
    t=ticks();
    for(n=0;n<64;n++)Xil_Out32(RAM+4*n,(uint16_t)x[n]);
    __asm__ volatile("dsb sy" ::: "memory");
    Xil_Out32(CTRL,1);
    do {
        status=Xil_In32(CTRL+4);
        if(micros(ticks()-t)>10000U){puts("ERROR,PL timeout");return -1;}
    }while(!(status&2));
    if(status&5){puts("ERROR,PL status");return -1;}
    for(n=0;n<4;n++) {
        if(Xil_In32(RAM+4*(256+n))!=golden.features[n])match=0;
        if(Xil_In32(RAM+4*(260+n))!=golden.hidden[n])match=0;
    }
    for(n=0;n<2;n++)if((int32_t)Xil_In32(RAM+4*(264+n))!=golden.logits[n])match=0;
    if(Xil_In32(RAM+4*266)!=golden.class_id)match=0;
    elapsed=micros(ticks()-t);plcycles=Xil_In32(CTRL+12);ncycles=Xil_In32(CTRL+16);
    printf("RESULT,%s,%u,%lu,%lu,%lu,%lu,%d",source,golden.class_id,(unsigned long)cpu_us,
           (unsigned long)plcycles,(unsigned long)ncycles,(unsigned long)elapsed,match);
    for(n=0;n<4;n++)printf(",%u",golden.features[n]);
    for(n=0;n<4;n++)printf(",%u",golden.hidden[n]);
    printf(",%d,%d\r\n",golden.logits[0],golden.logits[1]);
    return match?0:-1;
}
int main(void) {
    int16_t samples[64];uint32_t dt[64];unsigned n;int sensor_ready=0;
    // The first xiltimer sleep starts the Cortex-A9 global timer used below.
    usleep(1);
    // Simple, explicit BRAM coherency. Benchmark must report that D-cache is disabled.
    Xil_DCacheDisable();
    puts("V4 Fourier SoC, 100 MHz PL, 64 samples, 2 MAC PEs, D-cache OFF");
    puts("Commands: r=replay, i=init MPU9250, s=sample+infer, d=dump raw, b=100 replays");
    puts("RESULT columns: source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0..f3,h0..h3,o0,o1");
    for(;;) {
        unsigned char command=XUartPs_RecvByte(STDIN_BASEADDRESS);
        if(command=='r'){run_window("replay_normal",demo_samples[0]);run_window("replay_fault",demo_samples[1]);}
        else if(command=='b') {
            for(n=0;n<100;n++)if(run_window("benchmark",demo_samples[n%2]))break;
        }
        else if(command=='i'){sensor_ready=(sensor_init()==0);printf("SENSOR_READY,%d\r\n",sensor_ready);}
        else if(command=='s'||command=='d') {
            int result;
            if(!sensor_ready){puts("ERROR,run i first");continue;}
            result=acquire(samples,dt);if(result){printf("ERROR,capture,%d\r\n",result);continue;}
            if(command=='s')run_window("sensor",samples);
            else for(n=0;n<64;n++)printf("SAMPLE,%u,%d,%lu\r\n",n,samples[n],(unsigned long)dt[n]);
        }
    }
}
