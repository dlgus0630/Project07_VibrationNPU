#ifndef GOLDEN_H
#define GOLDEN_H
#include <stdint.h>
typedef struct {
    int16_t re[64],im[64];
    uint8_t features[4],hidden[4];
    int8_t logits[2];
    uint8_t class_id;
} inference_result;
void infer_integer(const int16_t samples[64],inference_result *result);
#endif
