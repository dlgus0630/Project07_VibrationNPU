# Zybo Z7 NPU 가속기 : 실측 진동 분류 기반 모터 제어 시스템

### Measured-Vibration Classification and Closed-Loop Motor Control on Zynq-7000

![사용자 제공 NPU 프로젝트 실물 구성 메인 이미지](docs/images/npu_hardware_main.png)

사용자 제공 대표 이미지: Zybo Z7, 모터 드라이버·모터, 전원 공급기와 오실로스코프 구성.
정량 검증값은 아래 원본 계측 사진과 보고서를 기준으로 합니다.

**실측 진동 → 64-point FFT → INT8 신경망 → 경고·출력 제한·정지까지 연결한 FPGA/SoC 시스템**

MPU-6500으로 모터 하우징의 진동을 수집하고, Zybo Z7-20의 PL에서 주파수 특징 추출과
신경망 추론을 수행합니다. 같은 FPGA에서 인코더 속도 추정, PI 제어, PWM, 안전 supervisor를
실행해 진동 분류와 모터 제어를 한 보드에 통합했습니다. ARM은 센서 설정·데이터 이동·로그를 담당합니다.

> **Zybo Z7-20 / PL 100 MHz / FFT+NPU 833 cycles / INT8 검증 118/120**<br>
> **2026-09-17에 저장된 구현 결과: WNS +0.091 ns · WHS +0.020 ns · DRC Error 0**

분류 대상은 **정상 운전과 의도적으로 주입한 32 Hz 토크 리플**입니다. 자연 발생 베어링 고장에 대한
진단 성능을 측정한 프로젝트는 아닙니다. 검증 절의 화면은 실제 Vivado/XSim 캡처와 오실로스코프 사진이며,
검증 시점과 원본 파일을 [화면·보고서 출처](docs/SCREENSHOT_PROVENANCE.md)에 기록했습니다.

## 0. 목차

1. [동작 시나리오](#1-동작-시나리오)
2. [핵심 기술 요약](#2-핵심-기술-요약)
3. [프로젝트 개요](#3-프로젝트-개요)
4. [주요 기능](#4-주요-기능)
5. [시스템 구성](#5-시스템-구성)
6. [아키텍처](#6-아키텍처)
7. [FFT와 INT8 MLP 데이터 형식](#7-fft와-int8-mlp-데이터-형식)
8. [AXI4-Lite 인터페이스](#8-axi4-lite-인터페이스)
9. [모터·안전 제어](#9-모터안전-제어)
10. [처리 순서와 상태 전이](#10-처리-순서와-상태-전이)
11. [실행 구조와 소스 구성](#11-실행-구조와-소스-구성)
12. [핵심 설계 포인트](#12-핵심-설계-포인트)
13. [Troubleshooting](#13-troubleshooting)
14. [검증 및 성능 분석](#14-검증-및-성능-분석)
15. [빌드와 소프트웨어 연동](#15-빌드와-소프트웨어-연동)

## 1. 동작 시나리오

1. ARM이 MPU-6500의 X축 raw 64개를 수집하고 공유 BRAM에 기록합니다.
2. AXI START를 받은 PL이 FFT, 4개 대역 특징, INT8 MLP를 순서대로 계산합니다.
3. PL의 safety supervisor가 분류 완료 시점마다 연속 이상 횟수를 갱신합니다.
4. 이상 1회는 warning, 2회 연속이면 요청 PWM을 최대 25%로 제한하고, 3회 연속이면 정지 상태를 유지합니다.
5. ARM heartbeat가 500 ms 동안 끊어져도 PL이 독립적으로 모터를 차단합니다.
6. SW0 OFF로 latch를 해제한 뒤 ON으로 다시 arm합니다. 정상 판정만으로 정지 상태가 풀리지는 않습니다.

모터 속도 제어는 encoder C1 → hybrid 속도 추정 → PI/anti-windup → PWM 경로로 실행됩니다.
Encoder C2는 방향·illegal transition·timeout·overflow를 관측하며 PI 피드백에는 사용하지 않습니다.

## 2. 핵심 기술 요약

| 영역 | 구현 내용 | 설계 의도 |
|---|---|---|
| SoC 분담 | Cortex-A9 + AXI4-Lite + dual-port BRAM | 데이터 수집과 정수 가속 경로 분리 |
| 주파수 분석 | 64-point radix-2 FFT, Q1.15 twiddle | FPGA에 맞는 고정소수점 연산과 중간값 검증 |
| 신경망 | `4 → 4 ReLU → 2`, INT8, MAC PE 2개 | 작은 구조로 누산·포화·재양자화 과정을 추적 |
| 제어 | hybrid encoder 추정, PI, anti-windup, 20 kHz PWM | 같은 PL에서 속도 피드백과 출력 제한 처리 |
| 안전 | 연속 이상 판정, latch, PS heartbeat watchdog | 분류 결과와 PS 정지를 각각 감시 |
| 실험 | 런타임 Kp/Ki, open-loop override, telemetry | 재합성 없이 게인 비교·시스템 식별 |
| 검증 | MATLAB/C/RTL 비교, XSim, post-route, 실물 측정 | 계산·논리·타이밍·물리 응답을 단계별 확인 |

현재 FPGA 회로는 **VHDL**로 구현합니다. 기존 Verilog-2001 회로는 변환 전후 비교 기준으로
보존했습니다. 정수 형식·가중치·레지스터 주소·상태 전이와 처리 사이클을 유지했으며,
ARM의 공개 인터페이스와 모델 상수, 기존 실측 자료도 유지합니다.
C 골든 모델은 [역할별 함수](fourier/firmware/README.md)로 정리하고 원본과 모든 결과 필드를 비교합니다.
ARM 앱은 플랫폼·센서·추론·텔레메트리·모터 명령을 나누고, `main.c`에는 초기화와 명령 분기를 둡니다.
[VHDL 전환과 검증](docs/VHDL_MIGRATION.md)

회로는 최상위 `*_struct.vhd`와 기능별 `*_fsm.vhd`·`*_rtl.vhd`로 나누었습니다.
상태·계산·카운터를 이름 있는 프로세스로 구분했으며,
[모듈 연결과 프로세스 구성](fourier/vhdl/README.md)에서 실제 파일로 이동할 수 있습니다.

HDL Coder를 사용하지 않으며, 학습은 PC에서 수행하고 FPGA에는 추론만 구현했습니다.
DMA와 cache coherence는 구현 범위에 포함하지 않습니다.

## 3. 프로젝트 개요

| 항목 | 내용 |
|---|---|
| 프로젝트명 | Project07_VibrationNPU |
| 대상 보드 / 소자 | Digilent Zybo Z7-20 / XC7Z020-1CLG400C |
| CPU / PL clock | ARM Cortex-A9 / 100 MHz |
| 센서 / 입력 | MPU-6500 X축 signed INT16, 64 samples/frame |
| NPU | 4→4→2 INT8 MLP, MAC PE 2개 |
| 분류 결과 | normal / injected torque ripple |
| 제어 대상 | L298N + encoder DC motor |
| 개발 도구 | MATLAB·Simulink, Vivado 2024.2, XSim, Vitis, Python |
| 원본 검증 데이터 | 정상·주입 이상 각 3 runs, 총 360 windows |

진동 분류의 계산 일치, 분류 성능, 안전 동작, 모터 응답을 각각 검증합니다.
MPU-6500의 X축으로 학습한 모델이며, 다른 센서 위치나 자연 발생 고장으로의 일반화는 별도 실험 대상입니다.

## 4. 주요 기능

- **실측 입력 수집**: 샘플 간격과 원본 CSV 출처를 함께 기록합니다.
- **고정소수점 FFT/NPU**: butterfly부터 logits까지 정수 Golden과 비교합니다.
- **NPU 중간값 관측**: FFT real/imag, 4-band feature, hidden, logits, class를 분리해 확인합니다.
- **폐루프 제어**: 인코더 속도 추정과 PI/anti-windup을 PL에 구현합니다.
- **단계별 안전 출력**: warning → 25% 제한 → latch 정지와 독립 heartbeat watchdog을 제공합니다.
- **실험 재현**: 기존 실측 run과 모터 telemetry를 별도 MATLAB·Simulink 모델에서 재생합니다.
- **설명 가능한 코드**: 함수 입출력·단위·수식·주의점을 한국어 `% [주N]` 각주로 읽을 수 있습니다.

## 5. 시스템 구성

```mermaid
flowchart LR
    IMU[MPU-6500 X축] --> SPI[SPI controller]
    SPI <--> PS[ARM Cortex-A9]
    PS <-->|AXI| BRAM[Dual-port BRAM]
    BRAM --> FFT[FFT64 + 4-band feature]
    FFT --> NPU[INT8 NPU · 2 PE]
    NPU --> SUP[Safety supervisor]
    PS -->|100 ms heartbeat| SUP
    ENC[Encoder C1] --> EST[Hybrid speed estimator]
    EST --> PI[PI + anti-windup]
    PI --> LIMIT[Duty limit / latch]
    SUP --> LIMIT
    LIMIT --> PWM[20 kHz PWM]
    PWM --> DRIVER[L298N + DC motor]
    DRIVER --> ENC
    C2[Encoder C1/C2] --> QUAD[Quadrature diagnostics]
```



| 보드 연결 | 용도 |
|---|---|
| JE1–4 | MPU-6500 SPI: SCLK, MOSI, MISO, CS |
| JD1–3 | L298N: PWM/ENA, IN1, IN2 |
| JD4 / JD7 | Encoder C1 / C2 |
| SW0 / BTN0 | arm·clear / 정지 |
| SW3 | 25%↔75%, 32 Hz 토크 리플 주입 |

센서 WHO_AM_I 실측은 `0x70`으로 MPU-6500입니다. 배선·전압·스위치 모드는
[하드웨어 가이드](docs/HARDWARE.md)와 [제어 확장 실험](docs/CONTROL_EXTENSION_EXPERIMENT.md)을 따릅니다.
초기 고정 duty 시험과 최종 PI 속도 제어 모드는 구분해서 해석합니다.

## 6. 아키텍처

### 6-1. Zynq PS/PL 실제 Block Design


![Vivado에서 연 실제 system.bd 블록 디자인](docs/images/vivado_block_design.png)

저장된 `build/fourier/.../system.bd`를 Vivado 2024.2에서 연 화면입니다. Processing System,
AXI interconnect, BRAM controller/memory, 직접 작성한 accelerator와 motor 모듈의 실제 연결을 보여 줍니다.
[확대 가능한 Vivado 원본 SVG](docs/images/vivado_block_design.svg)도 함께 제공합니다.

현재 VHDL의 모듈명·신호명·비트 폭·전달 방향은
[모듈·신호 구조도 3장과 전체 신호표](docs/architecture/README.md)에서 확인할 수 있습니다.
실행 순서와 조건은 [핵심 FSM 4장 및 시스템별 동작도 7장](docs/state_diagrams/README.md)에 정리했습니다.


### 6-2. 기존 MATLAB·Simulink 정수 NPU 모델

![실제 저장된 Simulink NPU 모델의 원본 내장 미리보기](docs/images/simulink_npu_verified_thumbnail.png)

위 그림은 **2026-09-17 MATLAB R2026a에서 저장된 `.slx`의 내장 원본 미리보기**입니다.
해상도가 작은 원본이며 새 모델을 실행한 화면은 아닙니다.
[해당 Simulink 모델](docs/evidence/2026-09-17_fourier_npu_algorithm.slx)을 열면 각 블록을 확대해 볼 수 있습니다.

```mermaid
flowchart LR
    A["Samples<br/>INT16 64×1"] --> B["FFT64<br/>Re 64 + Im 64"]
    B --> C["Band_features<br/>4×1, 0..127"]
    C --> D["Hidden_ReLU<br/>4×1, 0..127"]
    D --> E["Output_requantize<br/>2×1, -128..127"]
    E --> F["Logits<br/>To Workspace"]
```

| 실제 블록명 | 계산과 확인 항목 | 대응 코드 |
|---|---|---|
| `Samples` | `VIB_INPUT` 원본 64개, DC 포함 | `RUN_MATLAB_CHECKS.m` |
| `FFT64` | scaled radix-2 FFT, Re/Im 순서로 128개 출력 | `fourier_fft_sl.m`, `fft64_fixed.m` |
| `Band_features` | 4개 대역의 L1 합 → shift → 포화 | `fourier_features_sl.m` |
| `Hidden_ReLU` | `floor((W1*f+b1)/2^shift1)` → ReLU·포화 | 모델에 포함된 정수 가중치 |
| `Output_requantize` | `floor((W2*h+b2)/2^shift2)` → signed INT8 포화 | 모델에 포함된 정수 가중치 |
| `Logits` | 두 최종 점수를 MATLAB Golden과 비교 | `sl_logits` |

기존 검증은 20개 case를 MATLAB 함수와 Simulink에 차례로 넣고, FFT 성분과 층별 정수 값을 검사합니다.
MATLAB/Simulink의 블록 실행 시간은 RTL의 18-cycle NPU 지연을 뜻하지 않습니다. cycle 수는 별도로 XSim과 보드에서 확인합니다.

### 6-3. 2차 실측 전용 Simulink 구조

아래는 [`build_measured_models.m`](matlab/measured/build_measured_models.m)의 연결을 설명한 도식입니다.
이 새 모델의 실제 GUI 캡처는 MATLAB에서 생성·실행한 뒤 내보내도록 구성했습니다.

```mermaid
flowchart LR
    RAW["01 Verified recorded windows<br/>CSV hash / raw / dt / metadata"] --> FFT["02 FPGA integer FFT features"]
    FFT --> NPU["03 Existing trained INT8 NPU"]
    RAW --> QC["04 Measured frame quality"]
    RAW --> CMP["05 Recorded label comparison"]
    NPU --> CMP
    FFT --> LOG["06 Exact replay logs"]
    NPU --> LOG
    QC --> LOG
    CMP --> LOG
```

| 계층 | 들어가는 기록 | 나오는 값과 읽는 이유 |
|---|---|---|
| `01_Verified_recorded_windows` | 원본 64 counts, `dt_us`, window ID·label·host 시각 | 보간 없이 원본 프레임과 시간 메타데이터를 분리 |
| `02_FPGA_integer_FFT_features` | raw 64개 | FFT Re/Im 128개와 4-band feature, FPGA와 동일 전처리 |
| `03_Existing_trained_INT8_NPU` | feature 4개, 기존 `model.json` | hidden 4개, logits 2개, 동점 class 0 |
| `04_Measured_frame_quality` | raw와 실제 샘플 간격 | DC, AC RMS, ADC rail count, dt 평균·최소·최대·흔들림 |
| `05_Recorded_label_comparison` | 예측과 기록 label | truth/prediction/correct; 재학습 없이 기존 검증 재현 |
| `06_Exact_replay_logs` | 모든 중간 신호 | MATLAB 배열과 원본·정수 중간값이 같은지 비교 |

모터 기록은 `measured_motor_telemetry_replay`에서 따로 재생합니다.
`Original_motor_telemetry → Recorded_control_channels → Recorded_speed_PWM_integral`로
목표·실제 속도·PWM·적분값과 arm/fault/enabled를 표시합니다. 새 plant 응답을 만들거나 서로 다른
실험의 진동과 모터 데이터를 같은 시각에 측정한 것처럼 연결하지 않습니다.

**재생 tick 1개는 원본 record 1개**입니다. 진동 window 사이의 미측정 구간을 채우지 않으며,
모터의 `time_s=sample/100`은 원본 수집 프로그램의 명목 시간입니다.

## 7. FFT와 INT8 MLP 데이터 형식

| 단계 | 형식·크기 | 처리 |
|---|---|---|
| 센서 입력 | signed INT16 × 64 | ±2 g 설정, 16384 count/g |
| FFT | signed INT16 real/imag | bit-reversed load, 6단 butterfly마다 `/2`, 최종 `FFT(x)/64` |
| 대역 특징 | 4개 | bin `1..6`, `7..12`, `13..20`, `21..31`의 `abs(Re)+abs(Im)` 합 |
| 특징 양자화 | 0..127 | 대역 합을 5-bit 우시프트 후 포화 |
| 은닉층 | INT8 weight, INT32 누산 | 4×4 MAC, shift, ReLU, 0..127 포화 |
| 출력층 | signed INT8 logits × 2 | 2×4 MAC, shift, -128..127 포화 |
| 분류 | 0 또는 1 | class 1 점수가 더 클 때만 1, 동점이면 0 |

명목 1 kHz에서 FFT bin 간격은 15.625 Hz입니다. 특징은 대역별 L1 크기 합이며 PSD와는 다른 값입니다.
하드웨어 재현 경로에는 DC가 포함된 원본 입력을 그대로 넣는다. MATLAB의 진단용 PSD는 평균 제거와
Hann 창을 별도로 적용한다. 수치 계약은 [DESIGN.md](DESIGN.md), 읽기 설명은
[스터디 코드 각주 안내](docs/STUDY_CODE_NOTES.md)에 있습니다.

## 8. AXI4-Lite 인터페이스

AXI control base는 `0x43C00000`, 공유 BRAM base는 `0x40000000`이며 각각 4 KiB입니다.

| 주소/영역 | 역할 |
|---|---|
| control `+0x00` | START, DONE/error clear |
| status `+0x04` | busy, done, rejected-start, latch, warning, derated, watchdog |
| `+0x08 / +0x0C / +0x10` | class / 전체 cycle / NPU cycle |
| `+0x20..0x2C / +0x30..0x34` | feature / logits |
| `+0x40 / +0x44` | SPI command / response |
| `+0x48 / +0x4C` | heartbeat / safety telemetry |
| BRAM word `0..63` | 입력 samples |
| BRAM word `256..266` | feature, hidden, logits, class |

START는 idle에서만 수락하고 DONE은 결과 기록이 끝난 뒤 올라갑니다. AXI AW/W를 독립 수신하며
B/R backpressure 동안 응답을 유지합니다. PS는 가속기 busy 동안 BRAM을 접근하지 않습니다.
런타임 PI·encoder 확장 레지스터는 [실험 가이드](docs/CONTROL_EXTENSION_EXPERIMENT.md)에서 확인합니다.

## 9. 모터·안전 제어

| 조건 | 출력과 상태 |
|---|---|
| 정상, arm 완료 | PI 요청 duty 적용 |
| class 1 첫 번째 | warning, duty 제한 없음 |
| class 1 두 번째 연속 | warning + derated, duty 최대 25% |
| class 1 세 번째 연속 | classifier latch, PWM·구동 출력 차단 |
| latch 이전 class 0 | 연속 횟수·warning·derated 복구 |
| arm 중 heartbeat 500 ms 단절 | watchdog latch, 분류와 독립 차단 |
| latch 이후 class 0 | 정지 상태 유지 |
| SW0 OFF → ON | clear 후 재arm |

안전 판단은 분류 완료 이벤트마다 갱신합니다. `3 × 64 samples`를 실제 종단 차단 지연으로
간주하지 않습니다. 종단 차단 지연에는 윈도우 수집·호스트 명령·전송 사이의 간격도 포함됩니다.
자세한 상태 전이는 [안전 supervisor 설계](docs/SAFETY_SUPERVISOR.md)에 있습니다.

## 10. 처리 순서와 상태 전이

```mermaid
flowchart LR
    IDLE[IDLE] -->|START| LOAD[BRAM input read]
    LOAD --> FFT[FFT64]
    FFT --> FEAT[4-band feature]
    FEAT --> HIDDEN[Hidden MAC + ReLU]
    HIDDEN --> OUT[Output MAC + requantize]
    OUT --> STORE[BRAM result write]
    STORE --> DONE[DONE / class valid]
    DONE --> IDLE
```

가속기는 입력·계산·결과 기록의 소유권을 순서대로 넘깁니다. 계산 중 재시작 요청을 거부하고,
최종 결과를 기록한 뒤 DONE을 내므로 ARM이 중간 결과를 완료 결과로 읽지 않게 합니다.
안전 supervisor는 `class_valid`가 있는 사이클에만 분류 횟수를 갱신하고 heartbeat는 독립적으로 감시합니다.

## 11. 실행 구조와 소스 구성

| 경로 | 내용 |
|---|---|
| [`fourier/vhdl`](fourier/vhdl/) / [`common/reset_sync.vhd`](common/reset_sync.vhd) | 현재 VHDL 회로와 Vivado 연결용 최상위 파일 |
| [`fourier/rtl`](fourier/rtl/) | 보존된 기존 Verilog 회로, 동등성 비교 기준 |
| [`fourier/tb`](fourier/tb/) / [`fourier/tb_vhdl`](fourier/tb_vhdl/) | 기존 테스트와 VHDL의 기준값·클록별 비교 검사 |
| [`fourier/firmware`](fourier/firmware/) | ARM 앱과 C 기준 모델 |
| [`data`](data/) / [`measurements`](measurements/) | 모델·정수 vector / 실측 원본 |
| [`matlab`](matlab/) | 정수 Golden, Simulink 함수, 연구·실측 스터디 |
| [`vivado`](vivado/) / [`tools`](tools/) | 프로젝트·시뮬레이션·구현 Tcl / 학습·검증·수집 도구 |
| [`docs/images`](docs/images/) / [`docs/evidence`](docs/evidence/) | 실제 화면 / 최종 보고서·회귀 로그 사본 |
| [`artifacts`](artifacts/) | bit/XSA/ELF, 실험 기록, MATLAB 입력 ZIP |

## 12. 핵심 설계 포인트

| 설계 선택 | 이유와 검증 경계 |
|---|---|
| 매 FFT stage의 `/2` | 중간 정수 폭을 제한하며 최종 스케일을 `FFT/64`로 고정합니다. |
| signed floor·포화 규칙 고정 | 음수 shift와 overflow 차이가 추론 오차로 이어지지 않게 합니다. |
| MAC PE 2개 재사용 | 작은 4→4→2 모델의 구조와 cycle을 직접 검증하기 쉽습니다. |
| 학습/검증을 run별 분리 | 같은 acquisition의 인접 window가 양쪽에 섞이는 것을 막습니다. |
| 연속 이상과 latch | 단발 오검출과 지속 이상을 구분하고 정상 판정만으로 재기동하지 않습니다. |
| 수치 모델·실측 재생 분리 | 가정한 XYZ 응답을 센서로 측정한 3축 운동이라고 표현하지 않습니다. |
| 원본 해시·기록 보존 | 그림의 값과 구현 revision을 원본 파일로 추적합니다. |

## 13. Troubleshooting

| 관측한 문제 | 확인 과정 | 조치·교훈 |
|---|---|---|
| 이상 검출률이 15%로 저하 | CPU–PL 일치, 샘플 주기 정상, 주파수 대역 에너지 이동 확인 | 센서 재고정 후 이상 60/60; 나사 풀림 자체는 미확인 |
| 500 ms watchdog이 1.5 s처럼 관측 | watchdog counter를 AXI로 직접 노출 | 452..508 ms 확인; 외부 증상으로 잰 이전 시간의 오류 |
| 통합 후 critical path 위반 | PI anti-windup 가산기와 encoder 곱셈·clamp 경로 확인 | 파이프라인 추가, 정수 결과·완료 타이밍 회귀 검증 |
| 게인 변경마다 재합성 필요 | Kp/Ki/anti-windup을 AXI 레지스터로 확장 | 같은 bitstream에서 A/B 비교·식별 실험 가능 |

자세한 원인 배제 과정과 단계별 수치는 [이전 README 기록](docs/README_VALIDATION_HISTORY.md)과
[HANDOFF](HANDOFF.md)에 남겼습니다. 현재 구현 수치는 위 최종 보고서를 기준으로 합니다.

## 14. 검증 및 성능 분석

### 14-1. RTL 시뮬레이션

#### XSim 모터·안전 통합 파형

![XSim에서 연 모터 제어와 연속 이상 정지 파형](docs/images/xsim_motor_safety.png)

`tb_fourier_motor`의 저장된 WDB를 XSim에서 열어 캡처했습니다. `class_valid`, 연속 이상 횟수,
warning, derated, fault, requested duty, PWM을 함께 보며 출력 제한과 latch를 확인합니다.
이 화면은 **RTL behavioral simulation**입니다. 테스트벤치는 실행 시간을 줄이도록 내부 시간 파라미터를
설정하므로 화면의 시각·PWM 주기를 실물의 500 ms watchdog·20 kHz PWM 측정값으로 읽지 않습니다.

2026-09-17 기존 Verilog 구현의 저장 로그는 **9/9 PASS**입니다.

| 테스트벤치 | 주요 검증 |
|---|---|
| `tb_mac` | 정수 MAC 연산 |
| `tb_fft_npu` | 20개 입력의 FFT complex bin·특징·은닉값·logits·class·NPU cycle |
| `tb_core` | 가속기 순서와 BRAM 결과 기록 |
| `tb_axi` | AXI 레지스터와 버스 응답 |
| `tb_spi` | SPI 전송 |
| `tb_fault_latch` | 연속 이상 latch 기준선 |
| `tb_safety_supervisor` | warning·derate·classifier/watchdog latch |
| `tb_speed_pi_integration` | 속도 제어·출력 제한 통합 |
| `tb_fourier_motor` | arm·정지·PI·open-loop·anti-windup·quadrature 통합 |

[FFT/NPU 로그](docs/evidence/2026-09-17_tb_fft_npu.log) ·
[모터 통합 로그](docs/evidence/2026-09-17_tb_fourier_motor.log) ·
[원본 로그 전체](docs/evidence/)

VHDL 전환과 모듈 구조 정리 후 별도의 XSim 검사 13개로 기존 기준값과 클록별 출력 일치를 확인합니다.
MAC 65,536개 조합, FFT/NPU 20개 기준 입력, AXI·SPI·안전 상태, 가속기 코어와
PID 2,000회 입력·모터 telemetry, VHDL 단독 리셋·MAC·FFT/NPU TB를 검사합니다.
[현재 소스의 검사 로그와 파일 지문](docs/evidence/readability_complete_2026-11-15/),
[모듈 구조 정리 기록](docs/evidence/vhdl_structure_2026-11-15/)과
[최초 전환 검사 기록](docs/evidence/vhdl_2026-11-15/)을 기존 로그와 함께 보존합니다.

FFT/NPU 자체의 `start → FFT → hidden/logits → done`과 18-cycle 추론 구간은 현재 테스트 로그로
확인할 수 있으며, 해당 구간의 전용 파형 이미지는 아직 추가하지 않았습니다.
기존 9월 14일 AXI WDB도 확인했지만 FFT/NPU 내부 신호의 값 이력이 저장되지 않아 해당 그림을
추출할 수 없었습니다. MATLAB 검증을 갱신한 뒤 내부 신호 기록을 켜고 XSim을 다시 실행해야 합니다.

### 14-2. 구현 타이밍과 자원

#### Vivado Timing Summary 실제 화면

![Vivado 구현 결과의 setup WNS와 hold WHS](docs/images/vivado_timing_summary.png)

2026-09-17 19:33에 저장된 **최종 routed checkpoint**를 열어 확인한 결과입니다. 화면을 새로 캡처한
날짜와 회로를 구현한 날짜는 다릅니다. 이번 문서 작업에서 회로를 재합성하거나 보드에 다시 올린 것은 아닙니다.

| 항목 | 최종 저장 결과 | 해석 |
|---|---:|---|
| Clock | 100 MHz / 10 ns | `clk_fpga_0` |
| WNS | **+0.091 ns** | 최악 setup 여유 |
| TNS / setup 실패 endpoint | 0.000 ns / 0 | setup 음수 slack 없음 |
| WHS | **+0.020 ns** | 최악 hold 여유 |
| THS / hold 실패 endpoint | 0.000 ns / 0 | hold 음수 slack 없음 |
| WPWS | +3.750 ns | 최악 pulse-width 여유 |
| DRC | Error 0, Warning 23 | 경고까지 0이라는 의미는 아님 |
| LUT | 12,201 / 53,200 (22.93%) | 최종 utilization 보고서 |
| Register | 8,187 / 106,400 (7.69%) | 최종 utilization 보고서 |
| BRAM tile / DSP | 1 / 8 | 최종 utilization 보고서 |

**WNS**는 데이터가 다음 캡처 에지보다 충분히 일찍 도착하는지 확인하는 setup slack의 최솟값입니다.
**WHS**는 캡처 에지 직후 필요한 시간 동안 데이터가 유지되는지 확인하는 hold slack의 최솟값입니다.
둘 다 양수지만 여유가 작으므로 RTL이나 제약을 수정하면 구현 후 다시 확인해야 합니다.

위 통과 결과는 설정된 타이밍 제약 범위에 대한 것입니다. 원본 `check_timing`에는 input 8개·output 7개의
false-path 예외가 기록되어 있습니다. [Timing](docs/evidence/2026-09-17_timing.rpt) ·
[Utilization](docs/evidence/2026-09-17_utilization.rpt) · [DRC](docs/evidence/2026-09-17_drc.rpt) ·
[Check timing](docs/evidence/2026-09-17_check_timing.rpt)

이전 README의 `+0.119/+0.030 ns`, `12,228 LUT/8,119 FF`와 혼동하지 않도록 현재 파일의 값으로
정정했습니다. 단계별 과거 설명은 [이전 README 기록](docs/README_VALIDATION_HISTORY.md)에 보존했습니다.

### 14-3. 실물 계측

#### 오실로스코프: JD1 PWM 실측

UART `x`로 저장된 실제 이상 윈도우를 PL FFT/NPU에 세 번 입력하면서 JD1을 프로브로 측정했습니다.
아래는 **2026-09-15 classifier latch 경로 시험** 사진입니다. 최종 PI 통합 이후의 새 계측 사진으로
표현하지 않습니다.

| 정상 출력 50.0% | 제한 출력 25.0% | latch 정지, 정적 LOW |
|---|---|---|
| ![오실로스코프 PWM 50%](measurements/scope_captures_2026-09-15/jd1_pwm_baseline_50pct.jpg) | ![오실로스코프 PWM 25%](measurements/scope_captures_2026-09-15/jd1_pwm_derated_25pct.jpg) | ![오실로스코프 latch LOW](measurements/scope_captures_2026-09-15/jd1_pwm_latched_0pct.jpg) |

warning 단계에서는 50%가 유지되고, derate에서 25%, latch에서 PWM이 LOW가 되었습니다.
주기 신호가 사라지면 스코프의 duty/frequency 자동 측정은 `?`로 표시되므로 그 기호만으로
0%를 계산한 것은 아닙니다. 파형의 LOW 상태와 구동 정지 기록을 함께 확인했습니다.
[시험 절차·원본 기록](artifacts/safety_supervisor_hardware_2026-09-15.md)

#### 분류 데이터와 연산 성능

| 항목 | 결과·조건 |
|---|---|
| 실제 데이터 | 정상 3 run 180 windows + 토크 리플 3 run 180 windows |
| 학습/검증 분리 | run 1·2 학습 / run 3 검증, 이웃 window 무작위 혼합 없음 |
| FP32 / INT8 검증 | 119/120 (99.17%) / **118/120 (98.33%)** |
| INT8 혼동행렬 | 정상 58/60, 주입 이상 60/60; 정상 오검출 2개 |
| 저장 데이터 보드 replay | 100/100 CPU–PL 결과 일치 |
| 센서 재고정 후 별도 실시간 시험 | 이상 60/60, 정상 28/30, 전체 97.8% |
| 실측 sample 간격 | 평균 약 998.8 μs, 약 1001.2 Hz |
| PL FFT+NPU / NPU만 | 833 cycles = 8.33 μs / 18 cycles @ 100 MHz |
| 가속기 end-to-end | 26.38 μs, ARM 소프트웨어 847 μs 대비 약 32배 |

98.33%는 기존 검증 run의 120개 window에 대한 결과이며, 실측 재생에서도 같은 데이터와 모델을
사용합니다. [실측 데이터 분리](docs/REAL_DATASET.md) ·
[실물 분류 기록](artifacts/hardware_validation_2026-09-14.md) · [성능 측정](docs/PERFORMANCE.md)

#### 모터 제어·안전 실험

| 실험 | 관측 결과 |
|---|---|
| 폐루프 속도 추종 | reference 2048 대비 measured 2040..2045, 오차 0.4% 이내 |
| classifier 정지·재arm | 전류 0.13 A → 0.01 A, clear/rearm 후 0.13 A |
| PS 정지 watchdog | AXI 카운터 기준 452..508 ms에서 trip, 설계 500 ms와 일치 |
| 12→9→12 V 외란, 독립 2회 | duty 64.2→85.8%, 속도 최대 -14.6%, 약 1.5..2 s 회복 |
| 식별 모델 | gain 71.36 RPM/duty-pu, τ 0.620 s, 지연 0.060 s, test fit 40.3% |
| PI 게인 비교 | overshoot 11.10% → 3.68%, candidate의 상승 응답은 느려짐 |
| Quadrature | 방향·illegal transition 관측, 경계 프리셋 후 실제 전이로 overflow 3회 재현 |

원래 게인의 overshoot 11.10%는 초기 encoder 추정의 단일 노이즈 spike를 제외한 기존 분석값입니다.
식별 모델의 낮은 fit과 분석 조건을 함께 기록합니다. Anti-windup 차이는 포화 조건의 XSim에서 검증했고,
해당 실물 step은 duty가 약 85%까지 올라가 100% 포화에 거의 도달하지 않아 차이가 작았습니다.
[9월 16일 통합 기록](artifacts/single_board_integration_2026-09-16.md) ·
[9월 17일 제어 확장 기록](artifacts/single_board_integration_2026-09-17.md) ·
[실측 CSV](artifacts/experiments/)

### 14-4. MATLAB 기준값과 NPU 중간값 그래프

![MATLAB에 저장된 입력과 정수 FFT 값의 그래프](docs/images/matlab_saved_fft.png)

상단은 Golden case 중 실측 정상 0번·주입 이상 1번의 raw 64 samples, 하단은 저장된 정수 FFT의 양수 주파수
크기입니다. 하단에서 DC bin만 표시에서 제외했으며 NPU 입력의 DC를 제거한 것은 아닙니다.
명목 주파수 축은 1 kHz/64, 세로축은 `FFT/64`의 count 크기입니다. Hann PSD와 단위가 다릅니다.

![MATLAB 기준 feature hidden logits의 실측 16개 case heatmap](docs/images/matlab_saved_npu_tensors.png)

왼쪽부터 특징 4개·은닉 활성값 4개·최종 점수 2개입니다. 각 행은 동일한 case이므로 입력 특징이
ReLU와 재양자화를 거쳐 최종 판정으로 바뀌는 과정을 따라갈 수 있습니다. logits는 확률이 아닙니다.

원본 **Golden 20개는 실측 검증 frame 16개와 산술 경계 시험 4개**이며, 위 그래프는 실측 16개만 표시합니다. case 16..19는
영 입력·최대 양수·최대 음수·impulse를 만든 시험 벡터이며 실측이 아닙니다.
아래 2차 실측 전용 경로의 360개 window에는 이 경계 시험 입력을 포함하지 않습니다.

두 그림의 **수치 원본은 9월 17일 MATLAB 검증이 저장한**
[`matlab_reference.mat`](docs/evidence/2026-09-17_matlab_reference.mat)이며,
**이번 이미지 렌더링은 Python/Matplotlib**으로 수행했습니다. MATLAB GUI 캡처가 아닙니다.
20개 case의 저장 배열이 현재 독립 정수 기준 계산과 모두 같은지 확인했습니다.
[그래프 재생성 코드](tools/render_readme_npu_reference.py)를 함께 제공합니다.

### 14-5. 실측 3D 스펙트럼과 MATLAB 분석 출력

![실측 X축 기록의 Python 3D 스펙트럼 검증 미리보기](docs/images/measured_python_preview_3d.png)

위 그림은 실측 원본으로 만든 **Python 검증 미리보기**입니다. 주파수·프레임·크기의 3D 표시이며
물체의 XYZ 변위 궤적이 아닙니다. 미리보기는 평균 제거한 rectangular DFT 크기를 사용합니다.
MATLAB 스터디의 Hann PSD와 창·정규화가 다르므로 세로축 수치를 직접 비교하지 않습니다.

| MATLAB에서 생성하는 그림 | 확인하는 내용 |
|---|---|
| `measured_raw_frames.png` | 각 run의 raw counts와 프레임 내 실측 샘플 시각 |
| `measured_spectrum_3d.png` | 6개 run의 periodic-Hann PSD waterfall, counts²/Hz |
| `measured_quality.png` | AC RMS·DC·샘플 간격 표준편차·호스트 수신 간격 |
| `measured_confusion.png` | 기존 학습/검증 run을 나눈 혼동행렬 |
| `*_measured.png` | 기록된 모터 목표·속도·PWM·적분값·상태 |

각 PSD는 독립된 64-sample frame을 분석합니다. 원본 window 간격을 연속 STFT hop으로 간주하지 않고,
센서 단위 보정 없이 counts²/Hz를 물리 가속도 PSD로 바꾸지 않습니다.

| 경로 | 입력과 목적 | 실행 |
|---|---|---|
| 정수 Golden 검증 | 기존 FFT/NPU의 MATLAB·Simulink 중간값 비교 | `RUN_MATLAB_CHECKS` |
| **2차 실측 전용** | 원본 X축 360 windows + 모터 telemetry 5개, 19,381 records 재생 | `RUN_MEASURED_STUDY` |
| 6자유도 연구 | 가정한 질량·강성·감쇠와 가진력으로 XYZ·회전 응답 분석 | `RUN_RESEARCH_STUDY('ripple')` |

실측 경로의 3D 그림은 **주파수 × 윈도우 × 스펙트럼 크기**입니다. 측정하지 않은 Y/Z나 공간 변위를
만들지 않습니다. 6자유도 경로의 3D 장면은 가정 기반 물리 시뮬레이션이며 실측 재생과 별도입니다.
두 경로에는 함수 목적·입출력·단위와 `% [주1]` 형식의 한국어 설명 주석을 추가했습니다.

**새 스터디 경로는 이 작성 환경에 MATLAB이 없어 실제 MATLAB·Simulink 실행 검증이 남아 있습니다.**
실행 시 `.slx`를 생성하는 코드를 제공하며, 이번 XSim 캡처를 MATLAB 실행 증거로 사용하지 않습니다.
기존 보드 빌드의 MATLAB gate 기록과 현재 주석·스터디 소스의 검증 상태도 구분합니다.

[실측 재현 가이드](docs/MATLAB_SIMULINK_MEASURED.md) ·
[6자유도 연구 가이드](docs/MATLAB_SIMULINK_RESEARCH.md) ·
[코드 각주 읽기 순서](docs/STUDY_CODE_NOTES.md)

실제 MATLAB 그림과 Simulink 루트·하위 블록 이미지는 다음 순서로 내보냅니다.

```matlab
RUN_MATLAB_CHECKS
RUN_MEASURED_STUDY
EXPORT_README_FIGURES
```

[`EXPORT_README_FIGURES.m`](EXPORT_README_FIGURES.m)은 실측 replay 비교가 통과한 경우에만
`docs/images/matlab_exports/`에 실제 MATLAB PNG/FIG와 Simulink 다이어그램을 저장합니다.
이 내보내기 함수는 정적 구문 검사만 완료했으며 이 환경에서는 실행하지 못했습니다.

### 14-6. 현재 완료 범위와 남은 확인

| 항목 | 현재 상태 | 남은 작업 |
|---|---|---|
| README·대표 이미지·Vivado BD·WNS/WHS·모터 파형 | 로컬 반영, 이미지·링크·원본 해시 확인 완료 | GitHub 반영 후 웹 표시 확인 |
| 한국어 스터디 주석 | 35개 파일에 설명 추가, 구문 검사 완료; 최종 점검에서 결과 출처 확인 절차도 보강 | 실제 MATLAB 실행은 별도 |
| 새 실측·6자유도 MATLAB/Simulink | 코드·독립 Python 참조·정적 검사 완료 | MATLAB에서 `.slx` 생성·컴파일·실행과 그림 내보내기 |
| FFT/NPU 전용 파형 | 기존 회귀 PASS 로그 보존 | FFT/NPU 처리 단계와 cycle을 보여 주는 실제 XSim 캡처 |

## 15. 빌드와 소프트웨어 연동

MATLAB에서 `Project07_VibrationNPU`를 현재 폴더로 선택합니다.

```matlab
RUN_MATLAB_CHECKS                 % 기존 정수 Golden 및 Simulink 검증
RUN_MEASURED_STUDY                % 실제 기록만 재생하는 별도 스터디
RUN_RESEARCH_STUDY('ripple')      % 가정 기반 6자유도 연구
```

PC 도구는 이 README가 있는 폴더에서 실행합니다.

VHDL 전환 검사는 다음 명령으로 독립 실행할 수 있습니다.

```bash
python3 tools/run_vhdl_validation.py
python3 tools/check_vhdl_preservation.py
```

이 검사는 기존 보고서와 공식 `.pass` 마커를 덮어쓰지 않습니다. 공식 sim/build의
현재 소스에 대한 MATLAB 선행 검증 조건은 아래와 같이 유지합니다.

```bash
python3 -m pip install -r requirements.txt
python3 tools/offline_check.py
python3 tools/run.py sim
python3 tools/run.py build
```

| 사용하는 자료 | 실행 범위 |
|---|---|
| 전체 저장소 | Golden·실측·6자유도 연구 및 `EXPORT_README_FIGURES` |
| `artifacts/matlab_measured_input.zip` | 실측 원본을 포함한 `RUN_MEASURED_STUDY`; 그림은 `reports/measured/`에 생성 |
| `artifacts/matlab_research_input.zip` | 가정 기반 `RUN_RESEARCH_STUDY`와 Golden; 실측 CSV·모터 기록 미포함 |

실측 ZIP에는 `RUN_MATLAB_CHECKS`와 `EXPORT_README_FIGURES`가 없습니다. README의 전체
그림 내보내기 순서는 전체 저장소에서 실행합니다. 각 ZIP에는 해당 범위에 맞는 시작 안내가 있습니다.

공식 sim/build는 현재 source digest에 맞는 선행 MATLAB 검증을 요구합니다. 새 소스와 주석을 적용한
뒤에는 MATLAB 결과를 다시 검증해야 하며, 과거 PASS 마커를 현재 소스의 PASS로 간주하지 않습니다.
Vivado 2024.2와 Zybo Z7-20 board files가 필요합니다. 경로 설정·Vitis·UART 명령은
[Vitis 가이드](docs/VITIS_2024_2.md), 실측 수집·재학습은 [데이터 가이드](docs/REAL_DATASET.md)를 따릅니다.
