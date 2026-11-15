/*------------------------------------------------------------
 * PC 골든 모델 검사
 * 순서 : 기준 파일 열기 → 64개 입력 읽기 → C 추론 → 각 결과 비교
 * 성공/실패 문자열과 20개 기준 입력, 비교 순서를 유지한다.
 *------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include "golden.h"

typedef struct {
    FILE *samples;
    FILE *fft_real;
    FILE *fft_imag;
    FILE *features;
    FILE *hidden;
    FILE *logits;
    FILE *classes;
} reference_files;

static FILE *open_reference(const char *name)
{
    char path[256];
    FILE *stream;

    if (snprintf(path, sizeof path, "data/%s.mem", name) < 0) {
        exit(2);
    }
    stream = fopen(path, "r");
    if (!stream) {
        perror(path);
        exit(2);
    }
    return stream;
}

static int read_reference_value(FILE *stream, int bits, int is_signed)
{
    unsigned raw_value;
    unsigned sign_mask = 1U << (bits - 1);

    if (fscanf(stream, "%x", &raw_value) != 1) {
        fputs("truncated vector\n", stderr);
        exit(2);
    }
    if (is_signed && (raw_value & sign_mask)) {
        return (int)raw_value - (1 << bits);
    }
    return (int)raw_value;
}

static reference_files open_reference_files(void)
{
    reference_files files;

    files.samples = open_reference("samples");
    files.fft_real = open_reference("fft_re");
    files.fft_imag = open_reference("fft_im");
    files.features = open_reference("features");
    files.hidden = open_reference("hidden");
    files.logits = open_reference("logits");
    files.classes = open_reference("class");
    return files;
}

static void close_reference_files(const reference_files *files)
{
    fclose(files->samples);
    fclose(files->fft_real);
    fclose(files->fft_imag);
    fclose(files->features);
    fclose(files->hidden);
    fclose(files->logits);
    fclose(files->classes);
}

static void read_input_window(FILE *stream, int16_t samples[64])
{
    unsigned sample_index;

    for (sample_index = 0; sample_index < 64; sample_index++) {
        samples[sample_index] = (int16_t)read_reference_value(stream, 16, 1);
    }
}

/* 첫 불일치에서 멈추며, 같은 index의 실수/허수 및 특징/은닉 순서도 유지한다. */
static int compare_window(const reference_files *files, const inference_result *result,
                           int *failed_element)
{
    int element;

    for (element = 0; element < 64; element++) {
        *failed_element = element;
        if (result->re[element] != read_reference_value(files->fft_real, 16, 1)) {
            return 0;
        }
        if (result->im[element] != read_reference_value(files->fft_imag, 16, 1)) {
            return 0;
        }
    }
    for (element = 0; element < 4; element++) {
        *failed_element = element;
        if (result->features[element] != read_reference_value(files->features, 8, 0)) {
            return 0;
        }
        if (result->hidden[element] != read_reference_value(files->hidden, 8, 0)) {
            return 0;
        }
    }
    for (element = 0; element < 2; element++) {
        *failed_element = element;
        if (result->logits[element] != read_reference_value(files->logits, 8, 1)) {
            return 0;
        }
    }
    *failed_element = 2;
    if (result->class_id != read_reference_value(files->classes, 8, 0)) {
        return 0;
    }
    return 1;
}

int main(void)
{
    reference_files files = open_reference_files();
    int case_index;

    for (case_index = 0; case_index < 20; case_index++) {
        int16_t samples[64];
        inference_result result;
        int failed_element;

        read_input_window(files.samples, samples);
        infer_integer(samples, &result);
        if (!compare_window(&files, &result, &failed_element)) {
            fprintf(stderr, "HOST C FAIL case %d element %d\n", case_index, failed_element);
            return 1;
        }
    }
    close_reference_files(&files);
    puts("HOST C PASS: 20 windows, 2560 FFT components, 220 result values");
    return 0;
}
