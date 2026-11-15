/*------------------------------------------------------------
 * ARM 앱 진입점 : 초기화 → heartbeat/telemetry 처리 → UART 명령 분기
 * SPI/센서, 추론, 텔레메트리, 모터 명령은 각 기능 파일에 둔다.
 * 명령 문자와 출력 문자열은 기존 수집 도구의 계약을 유지한다.
 *------------------------------------------------------------*/
#include <stdint.h>
#include <stdio.h>
#include "app_inference.h"
#include "app_platform.h"
#include "app_registers.h"
#include "app_telemetry.h"
#include "motor_commands.h"
#include "sensor_spi.h"
#include "model_data.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xuartps_hw.h"

#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif

typedef struct {
    int sensor_ready;
    int16_t samples[64];
    uint32_t intervals_us[64];
} application_state;

static void print_startup(void)
{
    puts("V4 Fourier SoC, 100 MHz PL, 64 samples, 2 MAC PEs, D-cache OFF");
    puts("Commands: r=replay pair, x=replay one stored fault, i=init sensor, "
         "s=sample+infer, d=dump raw, b=100 replays, f=safety status, "
         "t/T=telemetry on/off, p=open-loop ID excitation, "
         "g/G=original/candidate PI gains, w/W=anti-windup on/off, "
         "o=preset quad position near overflow boundary");
    puts("RESULT columns: source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0..f3,h0..h3,o0,o1");
}

static void replay_benchmark(void)
{
    unsigned iteration;

    for (iteration = 0; iteration < 100; iteration++) {
        int result = inference_run_window("benchmark", demo_samples[iteration % 2]);

        if (result) {
            break;
        }
    }
}

static void acquire_and_process(unsigned char command, application_state *state)
{
    unsigned sample_index;
    int result;

    if (!state->sensor_ready) {
        puts("ERROR,run i first");
        return;
    }
    result = sensor_acquire_window(state->samples, state->intervals_us);
    if (result) {
        printf("ERROR,capture,%d\r\n", result);
        return;
    }
    if (command == 's') {
        inference_run_window("sensor", state->samples);
    } else {
        for (sample_index = 0; sample_index < 64; sample_index++) {
            printf("SAMPLE,%u,%d,%lu\r\n", sample_index, state->samples[sample_index],
                   (unsigned long)state->intervals_us[sample_index]);
        }
    }
}

static void execute_command(unsigned char command, application_state *state)
{
    switch (command) {
    case 'r':
        inference_run_window("replay_normal", demo_samples[0]);
        inference_run_window("replay_fault", demo_samples[1]);
        break;
    case 'x':
        inference_run_window("replay_fault_injection", demo_samples[1]);
        break;
    case 'b':
        replay_benchmark();
        break;
    case 'i':
        state->sensor_ready = sensor_initialize() == 0;
        printf("SENSOR_READY,%d\r\n", state->sensor_ready);
        break;
    case 'f':
        motor_print_safety();
        break;
    case 't':
    case 'T':
        telemetry_set_streaming(command == 't');
        printf("TELEMETRY,%d\r\n", telemetry_is_streaming());
        break;
    case 'p':
        motor_run_open_loop_steps();
        break;
    case 'g':
    case 'G':
        motor_set_gains(command == 'G');
        break;
    case 'w':
    case 'W':
        motor_set_anti_windup(command == 'w');
        break;
    case 'o':
        motor_preset_quad_position();
        break;
    case 's':
    case 'd':
        acquire_and_process(command, state);
        break;
    default:
        break;
    }
}

int main(void)
{
    application_state state;
    uint64_t heartbeat_time;

    state.sensor_ready = 0;
    /* 첫 sleep이 BSP의 Cortex-A9 global timer를 시작한다. */
    usleep(1);
    Xil_DCacheDisable();
    print_startup();
    platform_heartbeat();
    heartbeat_time = platform_ticks();

    for (;;) {
        unsigned char command;

        if (platform_microseconds(platform_ticks() - heartbeat_time) >= HEARTBEAT_INTERVAL_US) {
            platform_heartbeat();
            heartbeat_time = platform_ticks();
        }
        telemetry_poll();
        if (!XUartPs_IsReceiveData(STDIN_BASEADDRESS)) {
            usleep(1000);
            continue;
        }
        command = XUartPs_RecvByte(STDIN_BASEADDRESS);
        execute_command(command, &state);
    }
}
