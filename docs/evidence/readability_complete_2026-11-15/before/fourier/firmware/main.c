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
#define HEARTBEAT_US 100000U
#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif
#ifndef STDOUT_BASEADDRESS
#define STDOUT_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif
#define TELEMETRY_US 10000U
static int telemetry_streaming=0;
static uint16_t telemetry_seq=0;
static uint64_t telemetry_time;
static uint64_t ticks(void){XTime t;XTime_GetTime(&t);return (uint64_t)t;}
static uint32_t micros(uint64_t t){return (uint32_t)(t*1000000U/(COUNTS_PER_SECOND));}
static void heartbeat(void){Xil_Out32(CTRL+0x48,1U);}
static void send_telemetry_frame(void);
// Runtime PI tuning registers (0x068 ctrl2 bit0=open_loop_enable bit1=anti_windup_enable,
// 0x06c open_loop_duty, 0x070 kp_gain Q16, 0x074 ki_gain*Ts Q16). Reset defaults on the
// PL side reproduce the original fixed tuning exactly, so these commands are opt-in.
#define ORIGINAL_KP_Q16 58982U
#define ORIGINAL_KI_TS_Q16 3932U
// IMC_Kp_Q16/IMC_KiTs_Q16 from IDENTIFY_MOTOR.m on
// artifacts/experiments/open_loop_identification.csv (2026-09-17): plant gain
// 71.36 RPM/duty-pu, tau 0.620 s, dead time 0.060 s, test fit 40.3%.
#define CANDIDATE_KP_Q16 91486U
#define CANDIDATE_KI_TS_Q16 1477U
static int candidate_gains_active=0;
static void open_loop_dwell(uint32_t ms) {
    uint64_t start=ticks(),heartbeat_time=start,now;
    while(micros(ticks()-start)<ms*1000U){
        now=ticks();
        if(micros(now-heartbeat_time)>=HEARTBEAT_US){heartbeat();heartbeat_time=now;}
        if(telemetry_streaming && micros(now-telemetry_time)>=TELEMETRY_US){
            send_telemetry_frame();telemetry_time=now;
        }
        usleep(500);
    }
}
static void print_safety(void) {
    uint32_t status=Xil_In32(CTRL+0x04),detail=Xil_In32(CTRL+0x4c);
    printf("SAFETY,warning,%lu,derated,%lu,latched,%lu,watchdog,%lu,cause,%lu,consecutive,%lu,abnormal_total,%lu\r\n",
        (unsigned long)((status>>4)&1U),(unsigned long)((status>>5)&1U),
        (unsigned long)((status>>3)&1U),(unsigned long)((status>>6)&1U),
        (unsigned long)((detail>>10)&3U),(unsigned long)(detail&255U),
        (unsigned long)(detail>>16));
}
// Binary loop telemetry, byte-identical to the fixed 16-byte PL frame used on the
// earlier board, so the existing capture and analysis scripts need no change.
static void send_telemetry_frame(void) {
    uint8_t frame[16],checksum=0;unsigned n;
    uint32_t reference=Xil_In32(CTRL+0x50)&0x1fffU,measured=Xil_In32(CTRL+0x54)&0x1fffU;
    uint32_t duty=Xil_In32(CTRL+0x58)&0x1fffU;
    uint32_t integral=Xil_In32(CTRL+0x5c),status=Xil_In32(CTRL+0x04);
    uint32_t enabled=Xil_In32(CTRL+0x60)&1U,fault=(status>>3)&1U;
    frame[0]=0xa5;frame[1]=0x5a;
    frame[2]=(uint8_t)(telemetry_seq&255U);frame[3]=(uint8_t)(telemetry_seq>>8);
    frame[4]=(uint8_t)(reference&255U);frame[5]=(uint8_t)(reference>>8);
    frame[6]=(uint8_t)(measured&255U);frame[7]=(uint8_t)(measured>>8);
    frame[8]=(uint8_t)(duty&255U);frame[9]=(uint8_t)(duty>>8);
    frame[10]=(uint8_t)(integral&255U);frame[11]=(uint8_t)((integral>>8)&255U);
    frame[12]=(uint8_t)((integral>>16)&255U);frame[13]=(uint8_t)((integral>>24)&255U);
    // The PL had a separate arm signal; here the enable bit is the only arm state.
    frame[14]=(uint8_t)(enabled|(fault<<1)|(enabled<<2));
    for(n=0;n<15;n++)checksum^=frame[n];
    frame[15]=checksum;
    for(n=0;n<16;n++)XUartPs_SendByte(STDOUT_BASEADDRESS,frame[n]);
    telemetry_seq++;
}
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
    heartbeat();
    usleep(100000);
    if(write_reg(0x6b,0x01))return -1;
    heartbeat();
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
        // Keep the PL supervisor serviced during the blocking sensor window.
        // A stalled SPI transaction still times out and lets the watchdog trip.
        if((n&15U)==0U)heartbeat();
        deadline=ticks();
        do {
            if(spi(1,0,0x3a,0,&status))return -1;
            if(micros(ticks()-deadline)>8000U)return -1;
        }while(!(status&1));
        now=ticks();dt[n]=n?micros(now-previous):0;previous=now;
        if(n && (dt[n]<2800 || dt[n]>5200)) {
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
    heartbeat();infer_integer(x,&golden);cpu_us=micros(ticks()-t);
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
    uint64_t heartbeat_time;unsigned char command;
    // The first xiltimer sleep starts the Cortex-A9 global timer used below.
    usleep(1);
    // Simple, explicit BRAM coherency. Benchmark must report that D-cache is disabled.
    Xil_DCacheDisable();
    puts("V4 Fourier SoC, 100 MHz PL, 64 samples, 2 MAC PEs, D-cache OFF");
    puts("Commands: r=replay pair, x=replay one stored fault, i=init sensor, s=sample+infer, d=dump raw, b=100 replays, f=safety status, t/T=telemetry on/off, p=open-loop ID excitation, g/G=original/candidate PI gains, w/W=anti-windup on/off, o=preset quad position near overflow boundary");
    puts("RESULT columns: source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0..f3,h0..h3,o0,o1");
    heartbeat();heartbeat_time=ticks();
    for(;;) {
        if(micros(ticks()-heartbeat_time)>=HEARTBEAT_US){heartbeat();heartbeat_time=ticks();}
        if(telemetry_streaming && micros(ticks()-telemetry_time)>=TELEMETRY_US){
            send_telemetry_frame();
            telemetry_time=ticks();
        }
        if(!XUartPs_IsReceiveData(STDIN_BASEADDRESS)){usleep(1000);continue;}
        command=XUartPs_RecvByte(STDIN_BASEADDRESS);
        if(command=='r'){run_window("replay_normal",demo_samples[0]);run_window("replay_fault",demo_samples[1]);}
        else if(command=='x')run_window("replay_fault_injection",demo_samples[1]);
        else if(command=='b') {
            for(n=0;n<100;n++)if(run_window("benchmark",demo_samples[n%2]))break;
        }
        else if(command=='i'){sensor_ready=(sensor_init()==0);printf("SENSOR_READY,%d\r\n",sensor_ready);}
        else if(command=='f')print_safety();
        // t/T are absolute (see the g/G, w/W comment below) so a scripted capture
        // that always sends 't' first lands in a known streaming state regardless
        // of whatever a previous session left it in.
        else if(command=='t'||command=='T') {
            telemetry_streaming=(command=='t');
            if(telemetry_streaming){telemetry_seq=0;telemetry_time=ticks();}
            printf("TELEMETRY,%d\r\n",telemetry_streaming);
        }
        else if(command=='p') {
            // Open-loop duty staircase for system identification: 25/37.5/50/37.5/25%,
            // 5 s dwell each, AXI-timed instead of manual switch flips. This command
            // temporarily owns telemetry so one host process can send 'p' and capture
            // the entire response through the same serial connection.
            static const uint16_t steps[5]={1024,1536,2048,1536,1024};
            unsigned step_index;uint32_t ctrl2=Xil_In32(CTRL+0x068);
            int telemetry_was_streaming=telemetry_streaming;
            if(!telemetry_streaming){telemetry_streaming=1;telemetry_seq=0;telemetry_time=ticks();}
            Xil_Out32(CTRL+0x068,ctrl2|1U);
            puts("OPEN_LOOP_START");
            for(step_index=0;step_index<5;step_index++) {
                Xil_Out32(CTRL+0x06c,(uint32_t)steps[step_index]);
                printf("OPEN_LOOP_STEP,%u,%u\r\n",step_index,(unsigned)steps[step_index]);
                open_loop_dwell(5000U);
            }
            Xil_Out32(CTRL+0x06c,0U);
            ctrl2=Xil_In32(CTRL+0x068);
            Xil_Out32(CTRL+0x068,ctrl2&~1U);
            if(!telemetry_was_streaming)telemetry_streaming=0;
            puts("OPEN_LOOP_DONE");
        }
        // g/G and w/W are absolute, not toggles: a scripted A/B comparison run
        // (capture tool sends one of these via --send-command) must land in a known
        // state without first reading back the previous one.
        else if(command=='g'||command=='G') {
            candidate_gains_active=(command=='G');
            Xil_Out32(CTRL+0x070,candidate_gains_active?CANDIDATE_KP_Q16:ORIGINAL_KP_Q16);
            Xil_Out32(CTRL+0x074,candidate_gains_active?CANDIDATE_KI_TS_Q16:ORIGINAL_KI_TS_Q16);
            printf("GAINS,%s,kp_q16,%u,ki_ts_q16,%u\r\n",
                candidate_gains_active?"candidate":"original",
                (unsigned)(candidate_gains_active?CANDIDATE_KP_Q16:ORIGINAL_KP_Q16),
                (unsigned)(candidate_gains_active?CANDIDATE_KI_TS_Q16:ORIGINAL_KI_TS_Q16));
        }
        else if(command=='w'||command=='W') {
            uint32_t ctrl2=Xil_In32(CTRL+0x068);
            uint32_t enabled_now=(command=='w');
            ctrl2=enabled_now?(ctrl2|2U):(ctrl2&~2U);
            Xil_Out32(CTRL+0x068,ctrl2);
            printf("ANTI_WINDUP,%u\r\n",(unsigned)enabled_now);
        }
        else if(command=='o') {
            // Overflow-fault diagnostic: preset the quadrature position
            // register to one step short of the +-2^31 boundary (0x07c is
            // read-write for exactly this -- see encoder_quadrature.v). Two
            // real forward encoder edges from here latch overflow_fault
            // without needing billions of genuine pulses.
            Xil_Out32(CTRL+0x07c,0x7ffffffeU);
            printf("QUAD_POSITION_PRESET,0x7ffffffe\r\n");
        }
        else if(command=='s'||command=='d') {
            int result;
            if(!sensor_ready){puts("ERROR,run i first");continue;}
            result=acquire(samples,dt);if(result){printf("ERROR,capture,%d\r\n",result);continue;}
            if(command=='s')run_window("sensor",samples);
            else for(n=0;n<64;n++)printf("SAMPLE,%u,%d,%lu\r\n",n,samples[n],(unsigned long)dt[n]);
        }
    }
}
