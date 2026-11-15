#ifndef APP_PLATFORM_H
#define APP_PLATFORM_H

#include <stdint.h>

uint64_t platform_ticks(void);
uint32_t platform_microseconds(uint64_t elapsed_ticks);
void platform_heartbeat(void);

#endif
