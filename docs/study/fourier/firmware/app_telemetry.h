#ifndef APP_TELEMETRY_H
#define APP_TELEMETRY_H

#include <stdint.h>

int telemetry_is_streaming(void);
void telemetry_set_streaming(int enabled);
void telemetry_poll(void);
void telemetry_poll_at(uint64_t now);

#endif
