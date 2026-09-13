# 작업 인수인계

## 먼저 지킬 조건

- `docs/PROJECT_RULES.md`와 `DESIGN.md`를 먼저 읽는다.
- 소스 변경 후에는 MATLAB, XSim, synthesis/implementation 순서를 다시 지킨다.
- 실행하지 않은 검증을 통과로 기록하지 않는다.
- 커밋 작성자는 `dlgus0630` 한 명으로 유지하고 공동 작성자 트레일러를 넣지 않는다.
- MPU breakout 전압과 L298N 점퍼를 확인하기 전에는 12 V 출력을 켜지 않는다.

## 유지할 설계 규칙

1. FFT/NPU는 설명 가능한 소형 구조를 유지하고 실제 데이터와 엄격한 검증으로 깊이를 높인다.
2. PC 학습, MATLAB Golden, Simulink, Verilog simulation, synthesis, implementation,
   보드 검증 순서를 지킨다.
3. FPGA에서는 학습하지 않고 `4 -> 4 ReLU -> 2` INT8 모델의 추론만 수행한다.
4. ARM은 센서 설정, 데이터 이동, 정책과 로그를 담당하고 PL은 FFT/NPU 및 hard real-time 제어를 담당한다.
5. 직접 작성하는 HDL은 Verilog-2001로 유지하며 SystemVerilog와 HDL Coder를 사용하지 않는다.
6. bit width, signedness, saturation, truncation 또는 shift 변경 전 `DESIGN.md`를 갱신한다.
7. MATLAB 중간값, C 기준 모델과 RTL testbench를 자동 비교한다.
8. 합성 데이터 정확도를 실제 설비의 고장 진단 정확도로 표현하지 않는다.
9. 실측 train/validation은 서로 다른 acquisition run으로 나눈다.
10. 실행하거나 측정하지 않은 결과를 PASS 또는 실측값으로 기록하지 않는다.

## 완료 상태

- MATLAB/Simulink Fourier 20/20 PASS
- XSim `tb_mac`, `tb_fft_npu`, `tb_core`, `tb_axi`, `tb_spi`, `tb_fourier_motor` PASS
- Vivado 2024.2 synthesis/implementation/bitstream PASS
- setup `+0.178 ns`, hold `+0.035 ns`, DRC Error 0
- Vitis 2024.2 standalone BSP, FSBL, ARM 앱 빌드 PASS
- JTAG에서 BRAM `0x40000000`, control `0x43C00004` 접근 확인
- 공식 bitstream을 Zybo에 내려받아 replay 100/100 전체 결과 일치 확인
- 공용 breakout의 실장 센서는 WHO_AM_I `0x70`, 즉 MPU-6500으로 확인
- MPU-6500에 `SMPLRT_DIV=3`을 적용해 64 sample 간격 평균 998.921 us, 범위 994..1004 us 확인
- 실제 sensor window의 CPU-PL FFT/NPU 결과 일치 확인

위 결과는 분리 전 동일 RTL의 공식 검증 결과이며 `artifacts/`에 증거를 보관했다. 저장소가
`Project07_VibrationNPU`로 분리되면서 소스 해시가 달라졌으므로, 다음 build 전에
`artifacts/matlab_input.zip`을 MATLAB Online에서 실행하고 XSim을 다시 실행해야 한다. gate를
통과시키기 위해 결과 파일이나 해시를 수동으로 만들지 않는다.

보드 초기 접근이 멈춘 원인은 `proc_sys_reset/aux_reset_in`이 active-low인데 0에 고정된 것이었다.
현재 `vivado/create_fourier.tcl`은 aux reset을 1에 연결하고 SmartConnect와 peripheral reset을
각각 올바른 active-low 출력에 연결한다. ARM 시간값이 0이던 문제는 `main.c` 시작에서 `usleep(1)`로
global timer를 시작해 해결했다. 이 두 수정은 제거하지 않는다.

## 바로 이어서 할 일

1. Zybo의 JTAG/UART USB와 전원을 연결하고 공식 `artifacts/fourier.bit` 및
   `artifacts/fourier_app.elf`를 올린다.
2. MPU 전압 호환을 확인한 뒤 `i` 명령으로 WHO_AM_I와 register readback을 확인한다. 공용
   `MPU-9250/6500` PCB이며 현재 실물은 `0x70`, 즉 MPU-6500으로 확인됐다.
3. `docs/REAL_DATASET.md`에 따라 `tools/capture_dataset.py`로 정상/이상 raw 64 sample을 독립
   acquisition run으로 반복 저장한다.
4. 같은 도구의 `build` 명령으로 run 단위 train/validation 데이터를 만든 뒤
   `tools/train_export.py --real-data <폴더>`로 재학습한다.
5. 새 weight를 사용하면 MATLAB부터 모든 검증을 다시 수행한다.

실측 수집 도구와 회귀 테스트는 구현되어 있으며 `python3 tools/test_capture_dataset.py`가 PASS했다.
Zybo JTAG/UART, MPU-6500 초기화와 정지 상태 raw 수집도 실물에서 확인했다. 모터 정상/이상 run은
아직 수집하지 않았으므로 실제 분류 성능으로 기록하지 않는다.

현재 합성 모델의 class 0/1 이름을 실제 정상/고장 상태로 바꾸면 안 된다. 64 sample, 1 kHz의 FFT
간격은 15.625 Hz이므로 110 RPM 출력축의 약 1.83 Hz를 직접 분해하지 못한다. 모터 하우징 진동의
고조파·광대역 차이를 먼저 관찰한다.

## 보드 콘솔

- `r`: 제공 입력 한 번 replay
- `b`: replay 100회와 timing 출력
- `i`: MPU-6500/9250 초기화와 ID/readback
- `d`: raw 64 sample 출력
- `s`: sensor sample 후 FFT/NPU 실행

12 V와 센서가 연결되지 않은 상태에서는 `r`, `b`만 사용한다.

2026-09-13 센서 실측 증거는 `artifacts/mpu6500_hardware_summary_2026-09-13.json`과 해당 파일에
열거된 UART CSV에 보관했다. 공식 ARM ELF SHA-256은
`175fa0cf42e1ff9eb20dcff6e5b7ae11dbb95d906a1c40d785885516f75b9219`다.

센서 호환 펌웨어는 Vitis build, 실물 초기화, 1 kHz 샘플 수집, live CPU-PL 비교와 replay 회귀를
통과했다. 이 변경 이후 전체 MATLAB source-digest/XSim/Vivado gate는 재실행하지 않았다. 실제 모터
run으로 재학습하면 model/weight도 함께 바뀌므로, 그 시점에 전체 gate를 한 번 다시 실행한다.
