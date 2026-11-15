#ifndef SENSOR_SPI_H
#define SENSOR_SPI_H

#include <stdint.h>

int sensor_initialize(void);
int sensor_acquire_window(int16_t samples[64], uint32_t intervals_us[64]);

#endif
