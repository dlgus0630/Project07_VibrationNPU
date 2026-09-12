#!/usr/bin/env python3
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from model import features, fft64, npu

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'data'


def read_mem(name, bits, signed=False):
    values = np.array([int(line, 16) for line in (DATA / name).read_text().split()], dtype=np.int64)
    if signed:
        values = np.where(values >= 2 ** (bits - 1), values - 2 ** bits, values)
    return values


def main():
    model = json.loads((DATA / 'model.json').read_text())
    cases = np.loadtxt(DATA / 'cases.csv', delimiter=',', dtype=int, ndmin=2)
    expected_real = read_mem('fft_re.mem', 16, True).reshape(-1, 64)
    expected_imag = read_mem('fft_im.mem', 16, True).reshape(-1, 64)
    expected_feature = read_mem('features.mem', 8).reshape(-1, 4)
    expected_hidden = read_mem('hidden.mem', 8, True).reshape(-1, 4)
    expected_logits = read_mem('logits.mem', 8, True).reshape(-1, 2)
    expected_class = read_mem('class.mem', 8)
    max_error = 0.0
    for index, case in enumerate(cases):
        real, imag, _ = fft64(case)
        feature = features(case)
        hidden, logits, classification = npu(feature, model)
        assert np.array_equal(real, expected_real[index])
        assert np.array_equal(imag, expected_imag[index])
        assert np.array_equal(feature, expected_feature[index])
        assert np.array_equal(hidden, expected_hidden[index])
        assert np.array_equal(logits, expected_logits[index])
        assert classification == expected_class[index]
        exact = np.fft.fft(case) / 64
        max_error = max(max_error, float(np.max(np.abs(np.array(real) + 1j * np.array(imag) - exact))))
    assert max_error < 16

    c_result = 'NOT RUN: gcc unavailable'
    compiler = shutil.which('gcc')
    if compiler:
        with tempfile.TemporaryDirectory(prefix='vibration_c_') as folder:
            executable = str(Path(folder) / 'host_check')
            build = subprocess.run([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                                    '-fsanitize=undefined', str(ROOT / 'fourier/firmware/golden.c'),
                                    str(ROOT / 'fourier/firmware/host_check.c'), '-o', executable],
                                   capture_output=True, text=True)
            assert build.returncode == 0, build.stderr
            run = subprocess.run([executable], cwd=ROOT, capture_output=True, text=True)
            assert run.returncode == 0 and not run.stderr, (run.stdout, run.stderr)
            c_result = run.stdout.strip()

    report = {'cases': len(cases), 'fft_max_complex_error_lsb': max_error, 'host_c': c_result}
    output = ROOT / 'reports'
    output.mkdir(exist_ok=True)
    (output / 'offline_report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    print('OFFLINE CHECK PASS; MATLAB and XSim gates are unchanged.')


if __name__ == '__main__':
    main()

