/*------------------------------------------------------------
 * 추론 실행 : C 기준 계산 → BRAM 입력 → PL 실행 → 결과 비교/출력
 * BRAM word 256..259 특징, 260..263 은닉, 264..265 점수, 266 클래스
 * UART RESULT 열 순서와 시간 측정 시작/종료 위치를 유지한다.
 *------------------------------------------------------------*/
#include <stdio.h>
#include "app_inference.h"
#include "app_platform.h"
#include "app_registers.h"
#include "golden.h"
#include "xil_io.h"

static void write_input_samples(const int16_t samples[64])
{
    unsigned sample_index;

    for (sample_index = 0; sample_index < 64; sample_index++) {
        uint32_t address = SAMPLE_RAM_BASE_ADDRESS + 4 * sample_index;

        Xil_Out32(address, (uint16_t)samples[sample_index]);
    }
    /* 모든 입력 쓰기가 끝난 후 START를 보낸다. */
    __asm__ volatile("dsb sy" ::: "memory");
}

static int wait_for_accelerator(uint64_t start_time)
{
    uint32_t status;

    do {
        status = Xil_In32(CONTROL_BASE_ADDRESS + REG_STATUS);
        if (platform_microseconds(platform_ticks() - start_time) > 10000U) {
            puts("ERROR,PL timeout");
            return -1;
        }
    } while ((status & STATUS_DONE) == 0);

    if ((status & (STATUS_BUSY | STATUS_ERROR)) != 0) {
        puts("ERROR,PL status");
        return -1;
    }
    return 0;
}

static int compare_accelerator_result(const inference_result *golden)
{
    unsigned channel;
    int match = 1;

    /* 원본과 같은 읽기 순서 : 특징/은닉 쌍 → 점수 → 클래스. */
    for (channel = 0; channel < 4; channel++) {
        uint32_t feature_address = SAMPLE_RAM_BASE_ADDRESS + 4 * (256 + channel);
        uint32_t hidden_address = SAMPLE_RAM_BASE_ADDRESS + 4 * (260 + channel);

        if (Xil_In32(feature_address) != golden->features[channel]) {
            match = 0;
        }
        if (Xil_In32(hidden_address) != golden->hidden[channel]) {
            match = 0;
        }
    }
    for (channel = 0; channel < 2; channel++) {
        uint32_t logit_address = SAMPLE_RAM_BASE_ADDRESS + 4 * (264 + channel);

        if ((int32_t)Xil_In32(logit_address) != golden->logits[channel]) {
            match = 0;
        }
    }
    if (Xil_In32(SAMPLE_RAM_BASE_ADDRESS + 4 * 266) != golden->class_id) {
        match = 0;
    }
    return match;
}

static void print_inference_result(const char *source, const inference_result *golden,
                                   uint32_t cpu_us, uint32_t pl_cycles,
                                   uint32_t npu_cycles, uint32_t elapsed_us, int match)
{
    unsigned channel;

    printf("RESULT,%s,%u,%lu,%lu,%lu,%lu,%d", source, golden->class_id,
           (unsigned long)cpu_us, (unsigned long)pl_cycles,
           (unsigned long)npu_cycles, (unsigned long)elapsed_us, match);
    for (channel = 0; channel < 4; channel++) {
        printf(",%u", golden->features[channel]);
    }
    for (channel = 0; channel < 4; channel++) {
        printf(",%u", golden->hidden[channel]);
    }
    printf(",%d,%d\r\n", golden->logits[0], golden->logits[1]);
}

int inference_run_window(const char *source, const int16_t samples[64])
{
    inference_result golden;
    uint64_t start_time = platform_ticks();
    uint32_t cpu_us;
    uint32_t elapsed_us;
    uint32_t pl_cycles;
    uint32_t npu_cycles;
    int match;

    platform_heartbeat();
    infer_integer(samples, &golden);
    cpu_us = platform_microseconds(platform_ticks() - start_time);

    start_time = platform_ticks();
    write_input_samples(samples);
    Xil_Out32(CONTROL_BASE_ADDRESS + REG_CONTROL, 1);
    if (wait_for_accelerator(start_time)) {
        return -1;
    }
    match = compare_accelerator_result(&golden);
    elapsed_us = platform_microseconds(platform_ticks() - start_time);
    pl_cycles = Xil_In32(CONTROL_BASE_ADDRESS + REG_TOTAL_CYCLES);
    npu_cycles = Xil_In32(CONTROL_BASE_ADDRESS + REG_NPU_CYCLES);
    print_inference_result(source, &golden, cpu_us, pl_cycles, npu_cycles, elapsed_us, match);

    if (match) {
        return 0;
    }
    return -1;
}
