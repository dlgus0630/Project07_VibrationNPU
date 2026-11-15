#ifndef MOCK_BSP_H
#define MOCK_BSP_H

/* PC 검사 전용 BSP 대역. 실제 펌웨어 빌드에는 포함하지 않는다. */
#include <stdint.h>
#include <stddef.h>

typedef uint64_t XTime;
#define COUNTS_PER_SECOND 1000000U
#define XPAR_XUARTPS_0_BASEADDR 0xe0000000U

void XTime_GetTime(XTime *time);
uint32_t Xil_In32(uintptr_t address);
void Xil_Out32(uintptr_t address, uint32_t value);
void Xil_DCacheDisable(void);
int usleep(unsigned int microseconds);
int XUartPs_IsReceiveData(uintptr_t address);
unsigned char XUartPs_RecvByte(uintptr_t address);
void XUartPs_SendByte(uintptr_t address, unsigned char value);
void mock_memory_barrier(void);
int firmware_entry(void);

#endif
