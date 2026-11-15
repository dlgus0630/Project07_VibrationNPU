/*------------------------------------------------------------
 * 텔레메트리 : PL 레지스터 읽기 → 16바이트 프레임 → UART 전송
 * 바이트 : A5 5A | seq 2 | target 2 | speed 2 | duty 2 |
 *          integral 4 | flags 1 | XOR checksum 1
 * 모든 다중 바이트 값은 기존처럼 little endian으로 보낸다.
 *------------------------------------------------------------*/
#include "app_telemetry.h"
#include "app_platform.h"
#include "app_registers.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xuartps_hw.h"

#ifndef STDOUT_BASEADDRESS
#define STDOUT_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#endif

static int streaming_enabled = 0;
static uint16_t sequence_number = 0;
static uint64_t last_frame_time;

static void store_u16_le(uint8_t *destination, uint32_t value)
{
    destination[0] = (uint8_t)(value & 255U);
    destination[1] = (uint8_t)((value >> 8) & 255U);
}

static void send_telemetry_frame(void)
{
    uint8_t frame[16];
    uint8_t checksum = 0;
    unsigned byte_index;
    uint32_t reference = Xil_In32(CONTROL_BASE_ADDRESS + REG_SPEED_REFERENCE);
    uint32_t measured = Xil_In32(CONTROL_BASE_ADDRESS + REG_SPEED_MEASURED);
    uint32_t duty = Xil_In32(CONTROL_BASE_ADDRESS + REG_MOTOR_DUTY);
    uint32_t integral = Xil_In32(CONTROL_BASE_ADDRESS + REG_PID_INTEGRAL);
    uint32_t status = Xil_In32(CONTROL_BASE_ADDRESS + REG_STATUS);
    uint32_t enabled = Xil_In32(CONTROL_BASE_ADDRESS + REG_MOTOR_ARMED) & 1U;
    uint32_t fault = (status >> 3) & 1U;

    reference &= DUTY_VALUE_MASK;
    measured &= DUTY_VALUE_MASK;
    duty &= DUTY_VALUE_MASK;

    frame[0] = 0xa5;
    frame[1] = 0x5a;
    store_u16_le(&frame[2], sequence_number);
    store_u16_le(&frame[4], reference);
    store_u16_le(&frame[6], measured);
    store_u16_le(&frame[8], duty);
    store_u16_le(&frame[10], integral);
    store_u16_le(&frame[12], integral >> 16);

    /* 기존 프레임의 arm/enable 비트는 같은 enabled 값을 사용한다. */
    frame[14] = (uint8_t)(enabled | (fault << 1) | (enabled << 2));
    for (byte_index = 0; byte_index < 15; byte_index++) {
        checksum ^= frame[byte_index];
    }
    frame[15] = checksum;

    for (byte_index = 0; byte_index < 16; byte_index++) {
        XUartPs_SendByte(STDOUT_BASEADDRESS, frame[byte_index]);
    }
    sequence_number++;
}

int telemetry_is_streaming(void)
{
    return streaming_enabled;
}

void telemetry_set_streaming(int enabled)
{
    streaming_enabled = enabled;
    if (streaming_enabled) {
        sequence_number = 0;
        last_frame_time = platform_ticks();
    }
}

/* 메인 루프 : 전송이 끝난 시각을 다음 주기의 기준으로 삼는다. */
void telemetry_poll(void)
{
    if (streaming_enabled) {
        uint64_t elapsed = platform_ticks() - last_frame_time;

        if (platform_microseconds(elapsed) >= TELEMETRY_INTERVAL_US) {
            send_telemetry_frame();
            last_frame_time = platform_ticks();
        }
    }
}

/* open-loop 대기 : 호출자가 읽은 now를 그대로 기준으로 사용한다. */
void telemetry_poll_at(uint64_t now)
{
    if (streaming_enabled) {
        uint64_t elapsed = now - last_frame_time;

        if (platform_microseconds(elapsed) >= TELEMETRY_INTERVAL_US) {
            send_telemetry_frame();
            last_frame_time = now;
        }
    }
}
