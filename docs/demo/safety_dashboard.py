#!/usr/bin/env python3
"""Live terminal dashboard for the SW3 fault-injection / safety-latch demo.

Presentation-only tool: repeats the same 's' (sample+infer) and 'f' (safety
status) UART commands an operator would type by hand, and redraws a clean,
camera-friendly panel showing the rolling classification history and the
safety supervisor state instead of raw scrolling text. Does not affect any
verification gate. Requires pyserial (python3 -m pip install pyserial).

Usage:
    python3 docs/demo/safety_dashboard.py --port /dev/ttyUSB1
    python3 docs/demo/safety_dashboard.py --port COM5 --interval 0.8

Sensor must already be wired; the script sends 'i' once at startup. Ctrl+C
to stop.
"""
import argparse
import sys
import time

RESET = '\x1b[0m'
BOLD = '\x1b[1m'
GREEN = '\x1b[32m'
RED = '\x1b[31m'
YELLOW = '\x1b[33m'
CYAN = '\x1b[36m'
CLEAR_HOME = '\x1b[2J\x1b[H'
HISTORY_LEN = 20


class LineReader:
    """Minimal buffered \\r\\n line reader over a pyserial connection."""

    def __init__(self, connection):
        self.connection = connection
        self.buffer = b''

    def read_line(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                line = self.buffer[:newline]
                self.buffer = self.buffer[newline + 1:]
                return line.decode(errors='replace').strip()
            if time.monotonic() >= deadline:
                return None
            chunk = self.connection.read(256)
            if chunk:
                self.buffer += chunk

    def read_line_starting_with(self, prefix, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.read_line(deadline - time.monotonic())
            if line is None:
                return None
            if line.startswith(prefix):
                return line
        return None


def parse_result(line):
    fields = line.split(',')
    # RESULT,source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0..f3,h0..h3,o0,o1
    return {
        'source': fields[1],
        'class': int(fields[2]),
        'match': int(fields[7]),
    }


def parse_safety(line):
    fields = line.split(',')
    # SAFETY,warning,W,derated,D,latched,L,watchdog,WD,cause,C,consecutive,N,abnormal_total,T
    values = {fields[i]: int(fields[i + 1]) for i in range(1, len(fields) - 1, 2)}
    return values


def render(history, safety, last_result, cycles):
    lines = []
    lines.append(f"{BOLD}Zybo Vibration Safety Demo -- live classification{RESET}  (cycles={cycles})")
    lines.append('=' * 64)

    dots = []
    for value in history:
        dots.append(f'{RED}#{RESET}' if value == 1 else f'{GREEN}.{RESET}')
    padded = dots + ['-'] * (HISTORY_LEN - len(dots))
    lines.append('  Recent windows (oldest -> newest): ' + ' '.join(padded))
    lines.append('  (. = normal class 0, # = anomaly class 1)')
    lines.append('')

    if last_result is not None:
        match_text = f'{GREEN}match{RESET}' if last_result['match'] else f'{RED}MISMATCH{RESET}'
        class_text = f'{RED}1 (anomaly){RESET}' if last_result['class'] else f'{GREEN}0 (normal){RESET}'
        lines.append(f"  Last window : source={last_result['source']:<12} class={class_text}  CPU/PL {match_text}")
    lines.append('')

    if safety:
        latched = safety.get('latched', 0)
        derated = safety.get('derated', 0)
        warning = safety.get('warning', 0)
        watchdog = safety.get('watchdog', 0)
        consecutive = safety.get('consecutive', 0)
        abnormal_total = safety.get('abnormal_total', 0)
        cause = safety.get('cause', 0)

        if latched:
            lines.append(f"  {RED}{BOLD}### MOTOR OUTPUT LATCHED -- SAFETY STOP ###{RESET}")
        elif derated:
            lines.append(f"  {YELLOW}{BOLD}--- DERATED (25% duty limit) ---{RESET}")
        elif warning:
            lines.append(f"  {YELLOW}--- warning ---{RESET}")
        else:
            lines.append(f"  {GREEN}--- normal operation ---{RESET}")

        lines.append('')
        lines.append(f"  warning={warning}  derated={derated}  latched={latched}  "
                      f"watchdog_fault={watchdog}  cause={cause}")
        lines.append(f"  consecutive anomalies = {consecutive}   "
                      f"abnormal windows (total) = {abnormal_total}")
        if latched:
            lines.append('')
            lines.append('  Clear + re-arm: SW3 OFF -> SW0 OFF -> (keep SW2) -> SW0 ON')

    lines.append('')
    lines.append('  Ctrl+C to stop')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--interval', type=float, default=1.0,
                        help='seconds between classification windows')
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit('pyserial is required: python3 -m pip install pyserial')

    connection = serial.Serial(args.port, args.baud, timeout=0.1)
    connection.reset_input_buffer()
    reader = LineReader(connection)

    # t/T is absolute: make sure telemetry streaming is off so it never
    # interleaves with the RESULT/SAFETY text lines this script parses.
    connection.write(b'T')
    connection.flush()
    time.sleep(0.1)
    connection.reset_input_buffer()

    connection.write(b'i')
    connection.flush()
    ready_line = reader.read_line_starting_with('SENSOR_READY', 3.0)
    sensor_ok = ready_line is not None and ready_line.endswith('1')
    print(f"sensor init: {ready_line!r} (ok={sensor_ok})")
    if not sensor_ok:
        print('warning: sensor did not report ready -- check wiring before the demo')
    time.sleep(0.5)

    history = []
    last_result = None
    safety = {}
    cycles = 0

    try:
        while True:
            connection.reset_input_buffer()
            connection.write(b's')
            connection.flush()
            line = reader.read_line_starting_with('RESULT', 2.0)
            if line is not None:
                last_result = parse_result(line)
                history.append(last_result['class'])
                if len(history) > HISTORY_LEN:
                    history = history[-HISTORY_LEN:]

            connection.write(b'f')
            connection.flush()
            safety_line = reader.read_line_starting_with('SAFETY', 1.0)
            if safety_line is not None:
                safety = parse_safety(safety_line)

            cycles += 1
            sys.stdout.write(CLEAR_HOME + render(history, safety, last_result, cycles) + '\n')
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        connection.close()
        print('\nport closed')


if __name__ == '__main__':
    main()
