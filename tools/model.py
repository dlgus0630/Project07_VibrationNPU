"""Independent integer FFT and NPU reference."""
import math
import numpy as np


def sat(value, low, high):
    return max(low, min(high, int(value)))


def twiddles():
    return [(sat(round(32768 * math.cos(-2 * math.pi * k / 64)), -32768, 32767),
             sat(round(32768 * math.sin(-2 * math.pi * k / 64)), -32768, 32767))
            for k in range(32)]


def fft64(samples):
    assert len(samples) == 64
    real = [int(samples[int(f'{index:06b}'[::-1], 2)]) for index in range(64)]
    imag = [0] * 64
    stages = []
    table = twiddles()
    for stage in range(1, 7):
        span = 1 << stage
        half = span // 2
        for base in range(0, 64, span):
            for offset in range(half):
                a = base + offset
                b = a + half
                wr, wi = table[offset * 64 // span]
                tr = (real[b] * wr - imag[b] * wi) >> 15
                ti = (real[b] * wi + imag[b] * wr) >> 15
                ar, ai = real[a], imag[a]
                real[a] = sat((ar + tr) >> 1, -32768, 32767)
                imag[a] = sat((ai + ti) >> 1, -32768, 32767)
                real[b] = sat((ar - tr) >> 1, -32768, 32767)
                imag[b] = sat((ai - ti) >> 1, -32768, 32767)
        stages.append((real.copy(), imag.copy()))
    return real, imag, stages


def features(samples):
    real, imag, _ = fft64(samples)
    return [min(127, sum(abs(real[k]) + abs(imag[k]) for k in range(first, last + 1)) >> 5)
            for first, last in [(1, 6), (7, 12), (13, 20), (21, 31)]]


def npu(feature, model):
    x = np.array(feature, dtype=np.int64)
    acc1 = np.array(model['w1'], dtype=np.int64) @ x + model['b1']
    hidden = np.clip(acc1 >> model['shift1'], 0, 127)
    acc2 = np.array(model['w2'], dtype=np.int64) @ hidden + model['b2']
    logits = np.clip(acc2 >> model['shift2'], -128, 127)
    return hidden.tolist(), logits.tolist(), int(logits[1] > logits[0])

