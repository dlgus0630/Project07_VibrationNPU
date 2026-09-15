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
10. `tools/gates.py`의 digest는 `.md` 파일과 `artifacts/reports/build/measurements`를 제외한다.
    RTL, `.tcl`, `.c/.h`, `.py`를 바꾸면 MATLAB/XSim gate를 다시 통과시켜야 하지만 문서만 고칠
    때는 그럴 필요가 없다.
11. 최종 목표가 2026-09-15에 바뀌었다: `Project07_MotorControl`(Basys3)의 PI/encoder hybrid
    estimator를 이 저장소의 Zybo PL로 이식해 **한 보드로 완전 통합**한다. Basys3 저장소는
    삭제하지 않고 "개발·검증 기준선"으로 유지한다. 아래 "다음 작업 순서"를 따른다.

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

## 2026-09-15 오실로스코프·watchdog 후속 실측 (완료)

위 "안전 supervisor 확장 상태"에 기록된 시점 이후 추가로 완료한 것:

- **JD1 duty 오실로스코프 실측 완료**: baseline 50.0%, warning 50.0%(불변), derate 25.0%,
  latch 0%(파형 소실), SW0 clear/rearm 50.0% 복귀. 전부 `pwm_period` 계산값과 일치.
  스크린샷은 `measurements/scope_captures_2026-09-15/`, 상세 기록은
  `artifacts/safety_supervisor_hardware_2026-09-15.md`의 "Oscilloscope confirmation of JD1
  duty cycle" 절.
- **watchdog 발동 지연 정정**: 이 문서와 README가 이전에 적었던 "1.010 s 안에 정지"는 부정확한
  값이었다. 스크립트 기반 이분탐색으로 실제 발동 지점이 **1.489~1.600 s**임을 확인했다
  (RTL 설계값 500 ms의 약 3배). 원인은 아직 못 찾았다 — 클럭(오실로스코프로 20.00 kHz 독립
  확인)과 파라미터 비트 폭(합성 checkpoint에서 26 bit 확인)은 배제했지만, 카운터 값 자체가
  AXI로 노출되지 않아 ILA 없이는 더 못 판다. 상세는 같은 문서의 "Correction" 절,
  이분탐색 원본은 `measurements/watchdog_bisection_2026-09-15/trials.csv`.
- 두 결과 모두 커밋·push 완료 (`346cd6a`, `3a9b9dc`). 문서만 바뀌었으므로 (원칙 10) MATLAB/XSim
  gate는 영향 없다.

## 다음 작업 순서 — Zybo 단일보드 완전 통합 (2026-09-15 결정)

**최종 목표가 바뀌었다.** `Project07_MotorControl`(Basys3)의 encoder hybrid estimator와
PI/anti-windup을 이 저장소의 Zybo PL로 이식해 한 보드로 통합한다. Basys3 프로젝트는 삭제하지
않고 "개발·검증 기준선"으로 남긴다. 포트폴리오 서술: "Basys3에서 순수 RTL 모터 폐루프 제어기를
개발·검증한 뒤 Zybo Z7-20 PL로 이식해 ARM 센서 수집, FFT/NPU 진동 분류, 단계별 안전 제어와
통합했다." 이 결정과 근거는 작업 대화 기록에 있다.

목표 구조:

```text
Encoder C1 -> hybrid 속도추정 -> PI/anti-windup -> safety limiter -> PWM
                                       ^                  ^
                                   속도 목표        warning/derate/stop
                                                          ^
MPU-6500 -> ARM 수집 -> PL FFT64 -> INT8 NPU -> safety supervisor
                                                          ^
                                                 PS heartbeat watchdog
```

순서:

1. **watchdog 지연 문제(1.489~1.6 s) 원인 규명.** ILA를 `watchdog_count`에 붙이거나 디버그
   출력 pin을 추가해 카운터가 실제로 어떻게 도는지 확인한다. 이 문제를 안고 이식하면 통합
   시스템의 안전 정지 시간을 신뢰할 수 없다.
2. **PI/encoder 이식.** `Project07_MotorControl/laplace/rtl/encoder_speed_hybrid.v`,
   `pid_fixed.v`, `unsigned_divider.v`를 이 저장소 `fourier/rtl/`로 가져온다.
   `laplace/rtl/telemetry_uart.v`, `uart_tx.v`는 이식하지 않는다 — Zybo는 ARM이 이미 UART를
   맡고 있으므로 PI/encoder 상태는 `axi_vibration_top.v`에 읽기 레지스터를 추가하고 ARM
   firmware가 UART로 찍는 방식으로 대체한다(`print_safety()`와 같은 패턴). encoder C1 입력은
   새 물리 핀이 필요하다 — `fourier/constraints/zybo_z7_20.xdc`에서 미사용 JD/PMOD 핀을
   확인한다.
3. **PI 출력을 기존 safety limiter에 연결.** `fourier_motor_control.v`의 `requested_duty`
   소스를 스위치 고정값에서 PI 출력으로 바꾼다. `motor_derated`/`fault_latched`에 의한 25%
   제한과 PWM 차단 로직은 그대로 두고, PI 출력이 그 앞단으로 들어가게만 배선한다.
4. **단일보드 통합 실물 시험.** 속도제어 + 진동분류 + 제한 + 정지가 한 보드에서 함께 동작하는
   것을 확인한다. Basys3 기준선 결과(예: 13.66/27.32 RPM step 응답, 정착시간)와 비교한다.
5. **12 -> 9 -> 12 V 외란 시험을 Zybo 통합판에서 수행.** Basys3에서는 반복하지 않는다.
   `docs/TELEMETRY_EXPERIMENT.md`(MotorControl)의 절차를 참고해 이 저장소에 맞게 다시 쓴다.
   오실로스코프로 응답을 같이 기록한다.
6. **두 저장소와 포트폴리오 최종 정리.**

각 단계에서 RTL을 바꾸면 원칙 10에 따라 MATLAB/XSim gate를 다시 통과시킨다. 물리 작업(배선,
스위치, PSU)은 사용자가 직접 하므로 안내는 쉬운 한국어로 한 동작씩 나눈다.

## 저장소 상태

이 문서 작성 시점까지의 모든 실측 결과(재학습 모델, latch RTL, safety supervisor, 오실로스코프
확인, watchdog 이분탐색)는 커밋·push 완료돼 있다 (`git log`로 확인). 다음 세션은 위 "Zybo 단일
보드 완전 통합" 순서의 1번(watchdog 원인 규명)부터 시작한다.
