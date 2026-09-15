# Project07 continuation guide — 2026-09-15

이 문서는 다음 작업자가 대화 기록을 다시 읽지 않고 현재 작업을 이어가기 위한 실행 기준이다.
`artifacts/`는 source digest에서 제외되므로 MATLAB gate 실행 중에도 이 문서를 갱신할 수 있다.
상충하는 메모가 있으면 실제 파일, gate marker, SHA-256, UART 원본 순서로 확인한다.

## 1. 가장 먼저 확인할 것 (2026-09-15 갱신)

`matlab_results (16).zip`으로 MATLAB gate와 XSim 8/8이 이전 digest(`422079b8…`)로 모두 PASS했고,
그 결과가 커밋 `eb21f85`로 들어갔다. 이후 검토에서 그 커밋의 문서(`docs/SAFETY_SUPERVISOR.md`,
`README.md`, `HANDOFF.md`)에 실제로 오실로스코프/듀티 실측 없이 PASS라고 쓴 과장 표현이 여러 곳
발견되어, 사실 수준에 맞게 정정하고 같은 커밋에 amend했다 (`93e0615`, author/committer
`dlgus0630 <dlgus0630@naver.com>` 단독, push 안 함).

**설계 변경 (2026-09-15, 두 번째 갱신): digest 범위에서 설명용 문서를 뺐다.** 사용자가 README/HANDOFF
같은 prose 문서를 언제든 자유롭게 고칠 수 있어야 한다고 판단해서, `tools/gates.py:digest()`와
`matlab/source_digest.m`을 동일하게 고쳐 **모든 `.md` 파일을 확장자 기준으로 digest 계산에서
제외**했다 (`artifacts/reports/build/measurements/__pycache__/.git` 디렉터리 제외는 그대로 유지).
`tools/package_matlab.py`도 zip에는 `.md`를 그대로 담되 digest 검증 대상에서는 뺐다. 이제부터
RTL/firmware/MATLAB 스크립트/테스트/데이터 파일만 digest에 들어가고, README/HANDOFF/docs/*.md
수정은 게이트를 무효화하지 않는다. 세 파일 모두 exclusion 로직이 완전히 동일한지 항상 대조해서
유지할 것 — 하나만 고치면 Python/MATLAB digest가 영구히 갈라진다.

이 알고리즘 변경 자체가 digest를 다시 바꿨다. 사용자는 아래 새 패키지를 MATLAB Online에 올려야 한다.

- 로컬 파일: `artifacts/matlab_input.zip` (`tools/package_matlab.py`로 재생성 완료)
- ZIP SHA-256: `71dbe9c9c6834050cf0600fa44cada1245b18bee7012f9373612c14e84b87ccb`
- package source digest: `f1901eba6458efde05adff4a7101e76b677b0181f5d9575574d3da05adb34fbe`
- MATLAB 내부 경로/실행 명령/기대 출력은 이전과 동일 (`RUN_MATLAB_CHECKS` ->
  `MATLAB/SIMULINK PASS. Download reports/matlab_results.zip.`)
- `tools/gates.py`, `matlab/source_digest.m`, `tools/package_matlab.py`, `artifacts/matlab_input.zip`
  변경은 별도 커밋으로 남길 계획이며 (안전 supervisor 커밋 `93e0615`와 분리), 이 문서 작성 시점에
  아직 commit 여부를 확정하지 않았다면 `git log -1`로 실제 반영 여부를 먼저 확인한다.

**사용자가 새 `matlab_results.zip`을 반환하기 전에는 `artifacts/`와 `reports/` 밖의 파일을 수정하지
말 것.** 소스, README, HANDOFF, docs를 한 글자라도 바꾸면 위 digest와 반환 marker가 무효가 된다.

물리적 마지막 확정 상태는 watchdog clear 뒤 SW0 ON 재가동, 모터 회전, PSU 약 0.13 A였다. 그 직후
사용자에게 `SW0 OFF -> PSU OUTPUT OFF` 종료를 안내했으나 이 문서 작성 시점에는 종료 확인 답변을
받지 못했다. 다음 하드웨어 작업 전 반드시 두 상태를 확인한다. 배선을 바꿀 때는 보드와 PSU까지 끈다.

사용자가 주간 사용량 7% 이하라고 알리면 새 빌드나 실물 시험을 시작하지 않는다. 실행 중인 짧은
검증만 안전하게 마치고, 하드웨어를 `SW0 OFF -> PSU OUTPUT OFF`로 종료한 뒤 이 문서를 갱신하고
다음 AI에게 넘긴다.

## 2. 사용자 목표와 운영 규칙

- 목표 직무는 FPGA/SoC이며, 학부 포트폴리오 최고 수준을 넘어 개인 석사 수준의 설계·검증 근거를
  만들고 싶어 한다.
- 사용자는 시간이 부족하다. 여러 사소한 단계로 쪼개지 말고 한 번에 필요한 핵심 행동만 안내한다.
- 실제로 실행하거나 측정하지 않은 항목을 PASS, 실측, 완료라고 쓰지 않는다.
- 실패는 숨기지 않고 원인, 수정, 회귀검증을 함께 남긴다.
- 통제된 32 Hz 토크 리플과 저장된 이상 window를 자연 발생 베어링 고장으로 표현하지 않는다.
- 개발 순서는 PC/정수 Golden -> MATLAB/Simulink -> 전체 XSim -> Vivado timing/DRC -> 보드 실측이다.
- 직접 작성 HDL은 Verilog-2001이다. SystemVerilog와 HDL Coder를 사용하지 않는다.
- FPGA에서는 학습하지 않고 INT8 inference만 한다.
- Git 작성자와 기여자는 `dlgus0630 <dlgus0630@naver.com>` 한 명만 유지한다.
- 커밋 메시지, 파일, PR에 공동작성자 trailer나 특정 작성 도구 이름을 넣지 않는다.
- 사용자는 최종 검증 뒤 GitHub 업로드를 이미 요청했다. gate를 모두 통과한 뒤 이 저장소만 명시적으로
  stage하고 사용자 identity로 commit/push한다. 그 전에는 commit/push하지 않는다.
- 상세 프로젝트 원칙은 `docs/PROJECT_RULES.md`를 그대로 따른다.

## 3. 저장소와 범위

작업 루트:

```text
/home/dlgus0630/Downloads/fpga_fourier_pid_v4
```

현재 대상 저장소:

```text
Project07_VibrationNPU
remote: git@github.com:dlgus0630/Project07_VibrationNPU.git
branch: main
last committed baseline: 5efb3b38529208229b45ca3075ae67295ec05d37
```

별도 기준선 저장소:

```text
Project07_MotorControl
remote: git@github.com:dlgus0630/Project07_MotorControl.git
branch: main
```

두 저장소는 역할이 다르다.

- `Project07_MotorControl`: Basys3 pure RTL, encoder hybrid estimator, fixed-point PI, anti-windup
- `Project07_VibrationNPU`: Zybo PS/PL, MPU-6500 SPI, FFT64, INT8 NPU, 모터 안전 supervisor

Basys3 전체 PI를 Zybo에 복제하지 않는다. 포트폴리오에서는 두 결과를 하나의 상태감시·제어 시스템
스토리로 연결하되, 구현 저장소와 기술 핵심은 분리한다.

## 4. 하드웨어와 배선

- Board: Zybo Z7-20
- Sensor: MPU-6500, `WHO_AM_I=0x70`
- Motor: JGB37-520, 12 V, 110 RPM, Hall encoder 내장
- Driver: L298N, ENA jumper 제거
- PSU: 12.0 V, current limit 0.5 A

| 신호 | 연결 |
|---|---|
| MPU SCLK | Zybo JE1 |
| MPU MOSI/SDA | Zybo JE2 |
| MPU MISO/AD0 | Zybo JE3 |
| MPU CS/NCS | Zybo JE4 |
| MPU GND | Zybo JE5 GND |
| MPU VCC | Zybo JE6 3.3 V |
| Zybo JD1 | L298N ENA/PWM |
| Zybo JD2 | L298N IN1 |
| Zybo JD3 | L298N IN2 |
| Zybo JD5 | 공통 GND |
| Motor red/white | L298N OUT1/OUT2 |
| PSU +12 V | L298N +12V |
| PSU GND | L298N/Zybo 공통 GND |
| Encoder black | 공통 GND |
| Encoder blue/green/yellow | 현재 미사용·절연 |

센서는 모터 전면 하단 검정 gearbox bracket에 절연층을 두고 고정했다. 위치나 방향을 바꾸면 기존
학습 데이터와 직접 비교하지 않는다. 전원 인가 중 배선 변경 금지. 종료 순서는 항상
`SW0 OFF -> PSU OUTPUT OFF`다.

스위치 계약:

```text
SW0: OFF를 거친 뒤 ON해야 arm
SW2:1 = 10: 정상 50% duty
SW3 OFF: 정상 50% 고정 duty
SW3 ON: 25%/75%를 32 Hz로 교대하는 통제된 토크 리플
BTN0: emergency stop
```

## 5. 최종 안전 supervisor 설계

데이터 경로:

```text
MPU-6500 -> Cortex-A9 SPI acquisition -> AXI + dual-port BRAM
         -> PL radix-2 FFT64 -> 4-band feature -> 4x4x2 INT8 NPU
         -> PL safety supervisor -> L298N PWM/direction -> motor
```

정책:

```text
class1 1회: warning, 기존 요청 duty 유지
class1 2회 연속: derated, PWM 최대 25%
class1 3회 연속: classifier latch, PWM/IN1 LOW
derate 뒤 class0: warning/derate 해제 및 NORMAL 복구
arm 중 heartbeat 500 ms 단절: watchdog latch, PWM/IN1 LOW
SW0 OFF: latch/cause/consecutive clear, lifetime abnormal count 보존
```

핵심 파일:

- `fourier/rtl/safety_supervisor.v`
- `fourier/rtl/fourier_motor_control.v`
- `fourier/rtl/axi_vibration_top.v`
- `fourier/firmware/main.c`
- `fourier/tb/tb_safety_supervisor.v`
- `fourier/tb/tb_fourier_motor.v`
- `fourier/tb/tb_axi.v`
- `docs/SAFETY_SUPERVISOR.md`

AXI register:

| Offset | 내용 |
|---|---|
| `0x04` | bit3 latch, bit4 warning, bit5 derated, bit6 watchdog |
| `0x48` | PS heartbeat write pulse |
| `0x4C` | consecutive, warning, derated, cause, lifetime abnormal count |

UART:

```text
i: sensor init
s: live 64-sample acquisition + inference
f: safety status
x: one stored real abnormal window through CPU golden + PL FFT/NPU
r: stored normal/fault pair replay
```

`x`는 지속 이상 분기 재현용 검증 명령이다. 저장된 실제 이상 센서 window를 사용하지만 자연 고장
발생을 뜻하지 않는다. `main.c`는 blocking acquisition 중 16 sample마다 heartbeat를 보낸다.

## 6. 완료된 formal gate와 artifact

안전 확장 RTL과 첫 firmware 기준으로 완료된 결과:

- MATLAB/Simulink: 당시 source digest 일치 PASS
- XSim: 8/8 PASS (`tb_mac`, `tb_fft_npu`, `tb_core`, `tb_axi`, `tb_spi`, `tb_fault_latch`,
  `tb_safety_supervisor`, `tb_fourier_motor`)
- Vivado post-route setup WNS `+0.015 ns`
- hold WHS `+0.031 ns`
- DRC Error 0
- LUT 11,332, register 7,333, BRAM tile 1, DSP 5

최종 PL artifact:

| 파일 | SHA-256 |
|---|---|
| `artifacts/fourier_safety_supervisor.bit` | `a57f472a1c4f31c3baa10cf35126dbf65b2e4557dc1b1296f290e3dd5aceb255` |
| `artifacts/fourier_safety_supervisor.xsa` | `344c6a754543682bf382fea537357506bdc3d15db90fb5c3a177d0c814a865b1` |
| `artifacts/fourier_safety_supervisor.elf` | `be278a0fe3efc8fd9039983a5a125ef6dc10b759de91e713e65274a34af39a21` |

마지막 ELF는 heartbeat 보강과 `x` 명령을 포함한다. 이 변경은 ARM firmware뿐이므로 PL bit/XSA를
재구현할 필요는 없다. 다만 repository gate 규칙상 최신 MATLAB marker와 XSim marker는 갱신한다.

## 7. 2026-09-15 실물 결과

모든 UART/JTAG 원본은 `artifacts/safety_logs_2026-09-15/`, 설명은
`artifacts/safety_supervisor_hardware_2026-09-15.md`에 있다.

### 정상과 실제 센서 완화 경로

- 정상 회전: 12.0 V, 약 0.13 A
- live sensor class0 3/3
- CPU/PL match 3/3
- warning/derate/latch/watchdog 모두 0
- SW3 토크 리플 live class 결과 `1,1,0`
- 1회: warning
- 2회: PWM 25% 제한
- 3회: 제한이 진동을 정상으로 낮춰 class0, 자동 NORMAL 복구
- lifetime abnormal count 2

### 지속 이상 최종 정지

정상 모터 회전 중 저장된 실제 이상 window를 `x`로 3회 통과시켰다.

| 횟수 | class | warning | derated | latched | cause |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 1 | 0 | 0 | 0 |
| 2 | 1 | 1 | 1 | 0 | 0 |
| 3 | 1 | 0 | 0 | 1 | 1 |

- CPU/PL match 3/3
- 모터 정지, 전류 약 `0.13 A -> 0.01 A`
- 시간 경과 뒤에도 classifier latch 유지
- SW0 OFF로 latch/cause/consecutive clear, lifetime count 3 보존
- SW0 ON 재arm 후 모터 회전, 약 0.13 A

### Heartbeat watchdog

- 정상 arm 상태에서 Cortex-A9 #0을 JTAG로 1.010 s 정지 후 재개
- 정지 중 PL이 모터 latch 차단
- 재개 후 `latched=1`, `watchdog=1`, `cause=2`, `consecutive=0`
- 모터 정지, 전류 약 `0.13 A -> 0.01 A`
- SW0 OFF clear 뒤 cause/watchdog 0
- SW0 ON 재arm 뒤 모터 회전, 약 0.13 A

RTL timeout은 50,000,000 cycle @ 100 MHz = 500 ms다. 이번 시험은 차단이 1.010 s halt 구간 안에
발생했음을 증명한다. 정확한 물리 차단 시간을 500 ms로 실측했다고 쓰면 안 된다. 그 수치는 JD1
오실로스코프 single-shot을 수행한 뒤에만 기록한다.

초기 normal test에서 `cause=2`가 한 번 발생했으나 class0 3/3, abnormal_total 0이어서 기계 고정
문제가 아니었다. SW0 clear 후 PSU OFF armed 5초, 동일 sensor 3-window 재현, powered normal 3/3에서
재발하지 않았다. firmware에 acquisition 중 heartbeat를 보강한 뒤 최종 시험을 수행했다.

## 8. 사용자가 MATLAB 결과를 보내면 즉시 할 일

1. 새 ZIP 경로와 SHA-256을 기록한다. 예전 `matlab_results (1)..(15).zip`을 잘못 쓰지 않는다.
2. ZIP의 `reports/matlab.pass`가 아래 digest인지 먼저 확인한다.

```text
422079b82774fa927e9590a17f90c525075f9103a3bfb072c4fee4ab3c2ede18
```

3. ZIP을 저장소 루트에 풀어 `reports/`를 갱신한다.
4. gate를 확인한다.

```bash
cd /home/dlgus0630/Downloads/fpga_fourier_pid_v4/Project07_VibrationNPU
python3 tools/gates.py check matlab
```

5. 공식 XSim 8/8을 실행한다.

```bash
cd /home/dlgus0630/Downloads/fpga_fourier_pid_v4/Project07_VibrationNPU
VIVADO=/tools/Xilinx/Vivado/2024.2/bin/vivado python3 tools/run.py sim
python3 tools/gates.py check sim
```

Vivado 실행은 하드웨어/JTAG와 무관하다. `run_simulations.tcl`이 MATLAB marker를 먼저 검사하고,
8개 testbench 모두 PASS해야 현재 digest의 `reports/sim.pass`를 만든다.

시스템 Python에는 이 문서 작성 시점에 `numpy`가 없어 `tools/offline_check.py`가 import 단계에서
종료됐다. 이것은 알고리즘 FAIL이 아니다. 이미 MATLAB Online이 같은 최신 정수 Golden과 Simulink를
검증하므로 package 설치를 위해 작업을 중단하지 말고 MATLAB/XSim gate를 우선한다.

## 9. 최종 Git 절차

MATLAB marker와 XSim 8/8이 현재 digest로 통과한 뒤:

1. `git diff --check`
2. 결과 문서의 PASS/미완료 표현 대조
3. 특정 자동작성 도구명, 공동작성자 trailer, 자동 생성자 표기가 없는지 `rg`로 전체 점검한다.

4. `git status --short`에서 `Project07_VibrationNPU` 내부 파일만 stage한다.
5. `artifacts/p07_safety_v2.zip`과 `artifacts/p07_safety_final.zip`은 MATLAB 전달용 중복 ZIP이므로
   commit 대상에서 제외한다. 추적 중인 `artifacts/matlab_input.zip`은 포함한다.
6. 다음 결과물은 포함한다: 최종 source/docs/tests, safety bit/XSA/ELF, programming Tcl,
   `artifacts/safety_supervisor_hardware_2026-09-15.md`, `artifacts/safety_logs_2026-09-15/`, 이 문서.
7. identity 확인:

```bash
git config user.name
git config user.email
```

기대값은 `dlgus0630`, `dlgus0630@naver.com`이다. 공동작성자 trailer 없이 최종 설계 내용을 설명하는
일반적인 커밋 메시지를 사용한다. commit 뒤 `git show --format=fuller -1`로 author/committer를 확인하고
`git push origin main`을 수행한다. 사용자는 최종 검증 후 GitHub 업로드를 이미 요청했다.

## 10. 선택 확장과 우선순위

안전 supervisor 핵심 구현은 완료됐다. 포트폴리오 증거를 한 단계 더 강화할 때 가장 효율적인 추가
시험은 오실로스코프 JD1 single-shot이다.

1. 50% 정상 PWM
2. 두 번째 이상 뒤 25% 제한 PWM
3. 세 번째 이상 또는 watchdog 뒤 LOW
4. ARM halt edge와 JD1 LOW의 실제 지연

오실로스코프를 하지 않으면 현재 결과가 무효인 것은 아니다. 정확한 차단 지연 실측 주장만 제외한다.

별도 `Project07_MotorControl`의 고급 미완료 항목은 `12->9->12 V` 외란 3회, open-loop 다단 duty
모델 식별, 모델 기반 PI 재설계 비교, encoder C2 quadrature/illegal-transition 검출이다. 이것들은
현재 VibrationNPU 최종 gate와 Git 업로드를 끝낸 다음 별도 작업으로 진행한다. Zybo에 Basys3 PI 전체를
다시 구현하는 것은 역량 중복이 커서 우선순위가 낮다.

## 11. JTAG/UART 참고

- JTAG target: `ARM Cortex-A9 MPCore #0`, FPGA `xc7z020`
- UART는 마지막 작업에서 `/dev/ttyUSB1`, 115200 baud였다. USB 재연결 뒤 번호가 바뀔 수 있다.
- FT2232 interface 0은 JTAG, interface 1은 UART다.
- Wine의 `winedevice.exe`가 FT2232를 점유하면 Vivado/XSCT가 target을 못 찾을 수 있다.
- 과거 `echo '1-4:1.0' | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind`가 끝에 `No such device`를
  표시했지만 interface 0은 실제로 unbind됐고 JTAG가 동작했다. 재연결 후에는 `lsusb -t`로 확인한다.
- programming script: `artifacts/program_zybo_safety.tcl`
- 이 스크립트는 system reset -> safety bit -> PS init -> 최신 safety ELF -> continue 순서다.

현재 작업을 재개할 때 첫 판단은 새 MATLAB 결과가 도착했는지다. 도착했다면 8절부터 실행한다.
도착하지 않았다면 source를 건드리지 말고 기다리거나 `artifacts/` 문서만 갱신한다.
