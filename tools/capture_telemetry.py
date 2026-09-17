#!/usr/bin/env python3
"""Capture the Zybo motor telemetry stream and optionally start an experiment."""
import argparse
import csv
import time
from dataclasses import dataclass
from pathlib import Path

FRAME_SIZE = 16
SYNC = b'\xa5\x5a'


@dataclass
class Telemetry:
    sequence: int
    reference: int
    measured: int
    duty: int
    integral: int
    flags: int


def decode_frame(frame: bytes) -> Telemetry:
    if len(frame) != FRAME_SIZE or frame[:2] != SYNC:
        raise ValueError('invalid telemetry frame')
    checksum = 0
    for value in frame[:15]:
        checksum ^= value
    if checksum != frame[15]:
        raise ValueError('telemetry checksum mismatch')
    return Telemetry(
        int.from_bytes(frame[2:4], 'little'),
        int.from_bytes(frame[4:6], 'little') & 0x1fff,
        int.from_bytes(frame[6:8], 'little') & 0x1fff,
        int.from_bytes(frame[8:10], 'little') & 0x1fff,
        int.from_bytes(frame[10:14], 'little', signed=True),
        frame[14],
    )


class FrameParser:
    def __init__(self):
        self.buffer = bytearray()
        self.bad_checksums = 0

    def feed(self, data: bytes):
        self.buffer.extend(data)
        frames = []
        while True:
            position = self.buffer.find(SYNC)
            if position < 0:
                self.buffer[:] = self.buffer[-1:] if self.buffer[-1:] == SYNC[:1] else b''
                break
            if position:
                del self.buffer[:position]
            if len(self.buffer) < FRAME_SIZE:
                break
            candidate = bytes(self.buffer[:FRAME_SIZE])
            try:
                frames.append(decode_frame(candidate))
                del self.buffer[:FRAME_SIZE]
            except ValueError:
                self.bad_checksums += 1
                del self.buffer[0]
        return frames


def open_serial(port_name: str, baud: int):
    try:
        import serial
        from serial.tools import list_ports
    except ImportError as error:
        raise SystemExit('pyserial is required: python3 -m pip install pyserial') from error
    if port_name != 'auto':
        return serial.Serial(port_name, baud, timeout=0.1), port_name
    ports = list(list_ports.comports())
    preferred = [p.device for p in ports if
                 'digilent' in ((p.manufacturer or '') + (p.product or '')).lower()]
    candidates = preferred + [p.device for p in ports if p.device not in preferred]
    if not candidates:
        raise SystemExit('No serial port found. Check the Zybo USB cable and permissions.')
    errors = []
    for candidate in candidates:
        try:
            connection = serial.Serial(candidate, baud, timeout=0.1)
            connection.reset_input_buffer()
            return connection, candidate
        except serial.SerialException as error:
            errors.append(f'{candidate}: {error}')
    raise SystemExit('Could not open a serial port:\n' + '\n'.join(errors))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', default='auto', help='serial device or auto')
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--duration', type=float, default=30.0)
    parser.add_argument('--mark-after', type=float, help='print the target-change cue after N seconds')
    parser.add_argument('--second-mark-after', type=float, help='print a second cue after N seconds')
    parser.add_argument('--send-command',
                        help="one or more firmware command chars sent in sequence after "
                             "opening the port (e.g. 'tw' to enable telemetry then arm "
                             "anti-windup); each char must be one of pgGwWtT")
    parser.add_argument('--cpr', type=float, default=988.427)
    parser.add_argument('--output', type=Path, default=Path('artifacts/experiments/telemetry.csv'))
    args = parser.parse_args()

    connection, chosen_port = open_serial(args.port, args.baud)
    decoder = FrameParser()
    records = []
    first_sequence = None
    previous_sequence = None
    dropped = 0
    marked = False
    second_marked = False
    connection.reset_input_buffer()
    if args.send_command:
        if not set(args.send_command) <= set('pgGwWtT'):
            raise SystemExit("--send-command chars must be one of pgGwWtT")
        for char in args.send_command:
            connection.write(char.encode('ascii'))
            connection.flush()
            time.sleep(0.05)
        if set(args.send_command) & set('tT'):
            # A 't'/'T' resets the frame sequence immediately, but the board may
            # already have been streaming from an earlier, unrelated session with
            # nobody reading the port; drain whatever arrived in the round trip
            # so a stale, far-future sequence number never gets decoded as one
            # enormous apparent drop against the freshly reset one.
            time.sleep(0.2)
            connection.reset_input_buffer()
    start_time = time.monotonic()
    print(f'CAPTURE START {chosen_port} {args.baud} baud for {args.duration:.1f} s', flush=True)
    try:
        while time.monotonic() - start_time < args.duration:
            elapsed_wall = time.monotonic() - start_time
            if args.mark_after is not None and not marked and elapsed_wall >= args.mark_after:
                print('EVENT 1 NOW', flush=True)
                marked = True
            if (args.second_mark_after is not None and not second_marked and
                    elapsed_wall >= args.second_mark_after):
                print('EVENT 2 NOW', flush=True)
                second_marked = True
            for item in decoder.feed(connection.read(512)):
                if first_sequence is None:
                    first_sequence = item.sequence
                if previous_sequence is not None:
                    dropped += ((item.sequence - previous_sequence) & 0xffff) - 1
                previous_sequence = item.sequence
                sample_number = (item.sequence - first_sequence) & 0xffff
                full_scale_rpm = 1800.0 * 60.0 / args.cpr
                records.append({
                    'sample': sample_number,
                    'time_s': sample_number / 100.0,
                    'reference_q12': item.reference,
                    'measured_q12': item.measured,
                    'duty_q12': item.duty,
                    'integral_q12': item.integral,
                    'armed': item.flags & 1,
                    'fault': (item.flags >> 1) & 1,
                    'enabled': (item.flags >> 2) & 1,
                    'target_rpm': item.reference * full_scale_rpm / 4096.0,
                    'measured_rpm': item.measured * full_scale_rpm / 4096.0,
                    'duty_percent': item.duty * 100.0 / 4096.0,
                })
    finally:
        connection.close()
    if not records:
        raise SystemExit('No valid telemetry frames. Program the extension build and arm the motor.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=records[0].keys())
        writer.writeheader()
        writer.writerows(records)
    print(f'CAPTURE PASS frames={len(records)} dropped={dropped} '
          f'bad_checksum={decoder.bad_checksums} output={args.output}')


if __name__ == '__main__':
    main()
