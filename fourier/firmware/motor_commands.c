/*------------------------------------------------------------
 * 모터 명령 : 안전 상태 읽기, 기존 open-loop 계단, 게인/적분 설정
 * 실험에 사용했던 명령 문자, 수치와 UART 출력 형식을 유지한다.
 *------------------------------------------------------------*/
#include <stdint.h>
#include <stdio.h>
#include "motor_commands.h"
#include "app_platform.h"
#include "app_registers.h"
#include "app_telemetry.h"
#include "sleep.h"
#include "xil_io.h"

#define ORIGINAL_KP_Q16 58982U
#define ORIGINAL_KI_TS_Q16 3932U
/* 기존 IDENTIFY_MOTOR.m 결과로 저장된 비교용 게인. */
#define CANDIDATE_KP_Q16 91486U
#define CANDIDATE_KI_TS_Q16 1477U

void motor_print_safety(void)
{
    uint32_t status = Xil_In32(CONTROL_BASE_ADDRESS + REG_STATUS);
    uint32_t detail = Xil_In32(CONTROL_BASE_ADDRESS + REG_SAFETY_DETAIL);
    unsigned long warning = (status >> 4) & 1U;
    unsigned long derated = (status >> 5) & 1U;
    unsigned long latched = (status >> 3) & 1U;
    unsigned long watchdog = (status >> 6) & 1U;
    unsigned long cause = (detail >> 10) & 3U;
    unsigned long consecutive = detail & 255U;
    unsigned long abnormal_total = detail >> 16;

    printf("SAFETY,warning,%lu,derated,%lu,latched,%lu,watchdog,%lu,"
           "cause,%lu,consecutive,%lu,abnormal_total,%lu\r\n",
           warning, derated, latched, watchdog, cause, consecutive, abnormal_total);
}

static void open_loop_dwell(uint32_t milliseconds)
{
    uint64_t start_time = platform_ticks();
    uint64_t heartbeat_time = start_time;

    while (platform_microseconds(platform_ticks() - start_time) < milliseconds * 1000U) {
        uint64_t now = platform_ticks();

        if (platform_microseconds(now - heartbeat_time) >= HEARTBEAT_INTERVAL_US) {
            platform_heartbeat();
            heartbeat_time = now;
        }
        telemetry_poll_at(now);
        usleep(500);
    }
}

void motor_run_open_loop_steps(void)
{
    static const uint16_t duty_steps[5] = {1024, 1536, 2048, 1536, 1024};
    unsigned step_index;
    uint32_t control = Xil_In32(CONTROL_BASE_ADDRESS + REG_CONTROL_2);
    int telemetry_was_streaming = telemetry_is_streaming();

    if (!telemetry_was_streaming) {
        telemetry_set_streaming(1);
    }
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_CONTROL_2, control | CONTROL_2_OPEN_LOOP);
    puts("OPEN_LOOP_START");
    for (step_index = 0; step_index < 5; step_index++) {
        Xil_Out32(CONTROL_BASE_ADDRESS + REG_OPEN_LOOP_DUTY, duty_steps[step_index]);
        printf("OPEN_LOOP_STEP,%u,%u\r\n", step_index, (unsigned)duty_steps[step_index]);
        open_loop_dwell(5000U);
    }

    Xil_Out32(CONTROL_BASE_ADDRESS + REG_OPEN_LOOP_DUTY, 0U);
    control = Xil_In32(CONTROL_BASE_ADDRESS + REG_CONTROL_2);
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_CONTROL_2, control & ~CONTROL_2_OPEN_LOOP);
    if (!telemetry_was_streaming) {
        telemetry_set_streaming(0);
    }
    puts("OPEN_LOOP_DONE");
}

void motor_set_gains(int use_candidate)
{
    uint32_t kp;
    uint32_t ki_ts;
    const char *name;

    if (use_candidate) {
        kp = CANDIDATE_KP_Q16;
        ki_ts = CANDIDATE_KI_TS_Q16;
        name = "candidate";
    } else {
        kp = ORIGINAL_KP_Q16;
        ki_ts = ORIGINAL_KI_TS_Q16;
        name = "original";
    }
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_KP_GAIN, kp);
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_KI_GAIN, ki_ts);
    printf("GAINS,%s,kp_q16,%u,ki_ts_q16,%u\r\n", name, (unsigned)kp, (unsigned)ki_ts);
}

void motor_set_anti_windup(int enabled)
{
    uint32_t control = Xil_In32(CONTROL_BASE_ADDRESS + REG_CONTROL_2);

    if (enabled) {
        control |= CONTROL_2_ANTI_WINDUP;
    } else {
        control &= ~CONTROL_2_ANTI_WINDUP;
    }
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_CONTROL_2, control);
    printf("ANTI_WINDUP,%u\r\n", (unsigned)enabled);
}

void motor_preset_quad_position(void)
{
    /* 기존 overflow 진단 명령 : INT32 최댓값 두 단계 전 위치. */
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_QUAD_POSITION, 0x7ffffffeU);
    printf("QUAD_POSITION_PRESET,0x7ffffffe\r\n");
}
