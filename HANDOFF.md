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

PL 안전정지 latch·PI/encoder 폐루프·watchdog 관측 레지스터를 모두 포함한 **최종(공식 gate 통과)**
실행 artifact는 다음과 같다. `main.c`의 `micros()`/`acquire()` 타이밍 버그 수정, `watchdog_count`
AXI 노출에 따른 `pid_fixed.v`/`encoder_speed_hybrid.v` 파이프라이닝을 모두 반영한 소스에서,
MATLAB Online 재검증 → 공식 XSim → 공식 `tools/run.py build`(내부 타이밍 게이트에서 1회 실패 후
같은 checkpoint에 확립된 AggressiveExplore phys_opt+route 복구를 적용해 완료) → 이 XSA로 Vitis
platform/FSBL/ARM app 재빌드까지 전부 이 세션에서 끝냈다.

- `artifacts/fourier.bit`: SHA-256 `46e6d49b854fee1bfe92de875c33f60f628caf6e10a4ce2d73ae2759d3899cfb`
- `artifacts/fourier.xsa`: SHA-256 `5ac8408fb440dd83fd1165882110c2ce0a0e02bb45938e9a0f8207509bc31b78`
- `artifacts/fourier_app.elf`: SHA-256 `7088a3348056b7a850a3119694237d9c0c20372f67185887657a623d87ee0292`
- `artifacts/fsbl.elf`: SHA-256 `528b43028ed835d5cd386b1e73dfed40dab6c1d788f506db55afba72bb4393e9`
  (PS7 설정이 그대로라 이전 XSA 기준 FSBL과 바이트 단위로 동일)
- 이전 실측 모델 artifact는 `*_pre_latch.*` 이름으로 보존

검증 결과(위 최종 artifact 기준):

- MATLAB/Simulink: PASS (source digest `e6ec4ab63ba4b75cc5ab567707841f861a6a53b5db29beab79377109670e2b0d`)
- XSim: 9/9 PASS (`tb_speed_pi_integration`, `tb_fourier_motor` 갱신 포함 — 아래 "2026-09-16"
  절 참고)
- Vivado post-route: setup `+0.138 ns`, hold `+0.017 ns`, DRC Error 0
- resource: LUT 11,987, register 7,968, BRAM tile 1, DSP 8
- 새 XSA 기반 Vitis platform/BSP/FSBL/ARM app: PASS
- ARM-PL replay: `match=1`
- MPU-6500 재초기화: `WHO_AM_I=0x70`, `SENSOR_READY=1`

이 최종 artifact는 이번 세션에서 실물 보드로 재플래시·재검증하지는 않았다 — 배선/실물 시험은
이 정확한 route가 아니라(동일 RTL을 이전에 별도로 route한) 직전 ad-hoc 빌드로 수행됐고, 동작은
XSim 9/9 일치로 동등성을 확인했다. 다음에 보드를 켤 때는 이 최종 bit/ELF로 재프로그램한다.

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
  **→ 정정: 이 1.489~1.600 s 수치는 이후 2026-09-16에 근본원인 규명 결과 이 세션의
  측정 방법론(외부 증상만 관찰, 카운터 레지스터 직접 접근 없음)이 만든 인공물이었음이
  밝혀졌다. RTL 결함이 아니었다 — 카운터는 실제로는 참 100 MHz/참 500 ms에서 정확히
  동작한다. 레지스터로 직접 검증한 정정된 측정치는 아래 "2026-09-16 watchdog 근본원인
  규명 (해결)" 절 참고. 이 문단은 그 시점의 관측과 믿음을 정확히 기록한 것이므로 지우지
  않고 남겨둔다.**
- 두 결과 모두 커밋·push 완료 (`346cd6a`, `3a9b9dc`). 문서만 바뀌었으므로 (원칙 10) MATLAB/XSim
  gate는 영향 없다.

## 2026-09-16 PI/encoder 이식 빌드 완료 (물리 검증 전)

"다음 작업 순서" 2번(PI/encoder 이식)과 3번(safety limiter 연결)을 RTL/빌드 수준까지 끝냈다.
아직 인코더 배선, 보드 프로그래밍, 폐루프 실측은 하지 않았다 — 아래는 전부 소프트웨어/빌드
결과이며 하드웨어 검증 결과가 아니다.

- `Project07_MotorControl`의 `encoder_speed_hybrid.v`, `pid_fixed.v`, `unsigned_divider.v`를
  `fourier/rtl/`로 이식하고, PI 출력을 기존 safety limiter(`motor_derated`/`fault_latched`)
  앞단에 연결했다.
- XSim 9/9 PASS(신규 `tb_speed_pi_integration` 포함, `tb_fourier_motor` 갱신). MATLAB gate,
  sim gate 모두 PASS.
- 새 bit/XSA 빌드: 기본 라우트가 setup `-0.629 ns`로 timing miss했고, 이 프로젝트가 항상 쓰던
  방식대로 구현된 checkpoint에 `phys_opt_design -directive AggressiveExplore` +
  `route_design -directive AggressiveExplore`를 적용해 복구했다. 최종 post-route: setup
  `+0.054 ns`, hold `+0.034 ns`, DRC Error 0. `artifacts/fourier.bit`, `artifacts/fourier.xsa`
  SHA-256은 위 "gate와 artifact의 정확한 현재 상태" 절 참고.
- 새 XSA 기준으로 Vitis 2024.2에서 ARM ELF(`artifacts/fourier_app.elf`)와 FSBL
  (`artifacts/fsbl.elf`)을 재빌드했다. 해시는 같은 절에 있다.
- 하지 않은 것(이 절 작성 시점): encoder C1 물리 배선, 보드 재프로그래밍, 속도제어 폐루프
  실측. 같은 날 이어서 실물 시험을 수행했다 — 아래 "2026-09-16 단일보드 통합 실물 시험" 절
  참고.

## 2026-09-16 단일보드 통합 실물 시험

encoder C1 물리 배선을 마친 뒤 위 절의 bit/ELF로 Zybo를 JTAG 프로그램하고 실물 시험을
수행했다. "다음 작업 순서" 4번(단일보드 통합 실물 시험)이 처음 실제로 시작됐다.

- 센서 bring-up: `WHO_AM_I,0x70`, `SENSOR_MODEL,MPU-6500`, `SENSOR_READY,1` — 정상
- **폐루프 PI/encoder 속도제어 실물 PASS**: SW2=10(speed_reference=2048 고정)로 arm 후 모터가
  물리적으로 회전하는 약 6초 동안 AXI 0x50/0x54/0x58/0x5c/0x60을 4회 읽었다.
  measured_speed는 2040/2043/2045/2043으로 reference(2048) 대비 약 0.4% 이내에서 추종했고
  armed=1이 4회 모두 유지됐다. requested_duty는 2808~2839로 소폭 변동. 이식된
  `encoder_speed_hybrid.v` + `pid_fixed.v`가 실물에서 폐루프를 닫는 것을 처음 확인했다(이전은
  XSim만).
- **safety supervisor 반응 로직 실물 PASS(통합 시스템 상)**: 모터를 폐루프로 계속 회전시킨
  채 `s`(sample+infer) 명령을 18회 실행하는 동안, 2회 연속 abnormal마다 예외 없이
  `derated=1`이 설정됐고 그 직후 정상 판정이 나오면 즉시 warning/derated가 clear되고
  consecutive가 0으로 리셋됐다. 3연속(latch)은 이번 시험에서 발생하지 않았다.
- **새로운 open question(미해결)**: 같은 18회 시험에서 진동분류 class 순서가 `1,1,0` 패턴을
  예외 없이 정확히 6회 반복했다(12/18 = 66.7% abnormal). class 1일 때 NPU 최종 출력 logit이
  12회 전부 `o0=-61, o1=60`으로 완전히 동일해서 경계선 노이즈가 아니라 두 개의 안정된 상태가
  주기적으로 교대하는 것으로 보인다. 미검증 가설 두 가지: (a) PI 폐루프 duty 변동(2808~2839)이
  NPU가 학습해보지 못한 실제 주기 진동을 만들었을 가능성, (b) PI의 10 ms 제어 tick과 진동
  샘플링 윈도 사이 위상 앨리어싱일 가능성. 근본원인 조사는 사용자가 직접 보류하기로
  결정했고 이번 세션에서는 수행하지 않았다. 상세 원본은
  `artifacts/single_board_integration_2026-09-16.md`.
  **→ 후속: 같은 세션에서 이 open question을 deep-reasoner로 분석하고 재현을 시도했다.
  acquire() 타이밍 버그를 발견·수정했으나 원본 패턴 자체는 재현되지 않았다 — 상세는 아래
  "2026-09-16 분류 패턴 재현 시도" 절 참고.**
- 이 발견 때문에 "단일보드 통합 실물 시험"을 완결(done)로 표시하지 않는다. 폐루프 제어
  자체는 확정 PASS이지만, PI 제어 중 분류 거동이라는 새 미해결 질문이 남아 있다.
- **텔레메트리 전송 주기 버그: 근본원인 규명 및 수정 완료(같은 세션 후속)**: 당초 설계값
  100 Hz(`TELEMETRY_US 10000`) 대비 실측 ≈24.95 Hz(약 1/4)로 확인됐던 건은 이후 같은 세션
  안에서 근본원인을 찾아 고쳤다. 원인은 Vitis 자동생성 헤더 `xtimer_config.h`의
  `#define XSLEEPTIMER_FREQ XPAR_CPU_CORE_CLOCK_FREQ_HZ/2`(괄호 누락) 매크로가
  `main.c`의 `micros()` 계산 `t*1000000U/COUNTS_PER_SECOND`에 그대로 치환되면서 연산자
  우선순위상 `실제 값/4`가 되는 C 결함이었다(클럭 설정 자체는 정확했음을 확인). 사용자 작성
  파일 `fourier/firmware/main.c`의 `micros()` 한 줄에 괄호를 추가해 수정했고(자동생성 BSP
  파일은 건드리지 않음), ELF만 재빌드해 JTAG 재프로그램 후 `capture_telemetry.py --duration 8`
  로 검증했다 — 8.0초 동안 796 frame = **99.5 Hz**(예측한 4배 보정과 일치). 수정 확인됨. 이
  버그는 이 firmware의 `cpu_us`/`e2e_us` 출력값에도 동일하게 적용됐을 가능성이 크므로(아래
  "진행 현황" 참고), `plcycles`는 PL 하드웨어 카운터라 영향 없음. 전체 근거와 매크로 전개
  과정은 `artifacts/single_board_integration_2026-09-16.md`의 "텔레메트리 주기 버그 —
  근본원인 규명·수정 완료" 절 참고(그 앞의 "텔레메트리 실제 전송 주기 불일치" 절은 당시
  미규명 시점 기록으로 남겨둠).
- **gate 영향**: `fourier/firmware/main.c`의 이 `micros()` 괄호 수정은 실제 소스 변경이므로
  원칙 10에 따라 현재 `matlab.pass`/`sim.pass` marker를 무효화한다. 다음 공식
  `tools/run.py build` 전에 MATLAB Online 왕복과 XSim을 다시 통과시켜야 한다 — 이번 세션에서는
  이 재검증을 수행하지 않았다.
- **"다음 작업 순서" 5번(12→9→12 V 외란 시험): 정밀 재시험으로 완결**: 텔레메트리 버그 수정
  후 시간축이 정확해진 상태에서, 사전 타이밍 대신 "준비되는 대로 조작 후 CSV에서 실제 전환
  시점을 사후 확인"하는 방식으로 60초 캡처 2회를 완전하게 얻었다.
  `artifacts/experiments/disturbance_2026-09-16_v4_final.csv`(Run 1): 12V→9V drop에서 duty
  64.2%→85.8%(peak 86.6%), measured 최소 46.66 RPM(reference 대비 -14.6%) 후 회복, 9V에서
  12초 안정 dwell, 9V→12V restore에서 duty 81.3%→65.6%, measured 59.01 RPM까지 overshoot
  (+8.0%) 후 회복, 이후 41초 안정 dwell.
  `artifacts/experiments/disturbance_2026-09-16_v5_repeat.csv`(Run 2): 같은 방법론으로 반복,
  drop/restore 방향 모두 동일 패턴 재현(overshoot +4.2%, 39초 안정 dwell 등). 양 회차 모두
  recovery time 약 1.5-2초, safety trip 없음, oscillation 없음 — 두 독립 시행의 일치로
  재현성까지 확보됐다. Basys3의 `ANALYZE_DISTURBANCE` MATLAB 후처리는 이번엔 돌리지 않았고
  원본 CSV 직접 조사로 수치를 냈다는 점은 명시해둔다. 5번의 원래 요구(정량적·재현 가능한 외란
  응답 확인)는 이제 충족된 것으로 본다. 전체 데이터와 중간 실패 시도 기록은
  `artifacts/single_board_integration_2026-09-16.md`의 "외란 시험 — 정밀 재시험 완료(Run 1,
  Run 2)" 절 참고(그 앞의 "외란 시험 시도" 절은 당시 비정밀 시점 기록으로 남겨둠).

## 2026-09-16 watchdog 근본원인 규명 (해결)

"다음 작업 순서" 1번(watchdog 지연 1.489~1.6 s 원인 규명)을 같은 날 안에 실제로 끝냈다.
ILA 대신 카운터를 AXI로 직접 노출하는 더 간단한 방법을 썼다.

- `safety_supervisor.v` -> `fourier_motor_control.v` -> `axi_vibration_top.v`(신규
  read-only 레지스터 `0x43c00064`) -> `vivado/create_fourier.tcl` -> `tb_axi.v`/
  `tb_fourier_motor.v` 경로로 `watchdog_count`를 AXI에 노출했다. XSim 9/9 PASS, 동작 변경
  없음.
- 이 포트 추가가 이미 여유가 거의 없던 기존 critical path 두 개를 실제 timing 위반으로
  밀어넣었다. `fourier/rtl/pid_fixed.v`(anti-windup 64-bit adder+clamp)와
  `fourier/rtl/encoder_speed_hybrid.v`(DSP48E1 multiply -> compare/clamp mux) 각각에
  한 클록 파이프라인 레지스터를 추가해 bit-exact 결과를 유지한 채 해결했다(XSim으로 수정
  전후 완료 타임스탬프가 피코초 단위까지 동일함을 확인). `unsigned_divider.v`는 조사했으나
  무관함을 확인했고 손대지 않았다. 두 RTL 수정 모두 세션 중 사용자 승인을 받았다. 최종
  post-route: **WNS +0.138 ns, WHS +0.017 ns, DRC Error 0**. 전체 상세(코드 변경 내용,
  중간 Vivado 전략 시도 기록 포함)는 `artifacts/single_board_integration_2026-09-16.md`의
  "Watchdog 지연 미스터리 — 근본원인 규명 완료" 절 참고.
- 새 XSA로 ELF+FSBL을 재빌드하고 JTAG로 재프로그램한 뒤, ARM 코어를 halt한 채 AXI
  `0x43c00064`(watchdog_count)와 `0x43c00004`(status)를 ~50~60 ms 간격으로 직접 폴링하는
  진단을 두 차례 독립 실행했다. **두 시행 모두 결론이 같다: 카운터는 참 100 MHz로 돌고
  (기대값 대비 0.014%, 0.06% 오차 — 측정 잡음 범위 내), trip 시점은 452~508 ms로 설계값
  500 ms와 JTAG 폴링 해상도(~50 ms) 이내에서 일치한다.** 원본 데이터(두 회차 전체)는
  같은 artifacts 문서 참고.
- **결론: watchdog RTL 카운터는 처음부터 정상이었다.** 2026-09-15의 "1.489~1.6초, 약 3배"
  관측은 그 세션의 측정 방법론(외부 증상만 관찰, 레지스터 직접 접근 없음)이 만든 인공물이지
  실제 RTL 결함이 아니었다. **"다음 작업 순서" 1번은 이것으로 해결(RESOLVED)됐다** —
  watchdog 로직 자체에는 RTL 수정이 필요하지 않았다. 오늘 이뤄진 두 RTL 수정은 관측 레지스터
  추가로 필요해진, 기능과 무관한 타이밍 closure용 파이프라이닝이었다.
- 부수 참고 사항: `watchdog_count`는 `armed` 게이트를 받아 SW0 미arm 상태에서는 0에
  고정된다(의도된 설계). `fault_latched`/`watchdog_fault` 비트는 ARM resume만으로는 clear되지
  않고 실제 SW0 OFF->ON 사이클이 필요하다 — 둘 다 버그는 아니지만 향후 하드웨어 시험에
  유용한 운영 지식이라 기록해둔다.

## 2026-09-16 분류 패턴 재현 시도 — acquire() 타이밍 버그 발견·수정 (원본 패턴 미재현)

위 "2026-09-16 단일보드 통합 실물 시험" 절의 `1,1,0` 분류 패턴 open question을 같은 세션 안에서
deep-reasoner로 분석하고 실물 재현을 시도했다.

- **deep-reasoner 분석**: Finding 1 — class 1일 때 18회 중 12회 전부 비트 단위로 동일했던 NPU
  출력 logit(`o0=-61, o1=60`)은 첫 레이어 가중치가 전부 음수인 조합에서 feature 크기가
  threshold를 넘으면 4개 hidden unit이 전부 0으로 clamp되는 모델 포화 인공물이다(Python
  재구현으로 실측 캡처와 bit-exact 일치 확인, 증명됨). Finding 2 — 정확한 call-count-locked
  주기성은 폐루프 리밋 사이클(2연속 abnormal -> derate 25% -> duty 저하 -> 다음 읽기 정상 ->
  리셋 -> 반복)과 부합하는 구조적 설명이지만 "derate가 다음 읽기를 정상화시킨다"는 연결
  고리는 직접 확인되지 않았다. 이를 검증할 실험(E1: `s`/`f` 교대 실행으로 `derated`/
  `consecutive`가 분류 순서에 맞물리는지 확인)을 제안받았다. 상세는
  `artifacts/single_board_integration_2026-09-16.md`의 "분류 패턴 원인 조사 — deep-reasoner
  분석" 절.
- **E1 시도 중 새 버그 발견·수정**: 실물에서 E1을 시작하자 `s` 명령이 전부 `TIMING_ERROR`로
  실패했다. 원인은 `fourier/firmware/main.c`의 `acquire()` 샘플 타이밍 게이트
  (`dt[n]<700 || dt[n]>1300`)가 같은 날 앞서 고친 `micros()` 타이밍 버그(위 "텔레메트리 주기
  버그" 절) 이후 재보정되지 않은 채 남아 있었기 때문이다 — 보정된 타이머가 실제 ~4ms
  (≈250Hz) 센서 주기를 정확히 ~4000us로 보고하자 옛 700~1300 bound를 벗어났다.
  `dt[n]<700||dt[n]>1300` -> `dt[n]<2800||dt[n]>5200`(4배 재조정, 최초 micros() 버그 조사
  때 이미 flag했던 권장 범위와 일치), SPI poll timeout `5000U` -> `8000U`(margin 확보)로
  수정하고 ELF만 재빌드·재프로그램해 검증했다(단발 `s` 성공, `cpu_us=3389`가 보정된 벤치마크
  기준값과 근접).
- **재시험(9회, 원본과 동일 조건: fault injection 없음, 폐루프 구동 중)**: 9/9 class=0(정상),
  `abnormal_total` 9회 내내 0 — 원본의 `1,1,0`/66.7% abnormal 패턴은 재현되지 않았다.
- **sanity check**: SW3 ON(실제 토크 리플)으로 `s` 3회 추가 -> 2/3 abnormal — classifier가
  항상 정상만 내도록 고장난 것이 아니라 실제 신호에 반응함을 확인.
- **정직한 결론**: acquire() 타이밍 bound 버그는 확실히 실재했고 지금 고쳐졌다 — 독립적으로
  참인 사실이다. 다만 이 버그가 원본 `1,1,0` 패턴의 정확한 원인이었다는 것은 완전히 증명되지
  않았다 — 같은 기간 동안 watchdog 작업으로 인한 RTL 파이프라이닝 변경 등 다른 변수도 동시에
  바뀌었기 때문이다. 확실히 확립된 것은 현재 firmware+RTL 상태에서 통합 시스템이 안정적으로
  정상 판정을 내고(9/9, 오탐 0) fault injection에는 여전히 정확히 반응한다는 현재의 검증된
  상태다 — 원본 이상 현상의 정확한 메커니즘을 완전히 규명한 것은 아니다. deep-reasoner의
  Finding 1/2는 유효한 기술 기록으로 유지한다. 상세 원본 데이터는
  `artifacts/single_board_integration_2026-09-16.md`의 "분류 패턴 재현 시도" 절.
- **gate 영향**: `fourier/firmware/main.c`의 이 두 줄 수정(오늘 세 번째 `main.c` 변경, 앞선
  `micros()` 괄호 수정에 이어)도 실제 소스 변경이므로 원칙 10에 따라 `matlab.pass`/
  `sim.pass` marker를 다시 무효화한다. 다음 공식 `tools/run.py build` 전에 MATLAB Online과
  XSim을 다시 통과시켜야 한다 — 이번 세션에서는 수행하지 않았다.

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

1. ~~watchdog 지연 문제(1.489~1.6 s) 원인 규명.~~ **해결(2026-09-16).** AXI로
   `watchdog_count`를 직접 노출해 레지스터를 검증한 결과 RTL은 정상이었다(참 100 MHz,
   참 ~500 ms 트립) — 1.489~1.6 s는 이전 세션 측정 방법론의 인공물이었다. 상세는 위
   "2026-09-16 watchdog 근본원인 규명 (해결)" 절 참고.
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

**진행 현황 (2026-09-16 기준, 텔레메트리 버그 수정·5번 재시험·1번 watchdog 근본원인 규명
완료 반영):** 2번(PI/encoder
이식)과 3번(safety limiter 연결)은 RTL/빌드 수준에서 완료됐다(위 "2026-09-16 PI/encoder 이식
빌드 완료" 절 참고). 4번(단일보드 통합 실물 시험)은 같은 날 실제로 시작됐다 — 폐루프
PI/encoder 속도제어와 safety supervisor 반응 로직은 통합 시스템 실물에서 확정 PASS했지만(위
"2026-09-16 단일보드 통합 실물 시험" 절), PI 제어 중 진동분류가 `1,1,0` 주기 패턴을 보이는
새 미해결 질문이 생겨서 4번을 완결로 표시하지 않는다. **5번(12→9→12 V 외란 시험)은 같은 날
텔레메트리 버그 수정 후 정밀 재시험(Run 1, Run 2)으로 완결됐다** — 자세한 내용은 위 절 참고.
텔레메트리 전송 주기 버그(설계값 100 Hz 대비 실측 ~25 Hz)도 같은 날 근본원인 규명 및 수정을
마쳤다(99.5 Hz로 검증됨) — 더 이상 5번의 선행 과제가 아니다. **cpu_us/e2e_us 재측정도 같은 날
완료했다**: 수정된 firmware로 `b`(100회 replay benchmark)를 재실행한 결과 `cpu_us` 평균
`3391.43 us`(min 3387, max 3399, n=100), `e2e_us` 평균 `107.56 us`(min 106, max 110) —
예측한 4배 보정과 정확히 일치한다(기존 847 us × 4 = 3388, 기존 26.38 us × 4 = 105.52). 과거
HANDOFF.md에 기록된 847 us/26.38 us는 버그가 있던 시점의 실제 출력값이므로 지우지 않고 남겨
두되, 이 재측정치가 정확한 현재 기준값이다. `plcycles`(833)는 PL 하드웨어 카운터라 재측정해도
동일했다. **1번(watchdog 지연 원인 규명)도 같은 날 해결됐다** — AXI로 `watchdog_count`를
직접 노출해 레지스터를 검증한 결과 RTL은 정상이었고, 1.489~1.6 s는 이전 세션 측정
방법론의 인공물이었음이 밝혀졌다(위 "2026-09-16 watchdog 근본원인 규명 (해결)" 절 참고).
**"다음 작업 순서" 1~3, 5번은 모두 완료됐고, 4번(단일보드 통합 실물 시험)은 실질적으로
호전됐으나 완결로 표시하지 않는다.** PI 제어 중 분류 패턴(`1,1,0`) open question은 같은 날
후속 조사로 재검토됐다 — deep-reasoner 분석(모델 포화·리밋 사이클 가설)과 재현 시도 과정에서
`acquire()` 타이밍 검증 bound가 재보정되지 않은 실재 버그를 발견·수정했고, 수정 후 재시험
9/9이 전부 정상 판정(오탐 0)이었으며 fault injection에는 여전히 정확히 반응했다(2/3
abnormal). 다만 이 버그가 원본 `1,1,0` 패턴의 정확한 원인이었다는 것은 완전히 증명되지
않았다 — 같은 기간 동안 watchdog 작업의 RTL 파이프라이닝 변경 등 다른 변수도 함께 바뀌었기
때문이다. **실질적으로는 해결(현재 시스템은 검증된 정상 상태)이지만, 원본 관측의 정확한
메커니즘은 완전히 규명되지 않았다** — 상세는 위 "2026-09-16 분류 패턴 재현 시도" 절과
`artifacts/single_board_integration_2026-09-16.md` 참고.

## 저장소 상태

이 문서 작성 시점까지의 모든 실측 결과(재학습 모델, latch RTL, safety supervisor, 오실로스코프
확인, watchdog 이분탐색)는 커밋·push 완료돼 있다 (`git log`로 확인). encoder C1 배선은
2026-09-16에 완료됐고, "Zybo 단일보드 완전 통합" 순서의 4번(단일보드 통합 실물 시험)도 같은 날
실제로 시작돼 폐루프 PI/encoder 속도제어와 safety supervisor 반응 로직은 확정 PASS했다.
1번(watchdog 지연 원인 규명)도 같은 날 해결됐다(위 "2026-09-16 watchdog 근본원인 규명 (해결)"
절 참고) — RTL은 정상이었고 원인은 이전 측정 방법론의 인공물이었다. 남은 것은 PI 제어 중
진동분류가 보이는 `1,1,0` 주기 패턴 open question이다 — 같은 날 후속 조사로 관련된 실재
버그(acquire() 타이밍 bound)를 발견·수정했고 현재 시스템은 재시험에서 안정적으로 정상
판정하지만(9/9, fault injection 반응 유지), 원본 패턴의 정확한 메커니즘은 완전히 규명되지
않았다 — 위 "2026-09-16 분류 패턴 재현 시도" 절 참고.

**2026-09-16 최종**: 공식 MATLAB Online gate, 공식 XSim, 공식 `tools/run.py build`(내부 타이밍
게이트 1회 실패 후 확립된 AggressiveExplore 복구로 완료)를 이 세션 안에서 전부 재통과시켰고, 그
XSA로 Vitis platform/FSBL/ARM app도 재빌드했다 — 최종 해시는 위 "gate와 artifact의 정확한 현재
상태" 절 참고. 이 절 및 위의 모든 2026-09-16 작업(PI/encoder 이식, 단일보드 실물 시험, watchdog
근본원인 규명, 분류 패턴 조사, gate 재검증)은 이 문서 작성 시점 기준 아직 커밋되지 않았다 —
커밋은 사용자 확인 후 별도로 진행한다.
