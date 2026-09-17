// ============================================================================
// [공부용 주석 사본] fourier/firmware/main.c
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "ARM Cortex-A9(PS) 위에서 운영체제 없이(standalone)
// 돌아가는 애플리케이션 — SPI 센서를 초기화하고, AXI 레지스터(axi_vibration_top.v)를
// 읽고 써서 FPGA 가속기(FFT+NPU, 모터 제어)를 조종하며, UART로 사람이 보내는
// 한 글자 명령을 받아 실험/진단/텔레메트리 기능을 수행하는 전체 프로그램의 진입점"
//
// Memory-mapped I/O란 무엇인가 (배경지식, 이 파일 전체를 이해하는 핵심 개념)
// -----------------------------------------------------------------------
// ARM 코어에는 "FPGA 레지스터에 쓰기"라는 특별한 명령어가 따로 없습니다.
// 대신 특정 메모리 주소(예: 0x43c00000)에 그냥 평범한 저장(store) 명령으로
// 값을 쓰면, 그 주소가 AXI 버스를 거쳐 axi_vibration_top.v로 연결되어 있기
// 때문에 실제로는 "FPGA 레지스터에 쓴" 것과 같은 효과가 납니다. 이걸
// memory-mapped I/O라고 부릅니다. Xilinx SDK/Vitis가 제공하는
// `Xil_Out32(주소, 값)`과 `Xil_In32(주소)`가 바로 이 "메모리 주소에 32비트
// 쓰기/읽기"를 수행하는 함수입니다 — 컴파일러가 최적화로 없애버리거나 순서를
// 바꾸지 못하도록(volatile 성격의 접근) 보장해주는 것이 일반 변수 접근과
// 다른 점입니다. 이 파일에서 CTRL(=0x43c00000, axi_vibration_top의 레지스터
// 베이스 주소)과 RAM(=0x40000000, BRAM 베이스 주소)에 대한 모든 접근이 이
// 방식입니다. 예를 들어 `Xil_Out32(CTRL+0x48,1U)`는 axi_vibration_top.v의
// 레지스터 맵 0x048번지(ps_heartbeat 펄스)에 1을 쓰는 것이고, 이는
// axi_vibration_top.v study 사본에 있는 그 레지스터 설명과 정확히 대응됩니다.
// ============================================================================

// Vitis 2024.2 standalone Cortex-A9 application. No FPGA-side training.
#include <stdint.h>
#include <stdio.h>
#include "xil_io.h"      // Xil_Out32/Xil_In32 (memory-mapped I/O 함수)
#include "xil_cache.h"    // Xil_DCacheDisable 등 캐시 제어
#include "xiltimer.h"     // XTime_GetTime 등 타이머
#include "sleep.h"        // usleep
#include "xparameters.h"  // 보드/IP별 자동생성 주소·상수 정의(COUNTS_PER_SECOND 등)
#include "xuartps_hw.h"   // UART 직접 제어 함수(XUartPs_RecvByte 등)
#include "golden.h"       // ARM에서 순수 C로 돌리는 "정답 계산기"(FFT+NPU를 소프트웨어로 재구현)
#include "model_data.h"   // 신경망 가중치 등 모델 데이터, demo_samples(내장 샘플) 등
#define CTRL 0x43c00000U  // axi_vibration_top.v의 AXI 레지스터 베이스 주소
#define RAM  0x40000000U  // vibration_core가 쓰는 BRAM(64 입력 샘플 + 결과 저장)의 베이스 주소
#define HEARTBEAT_US 100000U // 100ms(=100000us)마다 한 번씩 heartbeat를 쏨
#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif
#ifndef STDOUT_BASEADDRESS
#define STDOUT_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif
#define TELEMETRY_US 10000U // 텔레메트리 스트리밍 켜져있으면 10ms(100Hz)마다 한 프레임 전송
static int telemetry_streaming=0;   // t/T 명령으로 켜고 끄는 텔레메트리 상태
static uint16_t telemetry_seq=0;    // 텔레메트리 프레임 일련번호(수신측이 프레임 손실 감지용)
static uint64_t telemetry_time;     // 마지막 텔레메트리 전송 시각(틱)
static uint64_t ticks(void){XTime t;XTime_GetTime(&t);return (uint64_t)t;} // 현재 시각을 하드웨어 글로벌 타이머 틱 단위로
// (한국어, 실제로 겪은 버그 이야기) micros() 함수: 틱 차이(t)를 마이크로초로
// 환산합니다. 겉보기엔 단순한 공식 `t*1000000U/(COUNTS_PER_SECOND)`인데,
// 여기 괄호가 반드시 필요합니다 — 실제로 이 프로젝트를 개발하던 세션에서
// 겪은 버그가 이 지점이었습니다. Xilinx가 자동생성하는 헤더(xparameters.h류)
// 안의 COUNTS_PER_SECOND 같은 매크로는 종종 그냥 `#define COUNTS_PER_SECOND
// 333333333` 처럼 괄호 없는 숫자 하나로 정의되어 있습니다. 문제는 이 매크로
// 자체가 아니라, 만약 코드에서 나눗셈 앞뒤를 괄호로 묶지 않고
// `t*1000000U/COUNTS_PER_SECOND` 라고만 썼는데 COUNTS_PER_SECOND가
// `A*B` 같은 "곱셈 표현식"으로 정의된 매크로였다면(보드/IP 설정에 따라
// 그럴 수 있음), C의 연산자 우선순위 규칙상 `/`와 매크로 치환 후 나타나는
// `*`가 뒤섞이면서 "전체를 A*B로 나누기"가 아니라 "A로만 나누고 B를 곱하는"
// 전혀 다른 계산이 되어버립니다. 실제로 이 프로젝트에서 벌어진 건 `micros()`가
// 진짜 경과 시간의 1/4만큼 작은 값을 돌려주는 버그였습니다 — 즉 실제로 4ms가
// 지나도 micros()는 1ms 지났다고 보고합니다. 이게 왜 위험하냐면, "5초 지났는지"를
// 검사하는 코드(`while(micros(ticks()-start)<5000000U)`)는 micros()가 1/4로
// 축소돼 보고되니 진짜로는 4배 더 걸려야(20초) "5초 지났다"는 조건을 만족합니다
// — 대기 시간이 짧아지는 게 아니라 반대로 4배 늘어지는 쪽으로 나타났습니다.
// 실제로 이 버그 때문에 텔레메트리 전송 주기가 설계값 100Hz 대신 실측
// ~25Hz(100Hz의 정확히 1/4)로 나왔던 것이 이 문제를 처음 발견한 단서였습니다.
// 해결책은 매크로가 뭘로 정의되어 있든 항상 안전하도록
// 나누는 대상 전체를 괄호로 딱 감싸는 것 — `t*1000000U/(COUNTS_PER_SECOND)`.
// 교훈: 자동생성 헤더의 매크로를 나눗셈의 분모로 쓸 때는 습관적으로 괄호를
// 쳐서, 그 매크로가 나중에 복잡한 표현식으로 바뀌어도 항상 "그 값 전체"로
// 나누도록 방어하는 게 안전합니다.
static uint32_t micros(uint64_t t){return (uint32_t)(t*1000000U/(COUNTS_PER_SECOND));}
static void heartbeat(void){Xil_Out32(CTRL+0x48,1U);} // 0x048에 1을 씀 -> ps_heartbeat 펄스 -> PL의 watchdog이 안 걸림
static void send_telemetry_frame(void);
// Runtime PI tuning registers (0x068 ctrl2 bit0=open_loop_enable bit1=anti_windup_enable,
// 0x06c open_loop_duty, 0x070 kp_gain Q16, 0x074 ki_gain*Ts Q16). Reset defaults on the
// PL side reproduce the original fixed tuning exactly, so these commands are opt-in.
#define ORIGINAL_KP_Q16 58982U   // axi_vibration_top.v 리셋값과 동일한 "원래" 고정 튜닝 게인
#define ORIGINAL_KI_TS_Q16 3932U
// IMC_Kp_Q16/IMC_KiTs_Q16 from IDENTIFY_MOTOR.m on
// artifacts/experiments/open_loop_identification.csv (2026-09-17): plant gain
// 71.36 RPM/duty-pu, tau 0.620 s, dead time 0.060 s, test fit 40.3%.
// (한국어) 이 두 값은 나중에 'p' 명령으로 open-loop 시스템 식별 실험을 해서
// 얻은 데이터를 IMC(Internal Model Control) 방식으로 재계산한 "후보" 게인.
// 'g'/'G' 명령으로 원래 값과 이 후보 값을 즉시 전환해가며 A/B 비교할 수 있음.
#define CANDIDATE_KP_Q16 91486U
#define CANDIDATE_KI_TS_Q16 1477U
static int candidate_gains_active=0; // 지금 원래 게인인지 후보 게인인지 기억(g/G 명령이 갱신)
// open_loop_dwell: ms 밀리초 동안 그냥 대기만 하는 게 아니라, 대기하는
// 동안에도 heartbeat와(켜져 있으면) 텔레메트리 전송을 계속 서비스해주는
// 함수. 'p' 명령(개루프 duty 계단 시퀀스)이 각 단계마다 5초씩 멈춰있어야
// 하는데, 그냥 usleep(5000000)으로 5초를 통으로 자버리면 그 사이
// heartbeat가 끊겨 PL의 watchdog이 걸려서 모터가 강제로 멈춰버리는 문제가
// 생김 — 그래서 짧게(500us) 쪼개어 자면서 그때그때 heartbeat/텔레메트리를
// 체크하는 루프로 만든 것.
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
// print_safety: 0x004(상태 비트 묶음)와 0x04c(안전 세부정보)를 읽어서 사람이
// 읽을 수 있는 한 줄 텍스트로 출력. 'f' 명령이 이 함수를 호출함. 비트
// 시프트/마스크(>>4)&1U 등은 axi_vibration_top.v study 사본의 레지스터
// 맵 표에 있는 비트 배치와 정확히 대응됨(0x004의 비트4=warning, 비트5=derated,
// 비트3=fault_latched, 비트6=watchdog_fault; 0x04c의 비트10:11=fault_cause,
// 하위8비트=fault_consec, 상위16비트=abnormal_count).
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
// (한국어) send_telemetry_frame: 모터 상태(목표속도, 실측속도, duty, PI 적분값,
// 무장/고장 여부)를 16바이트짜리 바이너리 프레임 하나로 묶어 UART로 그대로
// 쏨(사람이 읽는 텍스트가 아니라 PC 쪽 파이썬 스크립트 등이 파싱하는 고정
// 포맷). frame[0..1]은 매직 바이트(0xa5,0x5a, 수신측이 프레임 시작을 찾는
// 동기 워드), [2:3]은 순번, [4:5]/[6:7]/[8:9]/[10:13]은 각각 reference/
// measured/duty/integral을 리틀엔디안 바이트로 쪼갠 것, [14]는 상태 비트,
// [15]는 XOR 체크섬(수신측이 전송 오류를 검증).
static void send_telemetry_frame(void) {
    uint8_t frame[16],checksum=0;unsigned n;
    uint32_t reference=Xil_In32(CTRL+0x50)&0x1fffU,measured=Xil_In32(CTRL+0x54)&0x1fffU;
    uint32_t duty=Xil_In32(CTRL+0x58)&0x1fffU;
    uint32_t integral=Xil_In32(CTRL+0x5c),status=Xil_In32(CTRL+0x04);
    uint32_t enabled=Xil_In32(CTRL+0x60)&1U,fault=(status>>3)&1U;
    frame[0]=0xa5;frame[1]=0x5a; // 동기 워드(수신측이 프레임 경계를 찾음)
    frame[2]=(uint8_t)(telemetry_seq&255U);frame[3]=(uint8_t)(telemetry_seq>>8);
    frame[4]=(uint8_t)(reference&255U);frame[5]=(uint8_t)(reference>>8);
    frame[6]=(uint8_t)(measured&255U);frame[7]=(uint8_t)(measured>>8);
    frame[8]=(uint8_t)(duty&255U);frame[9]=(uint8_t)(duty>>8);
    frame[10]=(uint8_t)(integral&255U);frame[11]=(uint8_t)((integral>>8)&255U);
    frame[12]=(uint8_t)((integral>>16)&255U);frame[13]=(uint8_t)((integral>>24)&255U);
    // The PL had a separate arm signal; here the enable bit is the only arm state.
    frame[14]=(uint8_t)(enabled|(fault<<1)|(enabled<<2));
    for(n=0;n<15;n++)checksum^=frame[n]; // 15바이트 전부 XOR한 체크섬
    frame[15]=checksum;
    for(n=0;n<16;n++)XUartPs_SendByte(STDOUT_BASEADDRESS,frame[n]); // UART로 16바이트 그대로 전송
    telemetry_seq++;
}
// spi(): mpu_reg_spi.v(axi_vibration_top.v의 0x040/0x044 레지스터)를 통해
// SPI 센서에 한 번의 읽기/쓰기 트랜잭션을 수행하는 저수준 함수. 0x040에
// bit31(트리거)|data<<16|two<<8|read<<7|addr를 써서 시작시키고, 0x044를
// 폴링하며 완료(bit17=1)와 busy(bit16=0)를 기다림. 5ms(5000us) 안에 안
// 끝나면 타임아웃으로 -1 반환 — SPI 통신이 하드웨어 문제로 영영 안 끝나는
// 상황에서 소프트웨어가 무한루프에 빠지지 않게 하는 방어 코드.
static int spi(int read_op,int two,uint8_t addr,uint8_t data,uint16_t *result) {
    uint64_t t=ticks();uint32_t status;
    Xil_Out32(CTRL+0x40,0x80000000U|((uint32_t)data<<16)|(two?256U:0U)|(read_op?128U:0U)|addr);
    do {
        status=Xil_In32(CTRL+0x44);
        if(micros(ticks()-t)>5000U)return -1;
    }while(!(status&(1U<<17)) || (status&(1U<<16)));
    *result=(uint16_t)status;return 0;
}
static int write_reg(uint8_t a,uint8_t v){uint16_t ignored;return spi(0,0,a,v,&ignored);} // spi()의 "레지스터 쓰기" 전용 축약형
// sensor_init: MPU-6500/9250 IMU(가속도 센서)를 SPI로 초기화. WHO_AM_I(0x75)
// 레지스터를 읽어 어떤 칩인지 식별하고(0x70=6500, 0x71=9250 — 9250은 자이로
// 축이 더 있어서 샘플 분주값이 다름), 리셋(0x6b=0x80) 후 절전모드 해제
// (0x6b=0x01), I2C 비활성화+SPI 전용+가속도축 깨우기+범위설정 등을 순서대로
// 씀. 마지막에 몇몇 레지스터를 다시 읽어(check) 실제로 원하는 값이 들어갔는지
// 검증한 뒤에만 성공(0)을 반환 — "썼으니 됐겠지"라고 가정하지 않고 반드시
// 되읽어 확인하는 방어적 코딩.
static int sensor_init(void) {
    uint16_t id,check;uint8_t sample_divider;
    if(spi(1,0,0x75,0,&id))return -1;
    printf("WHO_AM_I,0x%02x,supported,0x70|0x71\r\n",id);
    if(id==0x70){puts("SENSOR_MODEL,MPU-6500");sample_divider=3;}
    else if(id==0x71){puts("SENSOR_MODEL,MPU-9250");sample_divider=0;}
    else return -1; // Do not silently accept an unknown or disconnected device.
    if(write_reg(0x6b,0x80))return -1; // 전체 리셋
    heartbeat();
    usleep(100000);
    if(write_reg(0x6b,0x01))return -1; // 절전 해제, 클럭소스 선택
    heartbeat();
    usleep(100000);
    // Disable I2C interface, leave SPI active; wake all accel axes, +/-2g.
    if(write_reg(0x6a,0x10)||write_reg(0x6c,0)||write_reg(0x19,sample_divider)||write_reg(0x1b,0)||
       write_reg(0x1a,1)||write_reg(0x1c,0)||write_reg(0x1d,1)||write_reg(0x37,0)||write_reg(0x38,1))return -1;
    usleep(20000);
    // 되읽어서 검증(방어적 코딩): 샘플레이트 분주값, 가속도계 설정이 실제로 반영됐는지 확인
    if(spi(1,0,0x1c,0,&check)||check!=0)return -1;
    if(spi(1,0,0x1d,0,&check)||check!=1)return -1;
    if(spi(1,0,0x19,0,&check)||check!=sample_divider)return -1;
    return 0;
}
// acquire: 센서로부터 64개의 가속도 샘플을 순서대로 읽어오는 함수. 매 샘플마다
// "데이터 준비됨" 상태 레지스터(0x3a)를 폴링해서 기다린 뒤, 실제 값(0x3b)을
// 읽음. dt[n]에는 이번 샘플과 이전 샘플 사이의 실제 간격(마이크로초)을 기록.
static int acquire(int16_t x[64],uint32_t dt[64]) {
    unsigned n;uint16_t status,raw;uint64_t previous=0,deadline,now;
    if(spi(1,0,0x3a,0,&status))return -1; // clear stale data-ready status  (이전에 남아있을 수 있는 낡은 상태를 먼저 비움)
    for(n=0;n<64;n++) {
        // Keep the PL supervisor serviced during the blocking sensor window.
        // A stalled SPI transaction still times out and lets the watchdog trip.
        // (한국어) 64개를 다 모으는 동안 시간이 좀 걸리므로, 16개마다 한 번씩
        // heartbeat를 쏴서 그 사이에 PL의 watchdog이 걸리지 않게 함. 그래도
        // SPI가 실제로 멈춰버리면 아래 8ms 타임아웃으로 결국 -1을 반환하고
        // watchdog도 정상적으로 트립되도록 놔둠(이 함수가 watchdog을 영원히
        // 속이지는 않는다는 뜻).
        if((n&15U)==0U)heartbeat();
        deadline=ticks();
        do {
            if(spi(1,0,0x3a,0,&status))return -1;
            if(micros(ticks()-deadline)>8000U)return -1; // 8ms 안에 데이터 준비 안 되면 타임아웃
        }while(!(status&1));
        now=ticks();dt[n]=n?micros(now-previous):0;previous=now; // 이번 샘플과 이전 샘플 사이 간격 기록(첫 샘플은 0)
        // (한국어) 타이밍 검증: 센서가 정상이면 매 샘플 간격이 대략 일정한
        // 범위(여기서는 2800~5200us) 안에 들어와야 함. 이 범위를 벗어난다는
        // 것은 SPI 통신이 씹혔거나, 센서 클럭이 이상하거나, 노이즈로 데이터가
        // 밀린 것일 수 있음 — 이런 경우 "그냥 이상한 값이지만 일단 넘어가자"고
        // 조용히 무시하지 않고, 명시적으로 TIMING_ERROR를 출력하고 이 윈도우
        // 전체를 폐기(-2 반환)하는 방어적 설계. 왜 중요한가: FFT는 "일정한
        // 샘플링 주기"를 전제로 주파수를 계산하기 때문에, 간격이 들쭉날쭉한
        // 데이터를 그대로 FFT에 넣으면 주파수 계산 결과 자체가 조용히
        // 틀려버리고, 그 틀린 결과를 "정상적인 분류 결과"로 오인하게 됨 —
        // 이게 사용자가 눈치채기 가장 어려운 종류의 버그이므로, 여기서
        // 아예 명시적으로 실패 처리해서 "조용한 오류"가 되지 않게 막음.
        if(n && (dt[n]<2800 || dt[n]>5200)) {
            printf("TIMING_ERROR,%u,%lu\r\n",n,(unsigned long)dt[n]);
            return -2; // discarded window, no silent timing gaps
        }
        if(spi(1,1,0x3b,0,&raw))return -1; // 2바이트(two=1) 읽기: 가속도 원시값
        x[n]=(int16_t)(raw<32768?raw:(int32_t)raw-65536); // unsigned 16비트로 온 값을 signed 16비트로 변환(부호 처리)
    }
    return 0;
}
// run_window: 64개 샘플 하나(source가 어디서 온 샘플인지 표시: replay/센서 등)를
// 가지고 (1) ARM이 golden.c로 직접 계산 + (2) FPGA(vibration_core)에게 같은
// 입력을 주고 계산시킨 뒤, 두 결과를 항목별로 하나하나 비교합니다.
//
// (한국어) 왜 "이중 검증"을 하는가: FPGA 회로(fft64_features.v, npu_2pe.v 등)는
// 사람이 손으로 짠 RTL이라 버그 가능성이 늘 있고, 시뮬레이션만으로는 실제
// 보드에서 타이밍이나 부호처리 등이 완전히 같다고 보장할 수 없습니다.
// golden.c(별도 study 사본 참고)는 같은 알고리즘(64점 FFT + 4개 주파수
// 대역 특징 추출 + 2-PE MLP 신경망)을 "하드웨어와 무관한 순수 C 코드"로
// 독립적으로 재구현한 것입니다 — 즉 같은 입력을 넣었을 때 하드웨어와
// 소프트웨어가 정확히 같은 정수 연산 과정을 거쳐 같은 결과를 내야 한다는
// 것이 설계 의도입니다. run_window는 매번 이 둘을 나란히 돌려서, 하나라도
// 어긋나면(match=0) 그 자리에서 바로 알 수 있게 합니다 — "시뮬레이션에서는
// 맞았는데 실제 보드에서는 미묘하게 다르더라"는 종류의 버그를 잡아내는
// 가장 실전적인 방법입니다.
static int run_window(const char *source,const int16_t x[64]) {
    unsigned n;int match=1;inference_result golden;
    uint64_t t=ticks();uint32_t cpu_us,elapsed,status,plcycles,ncycles;
    heartbeat();infer_integer(x,&golden);cpu_us=micros(ticks()-t); // ① ARM이 golden.c로 직접 계산(소프트웨어 정답)
    t=ticks();
    for(n=0;n<64;n++)Xil_Out32(RAM+4*n,(uint16_t)x[n]); // ② 64개 원본 샘플을 BRAM 0번지부터 씀(vibration_core의 입력)
    __asm__ volatile("dsb sy" ::: "memory"); // 메모리 배리어: 위 쓰기들이 실제로 AXI를 거쳐 BRAM에 다 반영된 뒤에야 다음 줄(시작 트리거)이 실행되도록 순서를 강제
    Xil_Out32(CTRL,1); // 0x000 bit0=1 -> start_pulse -> vibration_core 시작
    do {
        status=Xil_In32(CTRL+4);
        if(micros(ticks()-t)>10000U){puts("ERROR,PL timeout");return -1;} // 10ms 안에 안 끝나면 하드웨어 이상으로 간주
    }while(!(status&2)); // bit1=sticky_done이 설 때까지 폴링 대기
    if(status&5){puts("ERROR,PL status");return -1;} // bit0(busy) 또는 bit2(sticky_error)가 서 있으면 비정상
    // ③ FPGA가 BRAM 256번지부터 순서대로 써넣은 결과(vibration_core.v study
    // 사본의 STORE 단계 설명과 정확히 대응: 256~259=features, 260~263=hidden,
    // 264~265=logits, 266=class_id)를 golden.c의 결과와 하나하나 비교.
    for(n=0;n<4;n++) {
        if(Xil_In32(RAM+4*(256+n))!=golden.features[n])match=0;
        if(Xil_In32(RAM+4*(260+n))!=golden.hidden[n])match=0;
    }
    for(n=0;n<2;n++)if((int32_t)Xil_In32(RAM+4*(264+n))!=golden.logits[n])match=0;
    if(Xil_In32(RAM+4*266)!=golden.class_id)match=0;
    elapsed=micros(ticks()-t);plcycles=Xil_In32(CTRL+12);ncycles=Xil_In32(CTRL+16);
    // 결과를 CSV 스타일 한 줄로 출력: source, class, ARM계산시간(us), FPGA
    // 전체클럭수, NPU만의 클럭수, 전체 왕복시간(us), match(1=일치/0=불일치),
    // 이어서 features 4개, hidden 4개, logits 2개
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
    // (한국어) usleep(1)을 그냥 "1마이크로초 대기"를 하려는 게 아니라, xiltimer
    // 라이브러리의 내부 글로벌 타이머를 "처음 한 번은 반드시 호출해서"
    // 초기화시키기 위한 트릭에 가깝습니다 — 이후의 ticks()/micros() 계산이
    // 제대로 동작하려면 이 타이머가 먼저 시작되어 있어야 합니다.
    usleep(1);
    // Simple, explicit BRAM coherency. Benchmark must report that D-cache is disabled.
    // (한국어) D-cache(데이터 캐시)를 꺼두는 이유: ARM이 BRAM에 값을 쓰고
    // FPGA가 그 값을 읽어가는 구조인데, 캐시가 켜져 있으면 ARM이 "쓴 값"이
    // 실제로는 캐시에만 남아있고 아직 실제 BRAM(메모리)에는 반영 안 된
    // 상태일 수 있습니다(write-back 캐시). 그러면 FPGA는 낡은 값을 읽게
    // 되어 하드웨어-소프트웨어 간 데이터가 어긋납니다. 이런 캐시 일관성
    // 문제를 캐시 관리 API로 매번 세심하게 다루는 대신, 아예 D-cache를
    // 통째로 꺼서 "쓰면 바로 실제 메모리에 반영된다"를 단순하고 확실하게
    // 보장하는 방식을 택함(성능보다 정확성과 단순함을 우선한 설계 선택).
    Xil_DCacheDisable();
    puts("V4 Fourier SoC, 100 MHz PL, 64 samples, 2 MAC PEs, D-cache OFF");
    puts("Commands: r=replay pair, x=replay one stored fault, i=init sensor, s=sample+infer, d=dump raw, b=100 replays, f=safety status, t/T=telemetry on/off, p=open-loop ID excitation, g/G=original/candidate PI gains, w/W=anti-windup on/off, o=preset quad position near overflow boundary");
    puts("RESULT columns: source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0..f3,h0..h3,o0,o1");
    heartbeat();heartbeat_time=ticks();
    for(;;) {
        // (한국어) 메인 루프의 heartbeat 패턴: 100ms(HEARTBEAT_US)가 지날
        // 때마다 heartbeat()를 호출해서 PL의 safety_supervisor.v에 있는
        // watchdog 카운터를 계속 리셋시켜줍니다. 만약 이 ARM 애플리케이션이
        // 멈추거나(무한루프에 빠지거나 크래시) heartbeat를 더 이상 못 쏘게
        // 되면, watchdog이 정해진 시간(WATCHDOG_CYCLES) 안에 heartbeat를
        // 못 받아 motor_watchdog_fault를 걸고 모터를 강제로 멈춥니다 — "PS(
        // 소프트웨어)가 죽어도 모터는 반드시 안전하게 정지한다"는 안전
        // 설계의 핵심 축입니다.
        if(micros(ticks()-heartbeat_time)>=HEARTBEAT_US){heartbeat();heartbeat_time=ticks();}
        if(telemetry_streaming && micros(ticks()-telemetry_time)>=TELEMETRY_US){
            send_telemetry_frame();
            telemetry_time=ticks();
        }
        // UART에 수신 데이터가 없으면 1ms 쉬고 루프 처음으로(바쁜 대기를
        // 살짝 늦춰서 CPU를 과하게 태우지 않으면서도 heartbeat/텔레메트리
        // 주기는 계속 체크할 수 있게 함).
        if(!XUartPs_IsReceiveData(STDIN_BASEADDRESS)){usleep(1000);continue;}
        command=XUartPs_RecvByte(STDIN_BASEADDRESS);

        // ==================== UART 명령 처리 (한 글자씩) ====================
        //
        // 'r' — replay pair: 내장된 demo_samples[0](정상 샘플)과
        // demo_samples[1](이상 샘플) 두 개를 순서대로 run_window에 넣어
        // 각각 결과를 출력. 실제 센서 없이도 정상/이상 두 케이스를 한 번에
        // 확인할 수 있는 데모/스모크테스트 명령.
        if(command=='r'){run_window("replay_normal",demo_samples[0]);run_window("replay_fault",demo_samples[1]);}
        // 'x' — replay one stored fault: 이상 샘플(demo_samples[1]) 하나만
        // 1회 재생. 'r'의 절반만 실행하는 축약형(이상 케이스만 빠르게 다시
        // 보고 싶을 때).
        else if(command=='x')run_window("replay_fault_injection",demo_samples[1]);
        // 'b' — 100회 반복 벤치마크: demo_samples[0]/[1]을 번갈아(n%2) 100번
        // 돌려서 통계적으로 안정적인 성능/정확도 데이터를 뽑는 명령. 도중에
        // run_window가 실패(불일치 또는 하드웨어 에러)하면 즉시 break로
        // 중단 — 벤치마크 수백 줄 중 어디서 실패했는지 로그로 바로 드러남.
        else if(command=='b') {
            for(n=0;n<100;n++)if(run_window("benchmark",demo_samples[n%2]))break;
        }
        // 'i' — 센서 초기화: sensor_init()을 호출하고 성공 여부를
        // sensor_ready에 저장, 결과를 출력. 's'/'d' 명령(실제 센서 샘플링)을
        // 쓰기 전에 반드시 먼저 실행해야 하는 명령.
        else if(command=='i'){sensor_ready=(sensor_init()==0);printf("SENSOR_READY,%d\r\n",sensor_ready);}
        // 'f' — 안전상태 출력: print_safety() 호출(warning/derated/latched/
        // watchdog/fault_cause/consecutive/abnormal_total을 한 줄로 출력).
        else if(command=='f')print_safety();
        // t/T are absolute (see the g/G, w/W comment below) so a scripted capture
        // that always sends 't' first lands in a known streaming state regardless
        // of whatever a previous session left it in.
        // (한국어) 't'/'T' — 텔레메트리 켜기/끄기: t=켜기, T=끄기. 이게
        // "토글(누를 때마다 반전)"이 아니라 "절대값(t면 무조건 켜짐)"으로
        // 설계된 이유는, 자동화 스크립트가 이전 세션이 어떤 상태로
        // 끝났는지 모른 채로 항상 't'부터 보내면 무조건 켜진 상태로
        // 시작할 수 있게 하기 위함(상태를 미리 확인할 필요 없이 결정적으로
        // 원하는 상태에 도달). 켤 때는 telemetry_seq를 0으로 리셋하고
        // 시작시각을 새로 기록.
        else if(command=='t'||command=='T') {
            telemetry_streaming=(command=='t');
            if(telemetry_streaming){telemetry_seq=0;telemetry_time=ticks();}
            printf("TELEMETRY,%d\r\n",telemetry_streaming);
        }
        // 'p' — open-loop 시스템 식별용 duty 계단 자동 시퀀스: fourier_motor_control.v의
        // requested_duty 우선순위 로직(study 사본 참고)에서 최우선인
        // open_loop_enable 경로를 이용해, PI 제어기를 거치지 않고 duty를
        // 25%→37.5%→50%→37.5%→25%로 5초씩 순서대로 강제 인가합니다. 목적은
        // "이 duty를 넣으면 실제 속도가 어떻게 반응하는가"를 측정해서
        // plant(모터+부하)의 특성(이득, 시정수, 데드타임)을 알아내는 것 —
        // 그 결과가 위쪽 CANDIDATE_KP_Q16/CANDIDATE_KI_TS_Q16 계산의 근거가
        // 됩니다. 명령 실행 중에는 텔레메트리를 강제로 켜서(원래 꺼져
        // 있었다면 임시로) 전체 응답 과정을 하나의 UART 연결로 캡처할 수
        // 있게 하고, 끝나면 원래 상태로 복원합니다. 0x068 ctrl2 레지스터의
        // bit0(open_loop_enable)을 세우고, 각 스텝마다 0x06c(open_loop_duty)에
        // 값을 쓴 뒤 open_loop_dwell로 5초 대기, 끝나면 duty를 0으로 낮추고
        // open_loop_enable을 다시 꺼서 정상 PI 제어로 복귀합니다.
        else if(command=='p') {
            // Open-loop duty staircase for system identification: 25/37.5/50/37.5/25%,
            // 5 s dwell each, AXI-timed instead of manual switch flips. This command
            // temporarily owns telemetry so one host process can send 'p' and capture
            // the entire response through the same serial connection.
            static const uint16_t steps[5]={1024,1536,2048,1536,1024}; // 13비트 duty 값(8192가 100%이므로 각각 약 12.5/18.75/25/18.75/12.5%... 실제로는 speed_reference 스케일과 별개인 duty 절대값)
            unsigned step_index;uint32_t ctrl2=Xil_In32(CTRL+0x068);
            int telemetry_was_streaming=telemetry_streaming;
            if(!telemetry_streaming){telemetry_streaming=1;telemetry_seq=0;telemetry_time=ticks();}
            Xil_Out32(CTRL+0x068,ctrl2|1U); // bit0=1: open_loop_enable 켜기(기존 anti_windup 비트는 보존)
            puts("OPEN_LOOP_START");
            for(step_index=0;step_index<5;step_index++) {
                Xil_Out32(CTRL+0x06c,(uint32_t)steps[step_index]); // 이번 단계의 duty를 강제 인가
                printf("OPEN_LOOP_STEP,%u,%u\r\n",step_index,(unsigned)steps[step_index]);
                open_loop_dwell(5000U); // 5초간 유지(그 사이 heartbeat/텔레메트리는 계속 서비스됨)
            }
            Xil_Out32(CTRL+0x06c,0U); // duty를 0으로 낮춰 모터를 세운 뒤
            ctrl2=Xil_In32(CTRL+0x068);
            Xil_Out32(CTRL+0x068,ctrl2&~1U); // open_loop_enable을 다시 끔 -> PI 폐루프 제어로 복귀
            if(!telemetry_was_streaming)telemetry_streaming=0; // 텔레메트리를 원래 상태로 복원
            puts("OPEN_LOOP_DONE");
        }
        // g/G and w/W are absolute, not toggles: a scripted A/B comparison run
        // (capture tool sends one of these via --send-command) must land in a known
        // state without first reading back the previous one.
        //
        // (한국어) 'g'/'G' — 원래/식별된(후보) PI 게인으로 전환: g=원래 고정
        // 튜닝값(ORIGINAL_KP_Q16/ORIGINAL_KI_TS_Q16), G=시스템 식별로 얻은
        // 후보값(CANDIDATE_KP_Q16/CANDIDATE_KI_TS_Q16)을 0x070/0x074에 씀.
        // 't'/'T'와 마찬가지로 절대값 지정 방식이라 스크립트가 이전 상태를
        // 몰라도 항상 원하는 게인으로 정확히 전환 가능.
        else if(command=='g'||command=='G') {
            candidate_gains_active=(command=='G');
            Xil_Out32(CTRL+0x070,candidate_gains_active?CANDIDATE_KP_Q16:ORIGINAL_KP_Q16);
            Xil_Out32(CTRL+0x074,candidate_gains_active?CANDIDATE_KI_TS_Q16:ORIGINAL_KI_TS_Q16);
            printf("GAINS,%s,kp_q16,%u,ki_ts_q16,%u\r\n",
                candidate_gains_active?"candidate":"original",
                (unsigned)(candidate_gains_active?CANDIDATE_KP_Q16:ORIGINAL_KP_Q16),
                (unsigned)(candidate_gains_active?CANDIDATE_KI_TS_Q16:ORIGINAL_KI_TS_Q16));
        }
        // 'w'/'W' — anti-windup 켜기/끄기: w=켜기, W=끄기. 0x068의 bit1을
        // 세우거나 내림(bit0인 open_loop_enable은 건드리지 않도록 기존 값을
        // 먼저 읽어서 유지). anti-windup은 PI 제어기가 출력이 포화(saturate)된
        // 상태에서 적분항이 계속 쌓여 나중에 과도한 오버슈트를 일으키는
        // 현상을 막는 기법 — 이걸 끄면 그 현상이 어떻게 나타나는지 실험적으로
        // 비교해볼 수 있음.
        else if(command=='w'||command=='W') {
            uint32_t ctrl2=Xil_In32(CTRL+0x068);
            uint32_t enabled_now=(command=='w');
            ctrl2=enabled_now?(ctrl2|2U):(ctrl2&~2U);
            Xil_Out32(CTRL+0x068,ctrl2);
            printf("ANTI_WINDUP,%u\r\n",(unsigned)enabled_now);
        }
        // 'o' — quadrature position을 오버플로우 경계 직전으로 프리셋:
        // axi_vibration_top.v의 0x07c(RW로 확장된 quad_position)에
        // 0x7ffffffe(=2^31-2, +2^31-1 경계 바로 두 칸 앞)를 씀. 목적은
        // 오버플로우 안전장치(quad_overflow_fault)가 실제로 정상 동작하는지
        // "진짜 엔코더 펄스 수십억 개를 기다리지 않고" 손으로 엔코더를 살짝
        // 두 번만 돌려도 즉시 재현해서 확인하는 실물 테스트용 진단 명령
        // (axi_vibration_top.v study 사본의 0x07c 설명과 대응).
        else if(command=='o') {
            // Overflow-fault diagnostic: preset the quadrature position
            // register to one step short of the +-2^31 boundary (0x07c is
            // read-write for exactly this -- see encoder_quadrature.v). Two
            // real forward encoder edges from here latch overflow_fault
            // without needing billions of genuine pulses.
            Xil_Out32(CTRL+0x07c,0x7ffffffeU);
            printf("QUAD_POSITION_PRESET,0x7ffffffe\r\n");
        }
        // 's'/'d' — 실제 센서에서 샘플 수집: 's'=수집 후 바로 run_window로
        // 추론까지 실행(정상/이상 판정), 'd'=수집한 원시 샘플 64개를 값과
        // 타이밍(dt)까지 그대로 덤프(추론 없이 원시 데이터만 확인하고 싶을
        // 때, 또는 오프라인 분석용). 둘 다 sensor_ready가 아니면(즉 'i'로
        // 초기화 안 했으면) 에러 메시지를 내고 그냥 넘어감(continue). acquire()가
        // 실패(타이밍 에러 등)해도 마찬가지로 에러를 출력하고 넘어감 — 잘못된
        // 데이터로 추론을 강행하지 않음.
        else if(command=='s'||command=='d') {
            int result;
            if(!sensor_ready){puts("ERROR,run i first");continue;}
            result=acquire(samples,dt);if(result){printf("ERROR,capture,%d\r\n",result);continue;}
            if(command=='s')run_window("sensor",samples);
            else for(n=0;n<64;n++)printf("SAMPLE,%u,%d,%lu\r\n",n,samples[n],(unsigned long)dt[n]);
        }
    }
}
