#!/usr/bin/env python3
"""Combined live terminal dashboard: motor + safety + classification in one screen.

Presentation-only tool for the demo video. Alternates between two UART
modes on the same port -- a short burst of streaming telemetry (motor
speed/duty), then a paused moment to poll classification ('s') and safety
status ('f') -- and redraws one combined panel. Does not affect any
verification gate. Requires pyserial.

Usage:
    python3 docs/demo/combined_dashboard.py --port /dev/ttyUSB1

Ctrl+C to stop; telemetry is turned back off on the way out.
"""
import argparse
import sys
import time

FRAME_SIZE = 16
SYNC = b'\xa5\x5a'
CPR_DEFAULT = 988.427
BAR_WIDTH = 30
HISTORY_LEN = 20

RESET = '\x1b[0m'
BOLD = '\x1b[1m'
GREEN = '\x1b[32m'
RED = '\x1b[31m'
YELLOW = '\x1b[33m'
CYAN = '\x1b[36m'
CLEAR_HOME = '\x1b[2J\x1b[H'


class LineReader:
    def __init__(self, connection):
        self.connection = connection
        self.buffer = b''

    def read_line_starting_with(self, prefix, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                line = self.buffer[:newline]
                self.buffer = self.buffer[newline + 1:]
                text = line.decode(errors='replace').strip()
                if text.startswith(prefix):
                    return text
                continue
            chunk = self.connection.read(256)
            if chunk:
                self.buffer += chunk
        return None


def decode_telemetry_frame(frame):
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
        'reference': reference, 'measured': measured, 'duty': duty,
        'armed': flags & 1, 'fault': (flags >> 1) & 1, 'enabled': (flags >> 2) & 1,
    }


def parse_result(line):
    fields = line.split(',')
    return {'class': int(fields[2]), 'match': int(fields[7])}


def parse_safety(line):
    fields = line.split(',')
    return {fields[i]: int(fields[i + 1]) for i in range(1, len(fields) - 1, 2)}


def bar(fraction, width=BAR_WIDTH, color=CYAN):
    fraction = max(0.0, min(1.0, fraction))
    filled = int(round(fraction * width))
    return f"{color}{'#' * filled}{RESET}{'-' * (width - filled)}"


def render(motor, safety, last_result, history, cpr, ticks):
    lines = []
    lines.append(f"{BOLD}Zybo Combined Live Status{RESET}  (updates={ticks})")
    lines.append('=' * 66)

    if motor is not None:
        full_scale_rpm = 1800.0 * 60.0 / cpr
        target_rpm = motor['reference'] * full_scale_rpm / 4096.0
        measured_rpm = motor['measured'] * full_scale_rpm / 4096.0
        duty_pct = motor['duty'] * 100.0 / 4096.0
        armed_text = f'{GREEN}ARMED{RESET}' if motor['armed'] else f'{YELLOW}DISARMED{RESET}'
        rpm_frac = measured_rpm / target_rpm if target_rpm > 1e-6 else 0.0
        rpm_color = GREEN if 0.9 <= rpm_frac <= 1.1 else YELLOW if 0.7 <= rpm_frac <= 1.3 else RED
        lines.append(f"[MOTOR]  {armed_text}   target {target_rpm:6.2f} RPM   "
                      f"measured {measured_rpm:6.2f} RPM")
        lines.append(f"         speed [{bar(rpm_frac / 1.3, color=rpm_color)}]")
        lines.append(f"         duty  {duty_pct:5.1f}% [{bar(duty_pct / 100.0)}]")
    else:
        lines.append('[MOTOR]  (no telemetry yet)')
    lines.append('')

    dots = []
    for value in history:
        dots.append(f'{RED}#{RESET}' if value == 1 else f'{GREEN}.{RESET}')
    padded = dots + ['-'] * (HISTORY_LEN - len(dots))
    lines.append('[CLASS]  recent windows: ' + ' '.join(padded))
    if last_result is not None:
        class_text = f'{RED}1 anomaly{RESET}' if last_result['class'] else f'{GREEN}0 normal{RESET}'
        match_text = f'{GREEN}match{RESET}' if last_result['match'] else f'{RED}MISMATCH{RESET}'
        lines.append(f'         last: class={class_text}   CPU/PL {match_text}')
    lines.append('')

    if safety:
        latched = safety.get('latched', 0)
        derated = safety.get('derated', 0)
        warning = safety.get('warning', 0)
        if latched:
            lines.append(f"[SAFETY] {RED}{BOLD}### LATCHED -- MOTOR STOPPED ###{RESET}")
        elif derated:
            lines.append(f"[SAFETY] {YELLOW}{BOLD}--- DERATED (25% duty cap) ---{RESET}")
        elif warning:
            lines.append(f"[SAFETY] {YELLOW}--- warning ---{RESET}")
        else:
            lines.append(f"[SAFETY] {GREEN}--- normal ---{RESET}")
        lines.append(f"         warning={warning} derated={derated} latched={latched} "
                      f"consecutive={safety.get('consecutive', 0)} "
                      f"abnormal_total={safety.get('abnormal_total', 0)}")
    lines.append('')
    lines.append('  Ctrl+C to stop')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--cpr', type=float, default=CPR_DEFAULT)
    parser.add_argument('--telemetry-burst-s', type=float, default=1.2,
                        help='seconds of live motor telemetry per cycle')
    parser.add_argument('--no-classify', action='store_true',
                        help='skip the s/f query round (motor-only, no pause) -- '
                             'use if the sensor is not wired')
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit('pyserial is required: python3 -m pip install pyserial')

    connection = serial.Serial(args.port, args.baud, timeout=0.1)
    connection.reset_input_buffer()
    reader = LineReader(connection)

    sensor_ok = False
    if not args.no_classify:
        connection.write(b'T')
        connection.flush()
        time.sleep(0.1)
        connection.reset_input_buffer()
        connection.write(b'i')
        connection.flush()
        ready_line = reader.read_line_starting_with('SENSOR_READY', 3.0)
        sensor_ok = ready_line is not None and ready_line.endswith('1')
        print(f'sensor init: {ready_line!r} (ok={sensor_ok})')
        if not sensor_ok:
            print('warning: sensor not ready -- classification section will stay blank')
        time.sleep(0.3)

    motor_state = None
    last_result = None
    safety = {}
    history = []
    ticks = 0
    buffer = bytearray()

    try:
        while True:
            connection.reset_input_buffer()
            connection.write(b't')
            connection.flush()
            burst_deadline = time.monotonic() + args.telemetry_burst_s
            last_draw = 0.0
            buffer.clear()
            while time.monotonic() < burst_deadline:
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
                    decoded = decode_telemetry_frame(candidate)
                    if decoded is not None:
                        motor_state = decoded
                now = time.monotonic()
                if now - last_draw >= 1.0 / 15.0:
                    ticks += 1
                    sys.stdout.write(CLEAR_HOME + render(
                        motor_state, safety, last_result, history, args.cpr, ticks) + '\n')
                    sys.stdout.flush()
                    last_draw = now

            if args.no_classify or not sensor_ok:
                continue

            connection.write(b'T')
            connection.flush()
            time.sleep(0.05)
            connection.reset_input_buffer()
            reader.buffer = b''

            connection.write(b's')
            connection.flush()
            result_line = reader.read_line_starting_with('RESULT', 2.0)
            if result_line is not None:
                last_result = parse_result(result_line)
                history.append(last_result['class'])
                if len(history) > HISTORY_LEN:
                    history = history[-HISTORY_LEN:]

            connection.write(b'f')
            connection.flush()
            safety_line = reader.read_line_starting_with('SAFETY', 1.0)
            if safety_line is not None:
                safety = parse_safety(safety_line)
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
