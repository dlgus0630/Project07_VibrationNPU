# 성능 기록

2026-09-12, Zybo Z7-20, PL 100 MHz, ARM D-cache OFF, 제공 replay 100회 기준이다.

| 항목 | 결과 |
|---|---:|
| CPU 정수 기준 계산 | min 849 / median 850 / max 852 us |
| PL FFT+NPU+BRAM | 833 cycle, 8.33 us |
| NPU | 18 cycle |
| 전송·비교 포함 가속기 구간 | min 26 / median 26 / max 27 us |
| CPU-PL 전체 tensor 일치 | 100/100 |

자원은 LUT 10,626, FF 7,246, DSP 5, BRAM tile 1이다. 최종 timing은 setup `+0.178 ns`,
hold `+0.035 ns`, DRC Error 0이다. 원본은 `artifacts/uart_benchmark_100_v5.csv`, 구현 보고서는
`artifacts/timing.rpt`와 `artifacts/utilization.rpt`에 있다.

