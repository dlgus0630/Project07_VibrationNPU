# Project07_VibrationNPU

Zybo Z7-20에서 MPU-6500/9250의 진동 데이터를 수집하고, PL의 64-point FFT와 소형 INT8 NPU로
두 상태를 분류하고 모터 안전 제어와 통합하는 FPGA/SoC 포트폴리오 프로젝트다.

## 구조

```text
MPU-6500/9250 -> SPI -> ARM Cortex-A9
                    |
                    v
              AXI + Dual-port BRAM
                    |
                    v
          FFT64 -> 4-band feature -> 4x4x2 INT8 NPU
                    |
                    v
                  UART
```

- PS: 센서 설정, 64개 sample 수집, BRAM 전송, 가속기 시작, 결과 출력
- PL: radix-2 FFT, 주파수 대역 특징, 2개 MAC PE 기반 MLP 추론
- 별도 모터 출력: L298N에 20 kHz PWM을 제공하고 SW3로 32 Hz 토크 리플 fault injection
- 학습: PC에서만 수행하며 FPGA는 inference만 수행
- HDL: 직접 작성한 Verilog-2001, HDL Coder 미사용

## 검증 결과

| 항목 | 결과 |
|---|---:|
| 실제 데이터 | 정상 3 run 180 window, 토크 리플 3 run 180 window |
| 분리 방법 | run 1/2 학습, run 3 검증; 인접 window 혼합 없음 |
| FP32 검증 정확도 | 99.17% (119/120) |
| INT8 검증 정확도 | 98.33% (118/120) |
| INT8 혼동행렬 | normal 58/60, injected fault 60/60 |
| 독립 C/정수 Golden | 20 window, 2,560 FFT component, 220 result PASS |
| 재학습 전 MATLAB/Simulink | 20/20 PASS |
| 재학습 전 XSim | 6개 testbench PASS |
| fault-injection bit timing | setup +0.010 ns, hold +0.032 ns, DRC Error 0 |
| 해당 bit 구현 자원 | LUT 10,628, FF 7,270, DSP 5, BRAM 1 |
| Zybo replay | 100/100 CPU-PL 일치 |
| 실물 센서 | MPU-6500, WHO_AM_I `0x70`, 초기화 PASS |
| 실측 sample 간격 | 평균 998.921 us, 994..1004 us |
| 재학습 전 실측 sensor FFT/NPU | CPU-PL 일치, 833 cycle |
| PL FFT+NPU | 833 cycle = 8.33 us @ 100 MHz |
| NPU 구간 | 18 cycle |
| 가속기 전체 구간 | 26-27 us |

실측 분류의 class 1은 자연 발생 베어링 고장이 아니라 PL이 만든 `25%<->75% @ 32 Hz` 토크 리플이다.
정상 조건은 50% 고정 duty이며 두 조건 모두 12.0 V와 평균 duty 50%를 사용했다. 재학습으로
`data/`와 펌웨어 모델 상수가 바뀌었으므로 최종 MATLAB/Simulink, XSim, implementation과 Zybo
실측은 다시 수행해야 한다. 완료 전에는 위의 재학습 전 gate 결과를 새 모델의 결과로 해석하지 않는다.

## 실행

MATLAB Online에서 프로젝트 전체를 업로드한 뒤 실행한다.

```matlab
cd Project07_VibrationNPU
RUN_MATLAB_CHECKS
```

PC 검증과 Vivado 실행:

```text
python3 -m pip install -r requirements.txt
python3 tools/offline_check.py
python3 tools/run.py sim
python3 tools/run.py build
```

실제 MPU-6500/9250 데이터는 독립 run으로 수집하고 분리한다. 수집 명령, 최소 반복 횟수와 재학습 절차는
[docs/REAL_DATASET.md](docs/REAL_DATASET.md)를 따른다.

실측 분류 데이터는 정상 `50%` 고정 duty와 fault injection `25%<->75% @ 32 Hz`를 비교한다.
두 조건의 평균 duty와 전원 전압은 같으며, 이 조건은 자연 발생 베어링 고장이 아니라 PL이 만든
재현 가능한 토크 리플 시험 자극으로 기록한다. SW0은 arm, SW2..1은 정상 duty, SW3는 fault injection,
BTN0은 비상 정지다.

Vivado 2024.2와 Digilent Zybo Z7-20 board files가 필요하다. Vivado가 PATH에 없으면 `VIVADO`에
실행 파일 경로를, 보드 파일을 별도로 설치했다면 `DIGILENT_BOARD_REPO`에 `new/board_files` 경로를
지정한다. Vitis 실행과 UART 명령은 [docs/VITIS_2024_2.md](docs/VITIS_2024_2.md)를 따른다.

## 폴더

| 경로 | 내용 |
|---|---|
| `fourier/rtl` | FFT, NPU, AXI, SPI, 모터 PWM RTL |
| `fourier/tb` | 자동 PASS/FAIL testbench 6개 |
| `fourier/firmware` | ARM 앱과 독립 C 기준 모델 |
| `data` | 학습 데이터, 정수 가중치, test vector |
| `matlab` | MATLAB Golden 및 Simulink 함수 |
| `vivado` | 프로젝트 생성, XSim, bitstream Tcl |
| `tools` | 학습, 검증, UART 실측 데이터 수집 도구 |
| `artifacts` | 통과한 bit/XSA/ELF, 보고서, 보드 측정 결과 |
| `HANDOFF.md` | 다음 작업자가 먼저 읽을 진행 기록 |

실물 배선 전에는 [docs/HARDWARE.md](docs/HARDWARE.md)를 확인한다. 센서 breakout 전압과 L298N
점퍼 상태를 확인하기 전까지 12 V 출력을 켜지 않는다.
