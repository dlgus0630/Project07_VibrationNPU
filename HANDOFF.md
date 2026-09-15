# 작업 인수인계

기준 시각은 2026-09-15이며, 다음 작업 세션은 이 문서와 `docs/PROJECT_RULES.md`, `DESIGN.md`를
먼저 읽는다. 기록된 결과와 실제 파일을 대조하고 실행하지 않은 항목을 PASS로 쓰지 않는다.

## 지켜야 할 원칙

1. PC 학습 → MATLAB Golden/Simulink → XSim → synthesis/implementation → 보드 검증 순서를 지킨다.
2. FPGA에서는 학습하지 않고 `4 -> 4 ReLU -> 2` INT8 모델의 추론만 수행한다.
3. ARM은 센서 설정·데이터 이동·정책·로그, PL은 FFT/NPU와 모터 차단 latch를 담당한다.
4. 직접 작성하는 HDL은 Verilog-2001이며 HDL Coder와 SystemVerilog를 사용하지 않는다.
5. bit width, signedness, saturation, truncation, shift 변경 전 `DESIGN.md`를 갱신한다.
6. 실측 데이터는 acquisition run 단위로 train/validation을 분리한다.
7. 통제된 토크 리플을 자연 발생 베어링 고장으로 표현하지 않는다.
8. 커밋 작성자는 사용자 `dlgus0630` 한 명만 유지한다. 공동 작성자 트레일러나 자동 생성자 표기를
   넣지 않으며 커밋과 push는 사용자가 요청한 시점에만 수행한다.
9. 전원 인가 상태에서 배선을 바꾸지 않는다. 종료 순서는 `SW0 OFF -> PSU OUTPUT OFF`다.
10. `README.md`, `DESIGN.md`, `HANDOFF.md`, `docs/`도 source digest에 포함된다. RTL과 문서 변경을
    한 묶음으로 확정한 다음 MATLAB package를 새로 만들고 모든 gate를 다시 통과시킨다.

## 프로젝트 범위

이 저장소는 Project07의 통합 SoC 결과물이다.

```text
MPU-6500 X축 -> Cortex-A9 SPI 수집 -> dual-port BRAM
             -> PL FFT64 -> 4 band -> 4x4x2 INT8 NPU
             -> 3회 연속 이상 판정 -> PL motor latched stop
```

별도 `Project07_MotorControl` 저장소에는 Basys3 pure-RTL PI, anti-windup, encoder hybrid estimator와
실측 모터 결과가 보존돼 있다. Zybo에서 그 전체를 복제하지 않는다. 이 저장소에서는 실제 진동
분류가 모터 제한/정지로 이어지는 통합 시스템을 완성한다. Fourier는 실제 radix-2 FFT64 RTL,
Laplace/control은 MATLAB/Simulink plant·PI 기반과 Basys3 제어 기준선으로 유지한다.

## 확정 하드웨어

- Board: Zybo Z7-20
- Sensor breakout 실장 칩: MPU-6500, `WHO_AM_I=0x70`
- Motor: JGB37-520, DC 12 V, 110 RPM, Hall encoder 내장
- Driver: L298N, ENA jumper 제거
- PSU: 12.0 V, 초기 current limit 0.5 A
- Sensor: JE1 SCLK, JE2 MOSI, JE3 MISO, JE4 CS, JE5 GND, JE6 3.3 V
- Motor: JD1 ENA/PWM, JD2 IN1, JD3 IN2, JD5 common GND
- Motor red/white: L298N OUT1/OUT2
- Encoder black: common GND; blue/green/yellow은 현재 미사용·절연
- BTN0: emergency stop
- 센서는 모터 전면 하단의 검정 gearbox bracket에 절연층을 두고 단단히 고정했다. 데이터 수집 후
  위치·방향을 바꾸면 기존 데이터와 직접 비교하지 않는다.

현재 스위치 계약:

```text
SW0: OFF를 거친 뒤 ON해야 motor arm
SW2:1 = 10: 정상 50% duty
SW3 OFF: 정상 50% 고정 duty
SW3 ON: 25%/75%를 32 Hz로 교대, 평균 duty 50%
```

## 완료된 실물 수집과 통합 검증

새 fault-injection bit를 Zybo에 프로그램했고 센서 초기화를 다시 확인했다.

- `WHO_AM_I,0x70`
- `SENSOR_MODEL,MPU-6500`
- `SENSOR_READY,1`
- 정상 50%: 12.0 V, 약 0.12 A, 중간 속도 회전
- 토크 리플: 12.0 V, 약 0.15~0.16 A, 회전·소리 변화 확인
- 정상 3 run × 60 window = 180 window, rejected 0
- 토크 리플 3 run × 60 window = 180 window, rejected 0

원본은 `measurements/final_50pct/`에 있다. 각 CSV의 JSON sidecar에 센서 조건, 실행 ID,
bitstream SHA-256과 ELF SHA-256이 기록돼 있다. 잘못 측정한 13 V 파일은
`measurements/rejected_wrong_supply_13v_do_not_train/`, 효과가 없었던 binder-clip pilot은
`measurements/pilots/abnormal_pilot_01.*`에 격리돼 있으며 학습에 넣지 않는다.

파일럿 비교:

- detrended raw RMS: normal `45.737 ± 3.295`, injected `90.609 ± 6.029` count
- four-band INT8 feature mean: normal `[0.9, 0.7, 1.0, 1.9]`
- four-band INT8 feature mean: injected `[2.6, 1.2, 2.8, 2.5]`
- band 1/3 pooled effect size: `3.970`, `4.025`

새 실측 모델을 포함한 bit/XSA와 ARM 앱을 만든 뒤 Zybo에서 다음 검증을 완료했다.

- bitstream SHA-256:
  `6a1fcd2477a063eabf23852596d00e111b091eebd291b49f0b5399a37a70ff28`
- XSA SHA-256:
  `70e2122d94bc560a4bf48df22418fd5fc04aaeb0f9f1c31c8211d3aa574aa5ec`
- ELF SHA-256:
  `8bd647a3f71f0b02abdffdd351bc3a74ac5df313872048c942338f7444c8a810`
- post-route timing: setup `+0.009 ns`, hold `+0.029 ns`, DRC Error 0
- replay 100회: CPU/PL class `100/100` 일치
- PL latency: 833 cycle at 100 MHz
- ARM 기준 실행시간: 847 us
- end-to-end 평균 latency: 26.38 us

최초 실시간 분류에서는 정상 `60/60`, 토크 리플 `9/60`만 검출됐다. 계산 경로를 대조한 결과
CPU/PL 판정은 일치했고 fault-injection RTL도 데이터 수집 당시와 같았다. 샘플링 속도는
`1001.2 Hz`였으며 fault 에너지가 학습 당시 band 0에서 실측 당시 band 1로 이동했다. 따라서
원인은 FFT/NPU 계산 오류가 아니라 센서와 모터 사이의 기계적 전달 조건 변화로 좁혀졌다.

센서를 같은 위치에서 다시 단단히 고정한 뒤 재측정한 결과는 다음과 같다.

- 토크 리플: `60/60` 검출
- 정상: `28/30` 정상 판정
- 전체: `88/90 = 97.8%`
- fault class 최소 margin: `117`

재고정 전 센서가 실제로 느슨했는지는 직접 확인하지 못했으므로, 문서에는 나사 풀림으로 단정하지
않고 센서 고정 상태와 기계적 전달 경로의 변화로 기록한다. 원본 8개 CSV는
`measurements/hw_validation_2026-09-14/`, 전체 분석은
`artifacts/hardware_validation_2026-09-14.md`에 있다.

## 데이터셋과 재학습 결과

`measurements/dataset_50pct/`는 다음처럼 실행 단위로 분리했다.

- train: `normal_50_01/02`, `fault_ripple_01/02` = 240 window
- validation: `normal_50_03`, `fault_ripple_03` = 120 window
- 같은 run의 window가 train과 validation에 동시에 들어가지 않음

`tools/train_export.py --real-data measurements/dataset_50pct` 실행 결과:

```text
FP32 accuracy        119/120 = 99.17%
INT8 accuracy        118/120 = 98.33%
FP32/INT8 agreement  119/120 = 99.17%
INT8 confusion       [[58, 2], [0, 60]]
false positive       2/60
false negative       0/60
```

새 `data/model.json`, memory 파일, test vector, `fourier/firmware/model_data.h`가 생성됐다.
독립 Python/C 정수 기준검증은 20 window, 2,560 FFT component, 220 result value를 통과했고
FFT 최대 오차는 부동소수점 FFT/64 대비 6 LSB였다.

## gate와 artifact의 정확한 현재 상태

PL 안전정지 latch를 포함한 최종 실행 artifact는 다음과 같다.

- `artifacts/fourier.bit`: SHA-256 `cc48b9e7577f06f7978887f3a582018285058b828409ace5b291ec34eb9e9360`
- `artifacts/fourier.xsa`: SHA-256 `9bb245d0958c871fa8820785b90f296f018fb4694bb7363e96b28e76fc31374b`
- `artifacts/fourier_app.elf`: SHA-256 `428f788bfcf8710d217aeca11d023babd43255dec8d8a219b3e8aecad1c66e46`
- `artifacts/fsbl.elf`: SHA-256 `b6645ffd48ab1d2f8cffb4af2b62704d0b691ca37683da58952f8bc72a8c5f44`
- 이전 실측 모델 artifact는 `*_pre_latch.*` 이름으로 보존

검증 결과:

- MATLAB/Simulink: PASS
- XSim: 7/7 PASS
- Vivado post-route: setup `+0.039 ns`, hold `+0.013 ns`, DRC Error 0
- resource: LUT 11,265, register 7,272, BRAM tile 1, DSP 5
- 새 XSA 기반 Vitis platform/BSP/FSBL/ARM app: PASS
- ARM-PL replay: `match=1`
- MPU-6500 재초기화: `WHO_AM_I=0x70`, `SENSOR_READY=1`

최종 실물 시험은 정상 운전 class 0 `3/3`, CPU-PL `3/3` 일치로 시작했다. SW3 토크 리플을
인가한 뒤 판정열 `0,1,1,1,0,0`에서 세 번째 연속 class 1에 latch가 설정됐다. AXI status는
`0x0000000A`, 모터는 정지, `LD0 OFF / LD1 ON`, 전류는 0.13 A에서 0.01 A로 감소했다.
SW0 OFF clear 후 SW2를 유지하고 SW0 ON으로 재arm하자 `LD0 ON / LD1 OFF`, 모터 재회전,
0.13 A로 복귀했다.

원본 로그는 `measurements/hw_validation_2026-09-14/*latch_motor_final*.csv`, 전체 설명은
`artifacts/hardware_validation_2026-09-14.md`, 구조화 요약은
`artifacts/latch_hardware_summary_2026-09-14.json`에 있다.

## 안전 supervisor 확장 상태

구현과 빌드 완료 항목:

- `safety_supervisor.v`: 1회 warning, 2회 연속 25% derate, 3회 연속 classifier latch
- arm 중 500 ms PS heartbeat timeout에서 독립 watchdog latch
- AXI `0x48` heartbeat, `0x4C` 안전 telemetry와 status bit4..6
- ARM 100 ms heartbeat 및 UART `f` 안전상태 출력
- 공식 XSim 8/8 PASS: `tb_mac`, `tb_fft_npu`, `tb_core`, `tb_axi`, `tb_spi`, `tb_fault_latch`,
  `tb_safety_supervisor`, `tb_fourier_motor`
- MATLAB/Simulink gate: 이 문서의 증거 표현 정정 직전 source digest에서 PASS. 아래 "다음 작업 순서"
  참고 — 정정으로 digest가 바뀌므로 두 marker는 재생성 대상이다
- Vivado post-route setup `+0.015 ns`, hold `+0.031 ns`, DRC Error 0
- resource: LUT 11,332, register 7,333, BRAM tile 1, DSP 5
- bit SHA `a57f472a1c4f31c3baa10cf35126dbf65b2e4557dc1b1296f290e3dd5aceb255`
- XSA SHA `344c6a754543682bf382fea537357506bdc3d15db90fb5c3a177d0c814a865b1`
- 최신 ELF SHA `be278a0fe3efc8fd9039983a5a125ef6dc10b759de91e713e65274a34af39a21`
- 정상 실센서 class 0 3/3, CPU/PL 3/3 일치. 단 최초 정상 시험 1회에서 `cause=2`가 발생했다
  (class 0 3/3, abnormal_total 0이라 기계·오분류 문제는 아니었으나 원인 미규명, 이후 재현 안 됨).
  acquisition 중 heartbeat 보강 firmware로 최종 시험에서 watchdog 0 유지
- 통제된 32 Hz 인위적 토크 리플 class `1,1,0`에서 warning -> derated bit=1로 25% 제한 상태 ->
  정상 복구 확인. AXI 레지스터 bit 확인이며 JD1 duty%는 측정하지 않았다
- 저장된 실제 이상 window class `1,1,1`에서 warning -> 제한 -> latch 정지 PASS
- 모터 전류 `0.13 A -> 0.01 A`, latch 유지, SW0 clear/rearm 뒤 `0.13 A` 재회전 PASS
- Cortex-A9 #0 JTAG 정지 1.010 s 동안 watchdog latch, `cause=2`, 모터 `0.13 A -> 0.01 A` PASS
- watchdog SW0 clear/rearm 뒤 모터 `0.13 A` 재회전 PASS

`fourier/firmware/main.c`의 `x`는 저장된 실제 이상 window를 한 번 FFT/NPU에 통과시키는 지속 이상
검증 명령이다. 긴 센서 수집 중에는 16 sample마다 heartbeat를 보내도록 보강했다. 상세 실측 기록은
`artifacts/safety_supervisor_hardware_2026-09-15.md`와 `artifacts/safety_logs_2026-09-15/`에 있다.

## 다음 작업 순서

gate 현황: 증거 표현 정정 직전 source digest에서 MATLAB/Simulink gate와 공식 XSim 8/8이 모두
PASS였다. `tools/gates.py`의 digest는 `artifacts`, `reports`, `build`, `measurements`를 제외한
저장소 전체를 해시하므로 README/HANDOFF/docs 수정도 digest를 바꾼다. 따라서 이번 문서 정정으로
두 marker는 무효가 되고 재생성이 필요하다.

아직 완료로 기록하면 안 되는 항목:

- 정정된 문서를 포함한 새 source digest의 MATLAB/Simulink 반환 gate
- 오실로스코프 JD1의 50% -> 25% -> LOW 파형과 차단 지연시간(선택이지만 포트폴리오 권장)
- JD1 duty 25%와 latch LOW의 실제 파형. 현재 증거는 AXI 레지스터 bit 확인까지다

1. 현재 source로 `python3 tools/package_matlab.py`를 실행하고 MATLAB/Simulink gate를 갱신한다.
2. 공식 XSim 8/8을 다시 실행한다. firmware/문서만 바뀌었으므로 bit/XSA 재구현은 필요하지 않다.
3. 가능하면 오실로스코프 single-shot으로 JD1의 정상 50%, 제한 25%, latch LOW를 기록한다.
   UART 명령 사이의 사용자 확인 시간이 있으므로 현재 로그의 host timestamp를 차단 지연시간으로
   사용하지 않는다.
4. 모든 결과를 문서에 반영하고 사용자 검토 뒤 사용자 계정만으로 commit/push한다.

## 제한과 선택 확장

- class 1은 통제된 토크 리플이며 자연 고장 일반화 결과가 아니다.
- 정상 run 3개를 먼저, class 1 run 3개를 나중에 수집했으므로 온도 추세가 class와 결합됐을 수 있다.
- 센서의 고정 상태와 기계적 전달 경로가 분류 결과를 크게 바꾼다. 새 실험 전 정상 상태의 four-band
  평균을 기존 baseline과 비교하고 차이가 크면 센서 고정부터 점검한다.
- 최소 데이터셋은 완성됐다. 더 강한 통계가 필요하면 다른 날 조건을 번갈아 3 run씩 추가한다.
- oscilloscope는 최종 통합에서 JD1 PWM과 fault latch 직후 차단 시간을 증명할 때 사용한다.
- 전압 외란, encoder C2 quadrature, Zybo에 Basys3 전체 PI 이식은 최종 통합 뒤 선택 항목이다.
- `Project07_MotorControl`의 pure-RTL 제어 결과와 중복되는 기능 확장은 우선순위가 낮다.

## 저장소 상태

실측 수집, 실제 데이터 모델, latch RTL/testbench, 최종 artifact와 문서는 아직 커밋되지 않았다.
커밋과 push는 수행하지 않았다. 최종 문서 digest의 MATLAB/XSim marker와 `git diff --check`를
확인한 다음 사용자 요청 시 사용자 계정의 이름과 이메일만 사용한다.
