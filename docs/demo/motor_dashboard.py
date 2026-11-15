#!/usr/bin/env python3
"""Live terminal dashboard for the 12->9->12 V disturbance demo.

Presentation-only tool: reads the same binary telemetry stream as
tools/capture_telemetry.py and redraws a clean, camera-friendly status
panel instead of a scrolling raw log or a CSV. Does not affect any
verification gate. Requires pyserial (python3 -m pip install pyserial).

Usage:
    python3 docs/demo/motor_dashboard.py --port /dev/ttyUSB1
    python3 docs/demo/motor_dashboard.py --port COM5

Ctrl+C to stop; the script sends 'T' on the way out so the board is not
left streaming telemetry nobody is reading.
"""
import argparse
import sys
import time

FRAME_SIZE = 16
SYNC = b'\xa5\x5a'
CPR_DEFAULT = 988.427
BAR_WIDTH = 40

RESET = '\x1b[0m'
BOLD = '\x1b[1m'
GREEN = '\x1b[32m'
RED = '\x1b[31m'
YELLOW = '\x1b[33m'
CYAN = '\x1b[36m'
CLEAR_HOME = '\x1b[2J\x1b[H'


def decode_frame(frame):
    checksum = 0
    for value in frame[:15]:
        checksum ^= value
    if checksum != frame[15]:
        return None
    reference = int.from_bytes(frame[4:6], 'little') & 0x1fff
    measured = int.from_bytes(frame[6:8], 'little') & 0x1fff
    duty = int.from_bytes(frame[8:10], 'little') & 0x1fff
    flags = frame[14]
    return {
        'reference': reference,
        'measured': measured,
        'duty': duty,
        'armed': flags & 1,
        'fault': (flags >> 1) & 1,
        'enabled': (flags >> 2) & 1,
    }


def bar(fraction, width=BAR_WIDTH, color=CYAN):
    fraction = max(0.0, min(1.0, fraction))
    filled = int(round(fraction * width))
    return f"{color}{'#' * filled}{RESET}{'-' * (width - filled)}"


def render(state, cpr, frame_count):
    full_scale_rpm = 1800.0 * 60.0 / cpr
    target_rpm = state['reference'] * full_scale_rpm / 4096.0
    measured_rpm = state['measured'] * full_scale_rpm / 4096.0
    duty_pct = state['duty'] * 100.0 / 4096.0
    armed_text = f'{GREEN}ARMED{RESET}' if state['armed'] else f'{YELLOW}DISARMED{RESET}'
    fault_text = f'{RED}FAULT{RESET}' if state['fault'] else f'{GREEN}OK{RESET}'
    rpm_frac = measured_rpm / target_rpm if target_rpm > 1e-6 else 0.0
    rpm_color = GREEN if 0.9 <= rpm_frac <= 1.1 else YELLOW if 0.7 <= rpm_frac <= 1.3 else RED

    lines = []
    lines.append(f"{BOLD}Zybo Motor Control -- live telemetry{RESET}  (frames={frame_count})")
    lines.append('=' * 60)
    lines.append(f"  Status : {armed_text}   Encoder/motor fault : {fault_text}")
    lines.append('')
    lines.append(f"  Target RPM   : {target_rpm:7.2f}")
    lines.append(f"  Measured RPM : {measured_rpm:7.2f}   [{bar(rpm_frac / 1.3, color=rpm_color)}]")
    lines.append(f"  PWM duty     : {duty_pct:6.2f} %  [{bar(duty_pct / 100.0)}]")
    lines.append('')
    lines.append('  Ctrl+C to stop (telemetry is turned back off automatically)')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--cpr', type=float, default=CPR_DEFAULT)
    parser.add_argument('--refresh-hz', type=float, default=15.0)
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit('pyserial is required: python3 -m pip install pyserial')

    connection = serial.Serial(args.port, args.baud, timeout=0.1)
    connection.reset_input_buffer()
    connection.write(b't')
    connection.flush()
    time.sleep(0.2)
    connection.reset_input_buffer()

    buffer = bytearray()
    frame_count = 0
    last_state = None
    last_draw = 0.0
    min_interval = 1.0 / args.refresh_hz

    try:
        while True:
            buffer.extend(connection.read(512))
            while True:
                position = buffer.find(SYNC)
                if position < 0:
                    if buffer[-1:] == SYNC[:1]:
                        del buffer[:-1]
                    else:
                        buffer.clear()
                    break
                if position:
                    del buffer[:position]
                if len(buffer) < FRAME_SIZE:
                    break
                candidate = bytes(buffer[:FRAME_SIZE])
                del buffer[:FRAME_SIZE]
                decoded = decode_frame(candidate)
                if decoded is not None:
                    last_state = decoded
                    frame_count += 1
            now = time.monotonic()
            if last_state is not None and now - last_draw >= min_interval:
                sys.stdout.write(CLEAR_HOME + render(last_state, args.cpr, frame_count) + '\n')
                sys.stdout.flush()
                last_draw = now
    except KeyboardInterrupt:
        pass
    finally:
        connection.write(b'T')
        connection.flush()
        time.sleep(0.1)
        connection.close()
        print('\ntelemetry stopped, port closed')


if __name__ == '__main__':
    main()
