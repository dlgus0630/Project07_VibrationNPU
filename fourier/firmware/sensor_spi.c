/*------------------------------------------------------------
 * 센서 통신 : SPI 명령 조립 → 완료 대기 → 센서 설정/64개 수집
 * 반환 : 0 성공, -1 통신/설정 오류, -2 샘플 간격 오류
 * 주소, 쓰기 순서, timeout과 간격 판정은 기존 펌웨어를 유지한다.
 *------------------------------------------------------------*/
#include <stdio.h>
#include "sensor_spi.h"
#include "app_platform.h"
#include "app_registers.h"
#include "sleep.h"
#include "xil_io.h"

#define SPI_COMMAND_START 0x80000000U
#define SPI_COMMAND_READ 0x00000080U
#define SPI_COMMAND_TWO_BYTES 0x00000100U
#define SPI_STATUS_BUSY (1U << 16)
#define SPI_STATUS_DONE (1U << 17)
#define SPI_TIMEOUT_US 5000U
#define DATA_READY_TIMEOUT_US 8000U

enum {
    SENSOR_SAMPLE_DIVIDER = 0x19,
    SENSOR_GYRO_FILTER = 0x1a,
    SENSOR_GYRO_RANGE = 0x1b,
    SENSOR_ACCEL_RANGE = 0x1c,
    SENSOR_ACCEL_FILTER = 0x1d,
    SENSOR_INTERRUPT_PIN = 0x37,
    SENSOR_INTERRUPT_ENABLE = 0x38,
    SENSOR_INTERRUPT_STATUS = 0x3a,
    SENSOR_ACCEL_X_HIGH = 0x3b,
    SENSOR_USER_CONTROL = 0x6a,
    SENSOR_POWER_1 = 0x6b,
    SENSOR_POWER_2 = 0x6c,
    SENSOR_WHO_AM_I = 0x75
};

static uint32_t build_spi_command(int read_operation, int two_bytes,
                                  uint8_t address, uint8_t data)
{
    uint32_t command = SPI_COMMAND_START;

    command |= (uint32_t)data << 16;
    command |= address;
    if (two_bytes) {
        command |= SPI_COMMAND_TWO_BYTES;
    }
    if (read_operation) {
        command |= SPI_COMMAND_READ;
    }
    return command;
}

static int spi_transfer(int read_operation, int two_bytes, uint8_t address,
                        uint8_t data, uint16_t *result)
{
    uint64_t start_time = platform_ticks();
    uint32_t command = build_spi_command(read_operation, two_bytes, address, data);
    uint32_t status;
    int transfer_done;
    int transfer_busy;

    Xil_Out32(CONTROL_BASE_ADDRESS + REG_SPI_COMMAND, command);
    do {
        status = Xil_In32(CONTROL_BASE_ADDRESS + REG_SPI_STATUS);
        /* 완료 비트를 읽은 회차에서도 원본처럼 timeout을 먼저 확인한다. */
        if (platform_microseconds(platform_ticks() - start_time) > SPI_TIMEOUT_US) {
            return -1;
        }
        transfer_done = (status & SPI_STATUS_DONE) != 0;
        transfer_busy = (status & SPI_STATUS_BUSY) != 0;
    } while (!transfer_done || transfer_busy);

    *result = (uint16_t)status;
    return 0;
}

static int sensor_write_register(uint8_t address, uint8_t value)
{
    uint16_t ignored;

    return spi_transfer(0, 0, address, value, &ignored);
}

static int sensor_check_register(uint8_t address, uint16_t expected)
{
    uint16_t actual;

    if (spi_transfer(1, 0, address, 0, &actual)) {
        return -1;
    }
    if (actual != expected) {
        return -1;
    }
    return 0;
}

static int configure_sensor(uint8_t sample_divider)
{
    /* 설정표를 위에서 아래 순서로 쓰며, 첫 실패에서 즉시 중단한다. */
    const uint8_t settings[][2] = {
        {SENSOR_USER_CONTROL, 0x10},
        {SENSOR_POWER_2, 0x00},
        {SENSOR_SAMPLE_DIVIDER, sample_divider},
        {SENSOR_GYRO_RANGE, 0x00},
        {SENSOR_GYRO_FILTER, 0x01},
        {SENSOR_ACCEL_RANGE, 0x00},
        {SENSOR_ACCEL_FILTER, 0x01},
        {SENSOR_INTERRUPT_PIN, 0x00},
        {SENSOR_INTERRUPT_ENABLE, 0x01}
    };
    unsigned setting_index;

    for (setting_index = 0; setting_index < sizeof settings / sizeof settings[0]; setting_index++) {
        uint8_t address = settings[setting_index][0];
        uint8_t value = settings[setting_index][1];

        if (sensor_write_register(address, value)) {
            return -1;
        }
    }
    return 0;
}

int sensor_initialize(void)
{
    uint16_t identity;
    uint8_t sample_divider;

    if (spi_transfer(1, 0, SENSOR_WHO_AM_I, 0, &identity)) {
        return -1;
    }
    printf("WHO_AM_I,0x%02x,supported,0x70|0x71\r\n", identity);
    if (identity == 0x70) {
        puts("SENSOR_MODEL,MPU-6500");
        sample_divider = 3;
    } else if (identity == 0x71) {
        puts("SENSOR_MODEL,MPU-9250");
        sample_divider = 0;
    } else {
        return -1;
    }

    /* 센서 리셋 → 100 ms → 클럭 선택 → 100 ms. */
    if (sensor_write_register(SENSOR_POWER_1, 0x80)) {
        return -1;
    }
    platform_heartbeat();
    usleep(100000);
    if (sensor_write_register(SENSOR_POWER_1, 0x01)) {
        return -1;
    }
    platform_heartbeat();
    usleep(100000);

    if (configure_sensor(sample_divider)) {
        return -1;
    }
    usleep(20000);
    if (sensor_check_register(SENSOR_ACCEL_RANGE, 0)) {
        return -1;
    }
    if (sensor_check_register(SENSOR_ACCEL_FILTER, 1)) {
        return -1;
    }
    if (sensor_check_register(SENSOR_SAMPLE_DIVIDER, sample_divider)) {
        return -1;
    }
    return 0;
}

static int wait_for_data_ready(void)
{
    uint64_t deadline = platform_ticks();
    uint16_t status;

    do {
        if (spi_transfer(1, 0, SENSOR_INTERRUPT_STATUS, 0, &status)) {
            return -1;
        }
        if (platform_microseconds(platform_ticks() - deadline) > DATA_READY_TIMEOUT_US) {
            return -1;
        }
    } while ((status & 1U) == 0);
    return 0;
}

int sensor_acquire_window(int16_t samples[64], uint32_t intervals_us[64])
{
    uint64_t previous_time = 0;
    uint16_t status;
    unsigned sample_index;

    /* 직전 윈도우에서 남은 data-ready 상태를 먼저 읽어 지운다. */
    if (spi_transfer(1, 0, SENSOR_INTERRUPT_STATUS, 0, &status)) {
        return -1;
    }
    for (sample_index = 0; sample_index < 64; sample_index++) {
        uint64_t now;
        uint16_t raw;
        int32_t signed_sample;

        if ((sample_index & 15U) == 0) {
            platform_heartbeat();
        }
        if (wait_for_data_ready()) {
            return -1;
        }

        now = platform_ticks();
        if (sample_index == 0) {
            intervals_us[sample_index] = 0;
        } else {
            intervals_us[sample_index] = platform_microseconds(now - previous_time);
        }
        previous_time = now;

        if (sample_index > 0) {
            uint32_t interval = intervals_us[sample_index];

            if (interval < 2800 || interval > 5200) {
                printf("TIMING_ERROR,%u,%lu\r\n", sample_index, (unsigned long)interval);
                return -2;
            }
        }
        if (spi_transfer(1, 1, SENSOR_ACCEL_X_HIGH, 0, &raw)) {
            return -1;
        }
        signed_sample = raw;
        if (raw >= 32768) {
            signed_sample -= 65536;
        }
        samples[sample_index] = (int16_t)signed_sample;
    }
    return 0;
}
