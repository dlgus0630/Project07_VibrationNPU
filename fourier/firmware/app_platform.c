/*------------------------------------------------------------
 * 플랫폼 공통 기능 : 타이머 읽기, 시간 환산, PS heartbeat
 * 실제 타이머 주파수는 BSP의 COUNTS_PER_SECOND를 사용한다.
 *------------------------------------------------------------*/
#include "app_platform.h"
#include "app_registers.h"
#include "xil_io.h"
#include "xiltimer.h"

uint64_t platform_ticks(void)
{
    XTime current_ticks;

    XTime_GetTime(&current_ticks);
    return (uint64_t)current_ticks;
}

uint32_t platform_microseconds(uint64_t elapsed_ticks)
{
    uint64_t elapsed_microseconds = elapsed_ticks * 1000000U / COUNTS_PER_SECOND;

    return (uint32_t)elapsed_microseconds;
}

void platform_heartbeat(void)
{
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_HEARTBEAT, 1U);
}
