#!/usr/bin/env python3
"""Compare the original and readable C Golden models, including FFT components.

Recorded frames stay separate from generated software test vectors in the report.
This check does not update MATLAB/XSim gates or saved measurement artifacts.
"""
import csv
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / 'fourier/firmware'
BASELINE = ROOT / 'docs/evidence/golden_model_readability_2026-11-15/golden_before.c'
BASELINE_SHA256 = '55aade8cd80203adb46a904c34099c9bed094e644547fe80980648af5ed06cd3'
RANDOM_SEED = 20261115


class InferenceResult(ctypes.Structure):
    _fields_ = [
        ('re', ctypes.c_int16 * 64),
        ('im', ctypes.c_int16 * 64),
        ('features', ctypes.c_uint8 * 4),
        ('hidden', ctypes.c_uint8 * 4),
        ('logits', ctypes.c_int8 * 2),
        ('class_id', ctypes.c_uint8),
    ]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def recorded_frames(source_runs):
    """Read each original 64-sample window in acquisition order."""
    for run in source_runs:
        path = ROOT / run['file']
        assert sha256(path) == run['sha256'], f'Recorded input changed: {path}'
        with path.open(newline='') as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == run['windows'] * 64, f'Incomplete recording: {path}'
        for window in range(run['windows']):
            samples = []
            for sample_index, row in enumerate(rows[window * 64:(window + 1) * 64]):
                assert row['run_id'] == run['run_id']
                assert int(row['window']) == window
                assert int(row['sample_index']) == sample_index
                samples.append(int(row['raw_x']))
            yield f"{run['run_id']}/{window}", samples


def directed_frames():
    """Software test vectors for sign, rounding, FFT position and saturation."""
    levels = [-32768, -32767, -16384, -1, 0, 1, 16384, 32766, 32767]
    for level in levels:
        yield f'constant/{level}', [level] * 64
    for first, second in [(-32768, 32767), (32767, -32768), (-1, 0), (0, 1)]:
        yield f'alternating/{first}/{second}', [first, second] * 32
    for position in range(64):
        for amplitude in [-32768, -1, 1, 32767]:
            samples = [0] * 64
            samples[position] = amplitude
            yield f'impulse/{position}/{amplitude}', samples
    ramp = [-32768 + index * 1024 for index in range(64)]
    yield 'ascending_ramp', ramp
    yield 'descending_ramp', list(reversed(ramp))


def random_frames():
    """Deterministic verification inputs; these are not measured observations."""
    generator = random.Random(RANDOM_SEED)
    ranges = [(-32768, 32767), (-32, 32), (16128, 16640), (-2048, 2048)]
    for index in range(10000):
        low, high = ranges[index % len(ranges)]
        yield f'random/{index}', [generator.randint(low, high) for _ in range(64)]


def load_model(compiler, source, library_path, symbol):
    command = [compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
               '-fPIC', '-shared', '-fsanitize=undefined',
               '-fno-sanitize-recover=undefined', '-I', str(FIRMWARE)]
    if symbol != 'infer_integer':
        command.append('-Dinfer_integer=' + symbol)
    subprocess.run([*command, str(source), '-o', str(library_path)], check=True)
    library = ctypes.CDLL(str(library_path))
    function = getattr(library, symbol)
    function.argtypes = [ctypes.POINTER(ctypes.c_int16), ctypes.POINTER(InferenceResult)]
    function.restype = None
    return library, function


def compare_frame(before, after, label, samples):
    assert len(samples) == 64 and all(-32768 <= value <= 32767 for value in samples), label
    input_before = (ctypes.c_int16 * 64)(*samples)
    input_after = (ctypes.c_int16 * 64)(*samples)
    result_before = InferenceResult()
    result_after = InferenceResult()
    # Different sentinels expose result fields accidentally left unwritten.
    ctypes.memset(ctypes.byref(result_before), 0xA5, ctypes.sizeof(result_before))
    ctypes.memset(ctypes.byref(result_after), 0x5A, ctypes.sizeof(result_after))
    before(input_before, ctypes.byref(result_before))
    after(input_after, ctypes.byref(result_after))
    assert list(input_before) == samples and list(input_after) == samples, label
    # Compare fields, not C struct padding bytes.
    for field in ['re', 'im', 'features', 'hidden', 'logits']:
        original = list(getattr(result_before, field))
        readable = list(getattr(result_after, field))
        assert original == readable, f'{label}: {field}: {original} != {readable}'
    assert result_before.class_id == result_after.class_id, f'{label}: class'


def main():
    assert sha256(BASELINE) == BASELINE_SHA256, 'Original comparison source changed'
    compiler = shutil.which('gcc')
    if not compiler:
        raise RuntimeError('gcc is required for Golden model comparison')
    dataset = json.loads((ROOT / 'data/dataset_source.json').read_text())
    inputs = [BASELINE, Path(__file__).resolve(), FIRMWARE / 'golden.c',
              FIRMWARE / 'golden.h', FIRMWARE / 'model_data.h',
              ROOT / 'data/cases.csv', ROOT / 'data/dataset_source.json',
              *(ROOT / run['file'] for run in dataset['source_runs'])]
    hashes = {path.relative_to(ROOT).as_posix(): sha256(path) for path in inputs}
    os.environ.setdefault('UBSAN_OPTIONS', 'halt_on_error=1:print_stacktrace=1')
    counts = {}
    with tempfile.TemporaryDirectory(prefix='golden_equivalence_') as folder:
        folder = Path(folder)
        baseline_library, before = load_model(compiler, BASELINE, folder / 'before.so',
                                               'infer_integer_before')
        readable_library, after = load_model(compiler, FIRMWARE / 'golden.c',
                                               folder / 'after.so', 'infer_integer')
        with (ROOT / 'data/cases.csv').open(newline='') as stream:
            fixtures = [(f'fixture/{index}', [int(value) for value in row])
                        for index, row in enumerate(csv.reader(stream))]
        groups = [
            ('existing_fixtures', fixtures),
            ('recorded_windows', recorded_frames(dataset['source_runs'])),
            ('directed_test_vectors', directed_frames()),
            ('random_test_vectors', random_frames()),
        ]
        for group, frames in groups:
            count = 0
            for label, samples in frames:
                compare_frame(before, after, label, samples)
                count += 1
            counts[group] = count
            print(f'PASS {group}: {count} frames', flush=True)
        assert counts['existing_fixtures'] == 20
        assert counts['recorded_windows'] == 360
        assert baseline_library and readable_library
    for path in inputs:
        assert sha256(path) == hashes[path.relative_to(ROOT).as_posix()], path
    report = {
        'status': 'PASS',
        'timestamp_utc': datetime.now(timezone.utc).isoformat(),
        'tool': subprocess.check_output([compiler, '--version'], text=True).splitlines()[0],
        'undefined_behavior_sanitizer': True,
        'random_seed': RANDOM_SEED,
        'groups': counts,
        'total_frames': sum(counts.values()),
        'compared_values_per_frame': 139,
        'fields': ['re[64]', 'im[64]', 'features[4]', 'hidden[4]', 'logits[2]', 'class_id'],
        'note': 'Generated vectors are software verification inputs, not measured observations.',
        'source_sha256': hashes,
    }
    output = ROOT / 'reports/golden_equivalence.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'GOLDEN EQUIVALENCE PASS: {sum(counts.values())} frames, 139 values per frame')


if __name__ == '__main__':
    main()
