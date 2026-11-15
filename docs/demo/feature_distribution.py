#!/usr/bin/env python3
"""Capture real FFT-band features live and plot normal vs anomaly distribution.

Presentation-only tool for the README/demo video. Captures real sensor
windows through the 's' (sample+infer) UART command in two operator-timed
phases -- normal, then fault-injection -- and plots the four FFT-band
features (f0..f3) so the class separation is visible with real hardware
evidence instead of the two fixed demo_samples arrays. Does not affect
any verification gate. Requires pyserial and matplotlib.

Usage:
    python3 docs/demo/feature_distribution.py --port /dev/ttyUSB1

Timer-driven (no keyboard interaction, so it can run unattended while an
operator flips the physical switch): after a --lead-s countdown it captures
N windows labeled "normal", prints a cue to flip SW3, waits --settle-s, then
captures N more windows labeled "fault", and finally saves the raw CSV and a
PNG scatter/box plot.
"""
import argparse
import csv
import time
from pathlib import Path


class LineReader:
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
    # RESULT,source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0,f1,f2,f3,h0..h3,o0,o1
    fields = line.split(',')
    return {
        'class': int(fields[2]),
        'match': int(fields[7]),
        'f0': int(fields[8]),
        'f1': int(fields[9]),
        'f2': int(fields[10]),
        'f3': int(fields[11]),
    }


def capture_phase(connection, reader, label, count, settle_s):
    rows = []
    remaining = settle_s
    while remaining > 0:
        step = min(1.0, remaining)
        print(f'    starting in {remaining:.0f}s ...')
        time.sleep(step)
        remaining -= step
    print(f'  capturing {count} windows labeled "{label}" ...')
    for i in range(count):
        connection.reset_input_buffer()
        connection.write(b's')
        connection.flush()
        line = reader.read_line_starting_with('RESULT', 2.0)
        if line is None:
            print(f'    window {i + 1}/{count}: no RESULT, skipped')
            continue
        parsed = parse_result(line)
        parsed['label'] = label
        rows.append(parsed)
        print(f'    window {i + 1}/{count}: class={parsed["class"]} '
              f'f0..f3={parsed["f0"]},{parsed["f1"]},{parsed["f2"]},{parsed["f3"]}')

        connection.write(b'f')
        connection.flush()
        safety_line = reader.read_line_starting_with('SAFETY', 1.0)
        if safety_line is not None and ',latched,1,' in safety_line:
            print('    !!! SAFETY LATCH TRIPPED -- motor is stopped. Clear it with '
                  'SW0 OFF then ON before continuing. Stopping this capture phase early.')
            break
        time.sleep(0.15)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--windows', type=int, default=20,
                        help='captured windows per phase')
    parser.add_argument('--settle-s', type=float, default=2.0,
                        help='pause after a switch flip before capturing, so it settles')
    parser.add_argument('--lead-s', type=float, default=3.0,
                        help='countdown before phase 1 starts, so SW3 can be confirmed OFF')
    parser.add_argument('--out-dir', type=Path,
                        default=Path('measurements/feature_distribution_2026-09-17'))
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit('pyserial is required: python3 -m pip install pyserial')
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        raise SystemExit('matplotlib is required: python3 -m pip install matplotlib')

    connection = serial.Serial(args.port, args.baud, timeout=0.1)
    connection.reset_input_buffer()
    reader = LineReader(connection)

    connection.write(b'T')
    connection.flush()
    time.sleep(0.1)
    connection.reset_input_buffer()

    connection.write(b'i')
    connection.flush()
    ready_line = reader.read_line_starting_with('SENSOR_READY', 3.0)
    print(f'sensor init: {ready_line!r}')

    print(f'\nPhase 1/2 starting in {args.lead_s:.0f}s -- keep SW3 OFF (normal operation).')
    time.sleep(args.lead_s)
    normal_rows = capture_phase(connection, reader, 'normal', args.windows, 0.0)

    print(f'\n>>> FLIP SW3 ON NOW <<<  (fault injection phase starts in {args.settle_s:.0f}s)')
    fault_rows = capture_phase(connection, reader, 'fault', args.windows, args.settle_s)

    print('\n>>> FLIP SW3 OFF NOW -- capture done, saving results <<<')
    connection.close()

    rows = normal_rows + fault_rows
    if not rows:
        raise SystemExit('No windows captured -- check sensor wiring and try again.')

    args.out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = args.out_dir / 'feature_capture.csv'
    with csv_path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=['label', 'class', 'match', 'f0', 'f1', 'f2', 'f3'])
        writer.writeheader()
        writer.writerows(rows)
    print(f'\nCSV saved: {csv_path}')

    bands = ['f0', 'f1', 'f2', 'f3']
    fig, axes = plt.subplots(1, 4, figsize=(14, 4), sharey=False)
    colors = {'normal': '#2a9d3f', 'fault': '#d1495b'}
    for axis, band in zip(axes, bands):
        for label in ('normal', 'fault'):
            values = [row[band] for row in rows if row['label'] == label]
            if not values:
                continue
            jitter = [i * 0.02 for i in range(len(values))]
            axis.scatter([0 if label == 'normal' else 1] * len(values), values,
                         color=colors[label], alpha=0.7, label=label, s=40)
        axis.set_xticks([0, 1])
        axis.set_xticklabels(['normal', 'fault'])
        axis.set_title(f'band {band}')
        axis.grid(True, alpha=0.3)
    axes[0].set_ylabel('feature value (0-127)')
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc='upper center', ncol=2)
    fig.suptitle('FFT band features: normal vs fault-injection (real hardware capture)')
    fig.tight_layout(rect=[0, 0, 1, 0.9])

    png_path = args.out_dir / 'feature_distribution.png'
    fig.savefig(png_path, dpi=150)
    print(f'Plot saved: {png_path}')

    normal_classes = [row['class'] for row in rows if row['label'] == 'normal']
    fault_classes = [row['class'] for row in rows if row['label'] == 'fault']
    if normal_classes:
        print(f'normal phase: {sum(1 for c in normal_classes if c == 0)}/{len(normal_classes)} classified class 0')
    if fault_classes:
        print(f'fault phase : {sum(1 for c in fault_classes if c == 1)}/{len(fault_classes)} classified class 1')


if __name__ == '__main__':
    main()
