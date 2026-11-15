/*------------------------------------------------------------
 * PC 검증 : 실제 펌웨어의 main 루프를 가상 BSP에 연결
 * 비교 : 원본/수정본의 MMIO 순서·값, UART 바이트와 출력 문자열
 * 시간은 결정적인 시험용 시간이며 실측 성능으로 사용하지 않는다.
 * 명령이 끝나면 longjmp로 무한 main 루프를 시험 드라이버에 돌려준다.
 *------------------------------------------------------------*/
#include <inttypes.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bsp_mock/mock_bsp.h"
#include "golden.h"

static jmp_buf finish_test;
static uint64_t timer_us;
static uint32_t registers[64];
static uint32_t sample_ram[1024];
static uint8_t sensor_registers[128];
static uint32_t spi_status;
static const char *scenario;
static const char *commands;
static size_t command_index;
static unsigned idle_polls;
static unsigned sensor_sample_index;
static uint64_t next_sample_time;
static int accelerator_started;

void XTime_GetTime(XTime *time)
{
    timer_us += 100;
    *time = timer_us;
}

int usleep(unsigned int microseconds)
{
    timer_us += microseconds;
    return 0;
}

void Xil_DCacheDisable(void)
{
    puts("MOCK,DCACHE_DISABLE");
}

void mock_memory_barrier(void)
{
    puts("MOCK,DSB_SY");
}

static void complete_accelerator(void)
{
    int16_t samples[64];
    inference_result result;
    unsigned index;

    for (index = 0; index < 64; index++) {
        samples[index] = (int16_t)sample_ram[index];
    }
    infer_integer(samples, &result);
    for (index = 0; index < 4; index++) {
        sample_ram[256 + index] = result.features[index];
        sample_ram[260 + index] = result.hidden[index];
    }
    for (index = 0; index < 2; index++) {
        sample_ram[264 + index] = (uint32_t)(int32_t)result.logits[index];
    }
    sample_ram[266] = result.class_id;
    if (strcmp(scenario, "result_mismatch") == 0) {
        sample_ram[256] ^= 1U;
    }
}

static void execute_spi(uint32_t command)
{
    unsigned address = command & 0x7fU;
    unsigned read_operation = command & 0x80U;
    unsigned two_bytes = command & 0x100U;
    unsigned data = (command >> 16) & 255U;
    uint16_t reply = 0;

    if (!read_operation) {
        sensor_registers[address] = (uint8_t)data;
    } else if (address == 0x3a) {
        if (strcmp(scenario, "data_ready_timeout") != 0 && timer_us >= next_sample_time) {
            reply = 1;
        }
    } else if (address == 0x3b && two_bytes) {
        reply = (uint16_t)(16384 + (int)(sensor_sample_index % 17) - 8);
        if (strcmp(scenario, "sensor_signed_samples") == 0) {
            static const int16_t signed_samples[5] = {-32768, -1, 0, 1, 32767};

            reply = (uint16_t)signed_samples[sensor_sample_index % 5];
        }
        sensor_sample_index++;
        next_sample_time = timer_us + 4000;
        if (strcmp(scenario, "sample_interval_error") == 0) {
            next_sample_time = timer_us + 6000;
        }
    } else {
        reply = sensor_registers[address];
        if (strcmp(scenario, "configuration_mismatch") == 0 && address == 0x1d) {
            reply ^= 1U;
        }
    }
    spi_status = (1U << 17) | reply;
    if (strcmp(scenario, "spi_timeout") == 0) {
        spi_status = 1U << 16;
    }
}

uint32_t Xil_In32(uintptr_t address)
{
    uint32_t value;

    if (address >= 0x40000000U && address < 0x40001000U) {
        value = sample_ram[(address - 0x40000000U) / 4];
    } else if (address == 0x43c00044U) {
        value = spi_status;
    } else if (address == 0x43c00004U && accelerator_started) {
        value = 2;
        if (strcmp(scenario, "pl_timeout") == 0) {
            value = 1;
        } else if (strcmp(scenario, "pl_status_error") == 0) {
            value = 6;
        }
    } else {
        value = registers[(address - 0x43c00000U) / 4];
    }
    printf("MOCK,READ,%08" PRIxPTR ",%08" PRIx32 "\n", address, value);
    return value;
}

void Xil_Out32(uintptr_t address, uint32_t value)
{
    printf("MOCK,WRITE,%08" PRIxPTR ",%08" PRIx32 "\n", address, value);
    if (address >= 0x40000000U && address < 0x40001000U) {
        sample_ram[(address - 0x40000000U) / 4] = value;
        return;
    }
    registers[(address - 0x43c00000U) / 4] = value;
    if (address == 0x43c00040U) {
        execute_spi(value);
    } else if (address == 0x43c00000U) {
        accelerator_started = 1;
        complete_accelerator();
    }
}

int XUartPs_IsReceiveData(uintptr_t address)
{
    (void)address;
    if (commands[command_index] == '\0') {
        longjmp(finish_test, 1);
    }
    idle_polls++;
    return idle_polls >= 20;
}

unsigned char XUartPs_RecvByte(uintptr_t address)
{
    (void)address;
    idle_polls = 0;
    return (unsigned char)commands[command_index++];
}

void XUartPs_SendByte(uintptr_t address, unsigned char value)
{
    printf("MOCK,UART,%08" PRIxPTR ",%02x\n", address, value);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        return 2;
    }
    scenario = argv[1];
    commands = argv[2];
    sensor_registers[0x75] = 0x70;
    if (strcmp(scenario, "sensor_9250") == 0) {
        sensor_registers[0x75] = 0x71;
    } else if (strcmp(scenario, "unknown_sensor") == 0) {
        sensor_registers[0x75] = 0xff;
    }
    registers[0x00c / 4] = 1234;
    registers[0x010 / 4] = 18;
    registers[0x004 / 4] = 0x78;
    registers[0x04c / 4] = 0x00120c03;
    registers[0x050 / 4] = 2048;
    registers[0x054 / 4] = 1987;
    registers[0x058 / 4] = 1701;
    registers[0x05c / 4] = (uint32_t)-123456;
    registers[0x060 / 4] = 1;
    registers[0x068 / 4] = 2;
    if (setjmp(finish_test) == 0) {
        firmware_entry();
    }
    printf("MOCK,FINAL_TIME_US,%" PRIu64 "\n", timer_us);
    return 0;
}
