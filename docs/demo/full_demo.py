#!/usr/bin/env python3
"""One continuous live dashboard for a single-take demo recording.

Combines everything into one script/terminal so nothing needs to be
restarted mid-take: live motor telemetry + safety status + classification
history (same view as combined_dashboard.py), running through two timed
phases (normal, then fault-injection) with on-screen switch-flip cues, and
on exit automatically saves a labeled feature CSV + a normal-vs-fault PNG
plot (same output as feature_distribution.py) from everything it saw along
the way -- no separate capture step needed.

Presentation-only tool for the demo video. Does not affect any
verification gate. Requires pyserial and matplotlib.

Usage:
    python3 docs/demo/full_demo.py --port /dev/ttyUSB1

Timeline (defaults, all overridable):
  0s                          dashboard starts, telemetry only
  --normal-s (default 40s)    live combined view; do arm / duty-check /
                               disturbance test here (SW3 stays OFF)
  cue: FLIP SW3 ON            fault-injection phase begins
  --fault-s (default 30s)     live combined view continues; wait for the
                               latch banner
  cue: FLIP SW3 OFF           phase ends
  (Ctrl+C also ends it early at any point -- whatever was captured so far
  is still saved.)

On exit: saves measurements/full_demo_<date>/feature_capture.csv and
feature_distribution.png, labeling each classification window by which
phase it happened in.
"""
import argparse
import sys
import time
from pathlib import Path

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
    return {'class': int(fields[2]), 'match': int(fields[7]),
            'f0': int(fields[8]), 'f1': int(fields[9]),
            'f2': int(fields[10]), 'f3': int(fields[11])}


def parse_safety(line):
    fields = line.split(',')
    return {fields[i]: int(fields[i + 1]) for i in range(1, len(fields) - 1, 2)}


def bar(fraction, width=BAR_WIDTH, color=CYAN):
    fraction = max(0.0, min(1.0, fraction))
    filled = int(round(fraction * width))
    return f"{color}{'#' * filled}{RESET}{'-' * (width - filled)}"


def render(motor, safety, last_result, history, cpr, phase, remaining_s):
    lines = []
    lines.append(f"{BOLD}Zybo Full Demo -- live status{RESET}   "
                  f"phase={phase}  ({remaining_s:4.0f}s left)")
    lines.append('=' * 70)

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
    if phase == 'normal':
        lines.append('  Do the duty%/oscilloscope check and the 12->9->12V PSU test now.')
    elif phase == 'fault':
        lines.append('  Waiting for the latch banner. SW3 should be ON.')
    lines.append('  Ctrl+C ends early and still saves results.')
    return '\n'.join(lines)


def run_phase(connection, reader, phase_name, duration_s, telemetry_burst_s,
              state, cpr, sensor_ok, captured_rows):
    buffer = bytearray()
    phase_start = time.monotonic()
    phase_end = phase_start + duration_s
    while time.monotonic() < phase_end:
        connection.reset_input_buffer()
        connection.write(b't')
        connection.flush()
        burst_deadline = min(phase_end, time.monotonic() + telemetry_burst_s)
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
                    state['motor'] = decoded
            now = time.monotonic()
            if now - last_draw >= 1.0 / 15.0:
                remaining = max(0.0, phase_end - now)
                sys.stdout.write(CLEAR_HOME + render(
                    state['motor'], state['safety'], state['last_result'],
                    state['history'], cpr, phase_name, remaining) + '\n')
                sys.stdout.flush()
                last_draw = now

        if not sensor_ok or time.monotonic() >= phase_end:
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
            parsed = parse_result(result_line)
            state['last_result'] = parsed
            state['history'].append(parsed['class'])
            if len(state['history']) > HISTORY_LEN:
                state['history'] = state['history'][-HISTORY_LEN:]
            captured_rows.append({
                'label': phase_name, 'class': parsed['class'], 'match': parsed['match'],
                'f0': parsed['f0'], 'f1': parsed['f1'], 'f2': parsed['f2'], 'f3': parsed['f3'],
            })

        connection.write(b'f')
        connection.flush()
        safety_line = reader.read_line_starting_with('SAFETY', 1.0)
        if safety_line is not None:
            state['safety'] = parse_safety(safety_line)


def save_results(rows, out_dir):
    import csv
    if not rows:
        print('No classification windows captured -- nothing to save.')
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / 'feature_capture.csv'
    with csv_path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=['label', 'class', 'match', 'f0', 'f1', 'f2', 'f3'])
        writer.writeheader()
        writer.writerows(rows)
    print(f'CSV saved: {csv_path}')

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('matplotlib not available -- skipping plot (CSV is still saved).')
        return

    bands = ['f0', 'f1', 'f2', 'f3']
    fig, axes = plt.subplots(1, 4, figsize=(14, 4))
    colors = {'normal': '#2a9d3f', 'fault': '#d1495b'}
    for axis, band in zip(axes, bands):
        for label in ('normal', 'fault'):
            values = [row[band] for row in rows if row['label'] == label]
            if not values:
                continue
            axis.scatter([0 if label == 'normal' else 1] * len(values), values,
                         color=colors[label], alpha=0.7, label=label, s=40)
        axis.set_xticks([0, 1])
        axis.set_xticklabels(['normal', 'fault'])
        axis.set_title(f'band {band}')
        axis.grid(True, alpha=0.3)
    axes[0].set_ylabel('feature value (0-127)')
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc='upper center', ncol=2)
    fig.suptitle('FFT band features: normal vs fault-injection (full-demo capture)')
    fig.tight_layout(rect=[0, 0, 1, 0.9])
    png_path = out_dir / 'feature_distribution.png'
    fig.savefig(png_path, dpi=150)
    print(f'Plot saved: {png_path}')

    normal_classes = [row['class'] for row in rows if row['label'] == 'normal']
    fault_classes = [row['class'] for row in rows if row['label'] == 'fault']
    if normal_classes:
        print(f'normal phase: {sum(1 for c in normal_classes if c == 0)}/{len(normal_classes)} classified class 0')
    if fault_classes:
        print(f'fault phase : {sum(1 for c in fault_classes if c == 1)}/{len(fault_classes)} classified class 1')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--cpr', type=float, default=CPR_DEFAULT)
    parser.add_argument('--normal-s', type=float, default=40.0,
                        help='duration of the normal phase (arm/duty-check/disturbance test)')
    parser.add_argument('--fault-s', type=float, default=30.0,
                        help='duration of the SW3 fault-injection phase')
    parser.add_argument('--telemetry-burst-s', type=float, default=0.6,
                        help='seconds of live motor telemetry between each s/f query')
    parser.add_argument('--no-classify', action='store_true')
    parser.add_argument('--out-dir', type=Path, default=None,
                        help='default: measurements/full_demo_<unix-time>')
    args = parser.parse_args()

    if args.out_dir is None:
        args.out_dir = Path(f'measurements/full_demo_{int(time.time())}')

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
        time.sleep(0.3)

    state = {'motor': None, 'safety': {}, 'last_result': None, 'history': []}
    captured_rows = []

    try:
        print(f"\n===== PHASE: NORMAL ({args.normal_s:.0f}s) -- keep SW3 OFF, "
              f"do the duty check and PSU disturbance test =====")
        time.sleep(2.0)
        run_phase(connection, reader, 'normal', args.normal_s, args.telemetry_burst_s,
                  state, args.cpr, sensor_ok, captured_rows)

        print(f"\n===== FLIP SW3 ON NOW -- PHASE: FAULT ({args.fault_s:.0f}s) -- "
              f"wait for the latch banner =====")
        for remaining in range(6, 0, -1):
            print(f"      starting in {remaining}s ...")
            time.sleep(1.0)
        run_phase(connection, reader, 'fault', args.fault_s, args.telemetry_burst_s,
                  state, args.cpr, sensor_ok, captured_rows)

        print("\n===== FLIP SW3 OFF NOW -- then SW0 OFF/ON to clear+re-arm if latched =====")
    except KeyboardInterrupt:
        print("\n===== stopped early -- saving whatever was captured =====")
    finally:
        connection.write(b'T')
        connection.flush()
        time.sleep(0.1)
        connection.close()

    save_results(captured_rows, args.out_dir)


if __name__ == '__main__':
    main()
