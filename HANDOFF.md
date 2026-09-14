# 작업 인수인계

기준 시각은 2026-09-14이며, 다음 작업 세션은 이 문서와 `docs/PROJECT_RULES.md`, `DESIGN.md`를
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

## 프로젝트 범위

이 저장소는 Project07의 통합 SoC 결과물이다.

```text
MPU-6500 X축 -> Cortex-A9 SPI 수집 -> dual-port BRAM
             -> PL FFT64 -> 4 band -> 4x4x2 INT8 NPU
             -> 연속 이상 판정 -> PL motor limit/latched stop (아직 구현 전)
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

## 완료된 실물 수집

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

재학습 전 fault-injection acquisition bit는 아래 검증을 통과했다.

- MATLAB/Simulink PASS
- XSim 6/6 PASS
- post-route timing: setup `+0.010 ns`, hold `+0.032 ns`
- DRC Error 0
- Zybo motor normal/fault mode와 MPU UART 실물 PASS
- `artifacts/fourier.bit` SHA-256:
  `98ea0a59087d08f5507aa9d796f8be67616c76b125e4e6290687ea308f3a48c5`
- 이전 bit 백업 `artifacts/fourier_pre_fault_injection.bit` SHA-256:
  `ee5f55296147652112a3a44e4b765aff1c54cffb9577e6f231773a3deac8673f`
- 현재 보드에 올린 ELF SHA-256:
  `175fa0cf42e1ff9eb20dcff6e5b7ae11dbb95d906a1c40d785885516f75b9219`

중요: 재학습으로 `data/`와 `model_data.h`가 바뀌었다. 따라서 위 bit와 ELF에는 새 실측 모델이
아직 들어 있지 않다. 현재 `reports/matlab.pass`와 `reports/sim.pass`도 새 소스 digest에는 유효하지
않다. 새 모델의 MATLAB, XSim, Vivado, ELF 재빌드와 Zybo 검증이 다음 필수 작업이다.

## 다음 작업 순서

1. 현재 전체 소스로 MATLAB 입력을 만든다.

   ```bash
   python3 tools/package_matlab.py
   ```

2. `artifacts/matlab_input.zip`을 MATLAB Drive에 업로드하고 다음을 실행한다.

   ```matlab
   bdclose('all');
   clear functions;
   cd('/MATLAB Drive');
   if isfolder('Project07_real_model_final')
       rmdir('Project07_real_model_final','s');
   end
   unzip('matlab_input.zip','Project07_real_model_final');
   cd('/MATLAB Drive/Project07_real_model_final/Project07_VibrationNPU');
   RUN_MATLAB_CHECKS
   ```

3. PASS 뒤 `reports/matlab_results.zip`을 이 저장소 루트로 가져와 압축을 풀고
   `python3 tools/gates.py check matlab`로 source digest 일치를 확인한다.
4. `python3 tools/run.py sim`을 실행해 XSim 6개를 모두 통과시킨다.
5. `python3 tools/run.py build`로 새 실측 가중치가 포함된 bit/XSA를 만든다. setup과 hold slack이
   모두 0 이상이고 DRC Error 0인지 확인한다. 직전 구현은 최초 route setup `-0.046 ns`였으나
   post-route `phys_opt_design -directive AggressiveExplore`로 `+0.010 ns`가 됐다. 같은 문제가 나면
   위 명령을 적용하고 최종 timing report를 다시 생성하되 음수 slack bit를 사용하지 않는다.
6. 새 XSA로 Vitis standalone 앱을 다시 build한다. `model_data.h`가 변경됐으므로 기존
   `artifacts/fourier_app.elf`를 재사용하지 않는다.
7. 새 bit와 ELF를 Zybo에 프로그램한 뒤 replay 100회 CPU/PL 일치와 normal/fault 실시간 분류를
   각각 독립적으로 측정한다. validation 정확도는 PC 수치만으로 PL 실측 PASS로 대체하지 않는다.
8. 실측 분류가 확인된 다음 PL에 연속 이상 frame 판정과 latched stop을 추가한다. 권장 최소 설계는
   3회 연속 class 1에서 fault latch, SW0 OFF에서만 clear, BTN0 즉시 차단이다. 예상 판정시간은
   64 ms window 기준 약 192 ms이며 실측한다. testbench에 단발성 class 1 무시, 3회 연속 latch,
   latch 유지, SW0 clear를 넣는다.
9. 최종 bit에서 `정상 운전 -> SW3 ON -> NPU 이상 판정 -> motor PWM 차단 -> latched fault`를
   UART와 오실로스코프로 함께 측정한다. 이 결과가 통합 프로젝트의 최종 증거다.

## 제한과 선택 확장

- class 1은 통제된 토크 리플이며 자연 고장 일반화 결과가 아니다.
- 정상 run 3개를 먼저, class 1 run 3개를 나중에 수집했으므로 온도 추세가 class와 결합됐을 수 있다.
- 최소 데이터셋은 완성됐다. 더 강한 통계가 필요하면 다른 날 조건을 번갈아 3 run씩 추가한다.
- oscilloscope는 최종 통합에서 JD1 PWM과 fault latch 직후 차단 시간을 증명할 때 사용한다.
- 전압 외란, encoder C2 quadrature, Zybo에 Basys3 전체 PI 이식은 최종 통합 뒤 선택 항목이다.
- `Project07_MotorControl`의 pure-RTL 제어 결과와 중복되는 기능 확장은 우선순위가 낮다.

## 저장소 상태

실측 수집, fault-injection RTL, 실제 데이터 모델 파일과 문서가 아직 커밋되지 않았다. 커밋 전에
`git diff --check`, MATLAB/XSim/Vivado gate, 새 ELF와 최종 보드 검증을 완료하는 편이 안전하다.
중간 체크포인트가 필요하면 사용자 계정의 이름과 이메일로만 커밋하고 공동 작성자 표기를 넣지 않는다.
