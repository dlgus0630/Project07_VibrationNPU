/*------------------------------------------------------------
 * FFT + INT8 NPU 정수 골든 모델
 * 사용 : PC 검증과 Zynq ARM에서 같은 infer_integer()를 호출
 * 흐름 : 입력 정렬 → FFT → 대역 특징 → 은닉층 → 출력층 → 분류
 * 근거 : DESIGN.md의 정수 연산 계약, 기존 model_data.h의 상수
 *
 * 유지하는 규칙
 *   1. 음수 나눗셈은 0 방향이 아닌 아래쪽 정수로 내림
 *   2. FFT는 각 단계마다 /2 후 INT16 포화, 최종 FFT(x)/64
 *   3. 대역 합은 |실수|+|허수|, DC와 Nyquist는 제외
 *   4. 은닉층은 ReLU, 출력층은 signed INT8, 동점은 클래스 0
 *------------------------------------------------------------*/

#include "golden.h"
#include "model_data.h"

enum {
    FFT_SIZE = 64,
    FFT_STAGES = 6,
    TWIDDLE_FRACTION_BITS = 15,
    FEATURE_SHIFT_BITS = 5,
    FEATURE_COUNT = 4,
    HIDDEN_COUNT = 4,
    OUTPUT_COUNT = 2
};

/* 복소수 중간값. 곱셈과 butterfly 계산 중에는 INT32로 보관한다. */
typedef struct {
    int32_t real;
    int32_t imag;
} complex_value;

/* 단계 함수 : 공개 진입점에서 처리 순서를 먼저 볼 수 있게 선언한다. */
static void prepare_fft_input(const int16_t samples[FFT_SIZE], inference_result *result);
static void run_fft_stages(inference_result *result);
static void extract_band_features(inference_result *result);
static void run_hidden_layer(inference_result *result);
static void run_output_layer(inference_result *result);

/*------------------------------------------------------------
 * 공개 진입점 : 위에서 아래 순서로 한 번의 추론을 수행한다.
 * samples는 원본 64개 정수 입력, result는 중간값과 최종 결과다.
 *------------------------------------------------------------*/
void infer_integer(const int16_t samples[64], inference_result *result)
{
    /* 1. 6비트 인덱스를 뒤집어 FFT 입력 순서를 만든다. */
    prepare_fft_input(samples, result);

    /* 2. 6단계 butterfly를 계산한다. */
    run_fft_stages(result);

    /* 3. 양의 주파수 bin을 네 대역으로 묶어 특징을 만든다. */
    extract_band_features(result);

    /* 4. 특징 4개 → 은닉 뉴런 4개, ReLU 적용. */
    run_hidden_layer(result);

    /* 5. 은닉값 4개 → 출력 점수 2개, ReLU 미적용. */
    run_output_layer(result);

    /* 6. 두 점수를 비교한다. 같은 점수이면 기존처럼 0이다. */
    if (result->logits[1] > result->logits[0]) {
        result->class_id = 1;
    } else {
        result->class_id = 0;
    }
}

/*------------------------------------------------------------
 * 공통 정수 연산
 *------------------------------------------------------------*/

/* value / 2^shift를 내림한다. 예: -3 / 2 → -2.
 * C의 기본 정수 나눗셈(-3 / 2 → -1)과 다른 부분을 명시한다.
 * 호출 범위는 FFT 곱/합과 NPU 누산값이며 INT64_MIN은 들어오지 않는다.
 */
static int32_t floor_shift(int64_t value, unsigned shift)
{
    int64_t divisor = (int64_t)1 << shift;
    int64_t magnitude;
    int64_t rounded_magnitude;

    if (value >= 0) {
        return (int32_t)(value / divisor);
    }

    magnitude = -value;
    rounded_magnitude = (magnitude + divisor - 1) / divisor;

    return (int32_t)(-rounded_magnitude);
}

/* 범위를 벗어난 값을 가장 가까운 경계값으로 제한한다. */
static int32_t clamp_value(int32_t value, int32_t minimum, int32_t maximum)
{
    if (value < minimum) {
        return minimum;
    }

    if (value > maximum) {
        return maximum;
    }

    return value;
}

/* FFT 각 단계의 공통 출력 처리 : /2 내림 → INT16 포화. */
static int16_t scale_fft_output(int32_t value)
{
    int32_t half_value = floor_shift(value, 1);
    int32_t saturated = clamp_value(half_value, -32768, 32767);

    return (int16_t)saturated;
}

/*------------------------------------------------------------
 * 1. FFT 입력 정렬
 *------------------------------------------------------------*/

/* 예: 6비트 인덱스 000011(3) → 110000(48). */
static unsigned reverse_fft_index(unsigned index)
{
    unsigned reversed = 0;
    unsigned bit;

    for (bit = 0; bit < FFT_STAGES; bit++) {
        reversed = reversed << 1;
        reversed = reversed | (index & 1U);
        index = index >> 1;
    }

    return reversed;
}

static void prepare_fft_input(const int16_t samples[FFT_SIZE], inference_result *result)
{
    unsigned sample_index;

    for (sample_index = 0; sample_index < FFT_SIZE; sample_index++) {
        unsigned destination = reverse_fft_index(sample_index);

        result->re[destination] = samples[sample_index];
        result->im[destination] = 0;
    }
}

/*------------------------------------------------------------
 * 2. FFT butterfly
 *    위 입력 A, 아래 입력 B, 회전 계수 W일 때
 *    위 출력 = (A + B*W)/2, 아래 출력 = (A - B*W)/2
 *------------------------------------------------------------*/

/* (Br + j*Bi) × (Wr + j*Wi)를 네 곱으로 풀어 쓴다.
 * Q1.15 소수점 조정은 곱을 합친 뒤 한 번만 수행한다.
 */
static complex_value multiply_by_twiddle(complex_value input, unsigned twiddle_index)
{
    int64_t real_times_real = (int64_t)input.real * tw_re[twiddle_index];
    int64_t imag_times_imag = (int64_t)input.imag * tw_im[twiddle_index];
    int64_t real_times_imag = (int64_t)input.real * tw_im[twiddle_index];
    int64_t imag_times_real = (int64_t)input.imag * tw_re[twiddle_index];
    int64_t real_product = real_times_real - imag_times_imag;
    int64_t imag_product = real_times_imag + imag_times_real;
    complex_value rotated;

    rotated.real = floor_shift(real_product, TWIDDLE_FRACTION_BITS);
    rotated.imag = floor_shift(imag_product, TWIDDLE_FRACTION_BITS);

    return rotated;
}

static void apply_fft_butterfly(inference_result *result, unsigned upper_index,
                                unsigned lower_index, unsigned twiddle_index)
{
    complex_value upper;
    complex_value lower;
    complex_value rotated;
    int32_t upper_real;
    int32_t upper_imag;
    int32_t lower_real;
    int32_t lower_imag;

    /* 결과를 덮어쓰기 전에 A와 B를 모두 읽어 둔다. */
    upper.real = result->re[upper_index];
    upper.imag = result->im[upper_index];
    lower.real = result->re[lower_index];
    lower.imag = result->im[lower_index];

    rotated = multiply_by_twiddle(lower, twiddle_index);

    upper_real = upper.real + rotated.real;
    upper_imag = upper.imag + rotated.imag;
    lower_real = upper.real - rotated.real;
    lower_imag = upper.imag - rotated.imag;

    result->re[upper_index] = scale_fft_output(upper_real);
    result->im[upper_index] = scale_fft_output(upper_imag);
    result->re[lower_index] = scale_fft_output(lower_real);
    result->im[lower_index] = scale_fft_output(lower_imag);
}

static void run_fft_stages(inference_result *result)
{
    unsigned stage;

    for (stage = 1; stage <= FFT_STAGES; stage++) {
        unsigned group_size = 1U << stage;
        unsigned half_group = group_size / 2;
        unsigned group_start;

        for (group_start = 0; group_start < FFT_SIZE; group_start += group_size) {
            unsigned pair_index;

            for (pair_index = 0; pair_index < half_group; pair_index++) {
                unsigned upper_index = group_start + pair_index;
                unsigned lower_index = upper_index + half_group;
                unsigned twiddle_index = pair_index * FFT_SIZE / group_size;

                apply_fft_butterfly(result, upper_index, lower_index, twiddle_index);
            }
        }
    }
}

/*------------------------------------------------------------
 * 3. 대역 특징 : bin 1..6 / 7..12 / 13..20 / 21..31
 *    각 bin에서 |실수부|+|허수부|를 합하고 /32 후 0..127 포화
 *------------------------------------------------------------*/

static unsigned select_frequency_band(unsigned bin_index)
{
    if (bin_index <= 6) {
        return 0;
    }

    if (bin_index <= 12) {
        return 1;
    }

    if (bin_index <= 20) {
        return 2;
    }

    return 3;
}

static void extract_band_features(inference_result *result)
{
    uint32_t band_sums[FEATURE_COUNT] = {0, 0, 0, 0};
    unsigned bin_index;
    unsigned band_index;

    /* bin 0(DC)과 bin 32(Nyquist)를 제외한 양의 주파수만 사용한다. */
    for (bin_index = 1; bin_index < FFT_SIZE / 2; bin_index++) {
        int32_t real_magnitude = result->re[bin_index];
        int32_t imag_magnitude = result->im[bin_index];

        if (real_magnitude < 0) {
            real_magnitude = -real_magnitude;
        }

        if (imag_magnitude < 0) {
            imag_magnitude = -imag_magnitude;
        }

        band_index = select_frequency_band(bin_index);
        band_sums[band_index] += (uint32_t)(real_magnitude + imag_magnitude);
    }

    for (band_index = 0; band_index < FEATURE_COUNT; band_index++) {
        int32_t scaled_sum = (int32_t)(band_sums[band_index] >> FEATURE_SHIFT_BITS);
        int32_t feature = clamp_value(scaled_sum, 0, 127);

        result->features[band_index] = (uint8_t)feature;
    }
}

/*------------------------------------------------------------
 * 4. 은닉층 : bias + Σ(특징 × 가중치) → shift → ReLU/포화
 *------------------------------------------------------------*/
static void run_hidden_layer(inference_result *result)
{
    unsigned neuron;

    for (neuron = 0; neuron < HIDDEN_COUNT; neuron++) {
        int64_t accumulator = b1[neuron];
        unsigned input_index;
        int32_t scaled_value;
        int32_t activated_value;

        for (input_index = 0; input_index < FEATURE_COUNT; input_index++) {
            int32_t input_value = result->features[input_index];
            int32_t weight = w1[neuron][input_index];
            int32_t product = input_value * weight;

            accumulator += product;
        }

        scaled_value = floor_shift(accumulator, SHIFT1);
        activated_value = clamp_value(scaled_value, 0, 127);
        result->hidden[neuron] = (uint8_t)activated_value;
    }
}

/*------------------------------------------------------------
 * 5. 출력층 : bias + Σ(은닉값 × 가중치) → shift → INT8 포화
 *    출력 점수는 음수도 사용하므로 ReLU를 적용하지 않는다.
 *------------------------------------------------------------*/
static void run_output_layer(inference_result *result)
{
    unsigned neuron;

    for (neuron = 0; neuron < OUTPUT_COUNT; neuron++) {
        int64_t accumulator = b2[neuron];
        unsigned input_index;
        int32_t scaled_value;
        int32_t saturated_value;

        for (input_index = 0; input_index < HIDDEN_COUNT; input_index++) {
            int32_t input_value = result->hidden[input_index];
            int32_t weight = w2[neuron][input_index];
            int32_t product = input_value * weight;

            accumulator += product;
        }

        scaled_value = floor_shift(accumulator, SHIFT2);
        saturated_value = clamp_value(scaled_value, -128, 127);
        result->logits[neuron] = (int8_t)saturated_value;
    }
}
