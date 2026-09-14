# 실측 모델 Zybo 하드웨어 검증 기록

2026-09-14. 실측 데이터로 재학습한 모델을 담은 bitstream과 ARM ELF를 Zybo Z7-20에
프로그램하고 replay 일치와 실시간 분류를 측정했다. 이 문서는 `artifacts/` 아래에 있어
source digest에 포함되지 않는다. `README.md`, `DESIGN.md`, `docs/`에 대한 반영은 다음
RTL 변경과 함께 한 번에 수행하고 그때 MATLAB/XSim/Vivado 게이트를 다시 통과시킨다.

## 검증에 사용한 artifact

| 항목 | SHA-256 |
|---|---|
| `artifacts/fourier.bit` | `6a1fcd2477a063eabf23852596d00e111b091eebd291b49f0b5399a37a70ff28` |
| `artifacts/fourier.xsa` | `70e2122d94bc560a4bf48df22418fd5fc04aaeb0f9f1c31c8211d3aa574aa5ec` |
| `artifacts/fourier_app.elf` | `8bd647a3f71f0b02abdffdd351bc3a74ac5df313872048c942338f7444c8a810` |
| 직전 bit (보존) | `98ea0a59087d08f5507aa9d796f8be67616c76b125e4e6290687ea308f3a48c5` |
| 직전 ELF (보존) | `175fa0cf42e1ff9eb20dcff6e5b7ae11dbb95d906a1c40d785885516f75b9219` |
| source digest | `f3924de3018720bcc99c0e55c711df8e9f56691b89f6d98573d070207a2109c7` |

보드: Zybo Z7-20, JTAG serial `210351BD7304A`, UART `/dev/ttyUSB1` 115200 8N1.
PSU 12.0 V, current limit 0.5 A. 모터 JGB37-520, 드라이버 L298N, 센서 MPU-6500.

## 1. 프로그래밍

`fpga` 다운로드 후 `ps7_init`이 다음 오류로 실패했다.

```text
Cannot read memory if not stopped.
Context ARM Cortex-A9 MPCore #0 state: APB AP transaction error, DAP status 0xF0000021
```

원인은 보드가 이전 펌웨어를 실행 중이어서 APU가 debug access port를 점유한 상태였기
때문이다. `rst -srst`로 시스템을 리셋한 뒤 core 0을 `stop`하고 `ps7_init`을 실행하면
해결된다. 또한 level-0 ARM 타겟 이름이 정상 상태에서는 `APU`, DAP 오류 상태에서는 `DAP`로
바뀌므로 타겟 필터가 두 이름을 모두 받아야 한다.

확정된 순서는 다음과 같다.

```text
connect
targets -set -nocase -filter {name =~ "APU*" || name =~ "DAP*"}
rst -srst ; after 3000
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file artifacts/fourier.bit
targets -set -nocase -filter {name =~ "ARM*#0"}
stop ; configparams force-mem-access 1
source artifacts/ps7_init.tcl ; ps7_init ; ps7_post_config
rst -processor
dow artifacts/fourier_app.elf
configparams force-mem-access 0
con
```

## 2. replay CPU/PL 일치

센서와 모터를 쓰지 않는 내장 입력 검증이다. `SW0`은 OFF, PSU 출력은 OFF였다.

`r` 명령 결과를 PC 정수 기준검증 결과(`data/features.mem`, `hidden.mem`, `logits.mem`,
`class.mem`)와 필드 단위로 대조했고 전부 일치했다.

```text
case 0  features [1,1,2,3]  hidden [7,7,10,9]  logits [-3,1]    class 1   전부 일치
case 1  features [3,1,3,4]  hidden [0,0,0,0]   logits [-61,60]  class 1   전부 일치
```

`b` 명령 100회 결과:

```text
RESULT 줄 수   100
match=1        100 / 100
cpu_us         min 846   max 849   mean 847.40
pl_cycles      min 833   max 833   mean 833.00
npu_cycles     min 18    max 18    mean 18.00
e2e_us         min 26    max 27    mean 26.38
```

PL 순수 연산은 833 cycle @100 MHz = 8.33 us이고 ARM 소프트웨어 구현은 847 us다.
AXI 전송을 포함한 end-to-end 26.38 us 기준으로 약 32배다.

원본: `measurements/hw_validation_2026-09-14/hw_replay_real_model_r.csv`, `measurements/hw_validation_2026-09-14/hw_replay_real_model_b100.csv`

### 내장 데모 입력에 관한 주의

`tools/train_export.py:102`가 golden case를 다음처럼 고른다.

```python
order=[int(np.flatnonzero(yv==0)[0]), int(np.flatnonzero(yv==1)[0])]
```

따라서 `demo_samples[0]`은 validation set의 첫 번째 정답 정상 window다. 그런데 모델은
이것을 class 1로 예측한다. 즉 재학습 confusion matrix `[[58,2],[0,60]]`의 false positive
2건 중 하나가 데모 슬롯에 뽑혔다. logits가 `-3` 대 `1`로 마진이 4에 불과하다.
PC, ARM, PL 세 곳이 모두 같은 값을 내므로 하드웨어 문제는 아니다. 펌웨어가 이 슬롯을
`replay_normal`로 출력하므로 시연 시 오해를 살 수 있다. 실시간 측정에서는 정상 window의
마진이 최소 55였으므로 이 문제는 데모 입력 선택에 한정된다.

## 3. 실시간 분류 1차 측정

센서 초기화 `i` 결과는 `WHO_AM_I,0x70`, `SENSOR_MODEL,MPU-6500`, `SENSOR_READY,1`이다.
샘플 간격을 `d`로 직접 측정해 998.8 us, 즉 1001.2 Hz임을 확인했다. 타이밍 폐기 window는 0건이다.

조건은 `SW2` ON, `SW1` OFF, `SW0` arm이고 정상은 `SW3` OFF, 이상은 `SW3` ON이다.

```text
정상 60 window   class 0 60개, class 1 0개    CPU/PL 60/60
이상 60 window   class 1 9개  = 검출률 15.0%  CPU/PL 60/60
```

정상은 완벽했으나 이상 검출률이 학습 시 98%에서 15%로 떨어졌다. CPU와 PL이 계속 일치하므로
연산 경로 문제가 아니다.

원본: `measurements/hw_validation_2026-09-14/hw_live_normal_real_model.csv`, `measurements/hw_validation_2026-09-14/hw_live_fault_real_model.csv`

## 4. 근본원인 분석

four-band feature 평균을 학습 데이터와 비교했다.

| band | 대역 | 학습 정상 → 이상 | 1차 실측 정상 → 이상 |
|---|---|---|---|
| 0 | 16~94 Hz | 0.92 → **3.49** | 0.85 → 0.98 |
| 1 | 109~188 Hz | 0.79 → 1.22 | 0.68 → **3.17** |
| 2 | 203~313 Hz | 1.03 → **2.93** | 0.97 → 1.52 |
| 3 | 328~484 Hz | 1.92 → 3.00 | 1.67 → 2.25 |

정상 상태는 학습 데이터와 거의 같았으나 이상 상태의 에너지가 band 0에서 band 1로 이동했다.
모델은 band 0 증가를 이상의 근거로 학습했으므로 이 신호를 인식하지 못한다.

원시 파형 스펙트럼으로 확인했다.

```text
학습 이상 데이터 상위 성분   62.6 Hz, 78.2 Hz, 46.9 Hz   (32 Hz의 1.5~2.5 배음)
1차 실측 이상 상위 성분      125.2 Hz                    (32 Hz의 4 배음)
detrended raw RMS            학습 이상 107.1  →  1차 실측 77.4
```

fault injection 자체는 `fourier/rtl/fourier_motor_control.v`에서 `FAULT_HZ=32`으로 고정돼
있고 이 파일은 09:24 이후 변경되지 않았다. 데이터 수집은 10:27이므로 주입 회로는 동일하다.
샘플링 주파수도 1001.2 Hz로 정상이다. 따라서 원인은 기계적 전달 경로에 있다.

`docs/HARDWARE.md`와 인수인계 문서가 경고한 항목과 일치한다. 센서 고정 상태가 달라지면
32 Hz 토크 리플의 어느 배음이 증폭되는지가 바뀌고, 그 결과 band 분포가 이동한다.

## 5. 센서 재고정 후 2차 측정

전원을 내리고 센서를 다시 고정한 뒤 같은 조건으로 재측정했다.

```text
정상 30 window   class 0 28개, class 1 2개   오검출 6.7%
이상 60 window   class 1 60개               검출률 100.0%
CPU/PL 90/90
전체 정확도 97.8%, 미검출률 0.0%
```

| band | 1차 이상 | 2차 이상 | 학습 이상 |
|---|---|---|---|
| 0 | 0.98 | **2.90** | 3.49 |
| 1 | 3.17 | 2.05 | 1.22 |
| 2 | 1.52 | **4.27** | 2.93 |
| 3 | 2.25 | 3.42 | 3.00 |

band 0이 0.98에서 2.90으로 복귀해 학습 분포와 같은 형태가 됐다. 이상 판정 마진은 최소 117,
평균 120.9로 1차의 경계선 수준과 대비된다.

재고정이 검출률을 15%에서 100%로 되돌린 것은 확인했으나, 재고정 직전에 센서가 실제로
느슨했는지는 직접 확인하지 않았다. 따라서 원인은 "고정 상태 변화"로 기록하고 "나사 풀림"으로
단정하지 않는다. 재발 시 판별을 위해 측정 시작 전 정상 조건 feature 평균을 기준값과
비교하는 절차를 두는 것이 타당하다.

원본: `measurements/hw_validation_2026-09-14/hw_live_normal_run2.csv`, `measurements/hw_validation_2026-09-14/hw_live_fault_run2.csv`

## 6. 연속 이상 판정 latch 설계 검증

다음 단계에서 추가할 "3회 연속 class 1에서 fault latch" 설계를 2차 실측으로 검증했다.

```text
이상 구간   3번째 window에서 최초 3연속 성립 = 192 ms   (64 ms window 기준 예상치와 일치)
정상 구간   class 1이 2개 발생했으나 연속 발생 최대 1회, 3연속 성립 0건
```

단발 오검출이 존재하지만 연속되지 않으므로 3연속 조건은 정상 구간에서 걸리지 않는다.
임계값 3은 임의로 정한 값이 아니라 이 측정으로 뒷받침된다.

## 7. 남은 한계

- class 1은 `SW3`로 주입한 통제된 토크 리플이며 자연 발생 베어링 고장이 아니다.
- 정상 조건 오검출 2건은 1차 60 window에서는 0건, 2차 30 window에서는 2건으로 재현성이
  확정되지 않았다. 2건 중 1건은 arm 직후 첫 window였다.
- 데모 입력 `demo_samples[0]`의 오분류는 아직 수정하지 않았다.
- 본 측정은 단일 세션, 단일 고정 상태의 결과다. 다른 날 조건을 번갈아 수집하면 통계가 강화된다.

## 8. 재현 절차

```bash
# 1. 프로그램 (SW0 OFF, PSU OUTPUT OFF 상태에서)
xsdb artifacts/program_zybo.tcl

# 2. replay
python3 tools/monitor.py --port /dev/ttyUSB1 --command r --seconds 8 \
    --output measurements/hw_validation_2026-09-14/hw_replay_real_model_r.csv
python3 tools/monitor.py --port /dev/ttyUSB1 --command b --seconds 40 \
    --output measurements/hw_validation_2026-09-14/hw_replay_real_model_b100.csv

# 3. 센서 초기화 후 실시간 분류 (모터 구동 상태에서 SW3로 조건 전환)
python3 tools/monitor.py --port /dev/ttyUSB1 --command i --seconds 6 \
    --output measurements/hw_validation_2026-09-14/hw_sensor_init_real_model.csv
```

실시간 분류는 `s` 명령을 반복 전송하며 `RESULT` 줄을 수집한다. 종료 순서는
`SW3 OFF -> SW0 OFF -> PSU OUTPUT OFF`다.

## 9. PL fault latch 최종 실물 검증

3회 연속 이상 판정에서 모터 출력을 latch 차단하는 최종 RTL을 전체 게이트 후 Zybo에 올렸다.

| 파일 | SHA-256 |
|---|---|
| `artifacts/fourier.bit` | `cc48b9e7577f06f7978887f3a582018285058b828409ace5b291ec34eb9e9360` |
| `artifacts/fourier.xsa` | `9bb245d0958c871fa8820785b90f296f018fb4694bb7363e96b28e76fc31374b` |
| `artifacts/fourier_app.elf` | `428f788bfcf8710d217aeca11d023babd43255dec8d8a219b3e8aecad1c66e46` |

PSU 12.0 V, SW2 ON, SW1/SW3 OFF에서 정상 운전한 결과는 class 0 `3/3`, CPU-PL 일치
`3/3`, 모터 전류 약 0.13 A였다. SW3를 ON으로 전환한 뒤 실시간 판정열은
`0, 1, 1, 1, 0, 0`이었다. 전환 직후 class 0 다음에 class 1이 세 번 연속 입력되자 모터가
정지했고, 정지 뒤 두 window는 class 0으로 복귀했다.

차단 직후 관측값은 다음과 같다.

```text
AXI status 0x004 = 0x0000000A
fault latch bit3 = 1
PL error bit2    = 0
motor            = stopped
LD0 / LD1        = OFF / ON
PSU current      = 0.13 A -> 0.01 A
```

SW3를 OFF로 복구하고 SW0을 OFF로 내리자 LD1이 꺼지며 latch가 clear됐다. SW2만 유지한 채
SW0을 다시 ON으로 올리자 `LD0 ON / LD1 OFF`, 모터 재회전, 약 0.13 A로 복귀했다. 따라서
정상 유지, 실제 센서 이상 판정, PL latched stop, operator clear/rearm 전체 경로를 실물에서
확인했다.

원본은 `hw_live_normal_latch_motor_final.csv`, `hw_live_fault_latch_motor_final.csv`,
`hw_live_fault_latch_motor_final_cont.csv`이며 요약은
`artifacts/latch_hardware_summary_2026-09-14.json`에 있다. 판정 명령 사이에 사용자 확인 시간이
포함됐으므로 이 로그의 host timestamp로 192 ms 차단 시간을 주장하지 않는다. 192 ms는 64 ms
window 세 개의 알고리즘 기준값이며, 실제 출력 차단 시간의 계측은 오실로스코프 single-shot으로
별도 수행해야 한다.
