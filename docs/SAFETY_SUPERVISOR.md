# PL 안전 supervisor 확장

## 요구사항

| ID | 요구사항 | 검증 방법 |
|---|---|---|
| S1 | FPGA reset 뒤 SW0 OFF→ON 전에는 모터가 arm되지 않는다. | motor XSim, 실물 |
| S2 | 첫 class 1에서 warning을 표시한다. | supervisor XSim, AXI `0x04/0x4C` |
| S3 | 두 번째 연속 class 1에서 PWM을 최대 25%로 제한한다. | motor XSim, JD1 scope |
| S4 | 세 번째 연속 class 1에서 PWM/IN1을 latch 차단한다. | motor XSim, 실물 |
| S5 | trip 전 class 0은 warning과 derate를 복구한다. | supervisor XSim |
| S6 | latch는 정상 판정으로 풀리지 않고 SW0 OFF 또는 reset으로만 해제된다. | supervisor XSim, 실물 |
| S7 | arm 중 PS heartbeat가 500 ms 끊기면 PL이 독립적으로 latch 차단한다. | supervisor XSim, ARM 정지 실물 |
| S8 | 분류기와 watchdog fault cause를 구분해 읽을 수 있다. | AXI XSim, UART `f` |

## 상태와 duty

```text
consecutive class1 = 0 : NORMAL, switch duty
consecutive class1 = 1 : WARNING, switch duty
consecutive class1 = 2 : DERATED, min(requested duty, 25%)
consecutive class1 >=3 : TRIPPED, PWM=0 and IN1=0 until clear
heartbeat timeout      : TRIPPED, PWM=0 and IN1=0 until clear
```

Derate가 진동을 정상 범위로 낮춰 다음 판정이 class 0이 되면 trip하지 않고 NORMAL로 복구한다.
이 동작은 이상 원인이 출력 제한으로 제거됐다는 뜻이다. 제한 뒤에도 class 1이 계속되거나 PS가
응답하지 않으면 PL이 최종 정지한다.

## AXI register

| Offset | 접근 | 내용 |
|---|---|---|
| `0x04` | R | bit3 latch, bit4 warning, bit5 derated, bit6 watchdog cause |
| `0x48` | W | bit0 heartbeat pulse |
| `0x4C` | R | consecutive, warning, derated, cause, lifetime abnormal count |

`0x4C[11:10]` cause는 bit0 classifier trip, bit1 watchdog trip이다. abnormal count는 class 1이
입력될 때마다 포화 증가하며 SW0 clear 뒤에도 유지되고 FPGA reset에서만 초기화된다.

## 최종 실물 합격 기준

- 정상 운전에서 warning/derated/latch가 모두 0
- 첫 이상 판정 뒤 warning=1이고 모터가 계속 회전
- 두 번째 연속 이상 판정 뒤 AXI `0x4C` derated=1. duty가 실제로 25%인지는 JD1 오실로스코프
  측정 항목이며 레지스터 bit 확인만으로는 판정하지 않는다
- 세 번째 연속 이상 판정 뒤 latch=1, LD1 ON, 모터 정지. JD1이 LOW로 떨어지는 파형 자체는
  오실로스코프 측정 항목이다
- SW0 OFF clear 뒤 fault cause가 0이고 재arm 가능
- 별도 watchdog 시험에서 ARM 정지 구간 안에 cause=2와 모터 정지. RTL timeout 설계값은 500 ms이지만
  실제 물리 차단 지연은 JD1 오실로스코프 single-shot 전까지 확정하지 않는다
- 각 시험의 UART 원본, PSU 전류, artifact SHA-256 보관. scope 캡처는 아직 수행하지 않았다

## 2026-09-15 실물 결과

- 정상 센서 window 3/3 class 0, CPU/PL 3/3 일치, 모든 safety 상태 0
- 통제된 32 Hz 인위적 토크 리플(SW3) class `1,1,0`: warning 뒤 derated bit=1로 25% 제한 상태 진입,
  이어서 class 0으로 정상 자동 복구. 여기서 확인한 것은 AXI `0x04/0x4C`의 warning/derated bit 값이며,
  JD1의 실제 duty 백분율은 측정하지 않았다. 이 리플은 자연 발생 베어링 고장이 아니다
- 저장된 실제 이상 window의 결정론적 지속 주입 class `1,1,1`: warning, 제한, classifier latch 확인
- classifier latch 뒤 실모터 정지 및 전류 약 `0.13 A -> 0.01 A` 실측
- latch 유지, SW0 OFF clear, lifetime counter 보존, SW0 ON 재가동 확인
- heartbeat: 최초 정상 시험 1회에서 `cause=2`가 발생했다. 당시 class 0 3/3, abnormal_total 0이어서
  기계 고정이나 오분류 문제는 아니었으나 원인은 끝까지 규명하지 못했고 이후 어떤 재현 시도에서도
  다시 발생하지 않았다. acquisition 중 heartbeat를 보강한 firmware로 최종 정상 시험을 수행해
  watchdog을 0으로 유지했다. 즉 무조건 통과가 아니라 원인 불명 1회 발생 뒤 보강 후 성공이다
- Cortex-A9 #0을 1.010 s 정지한 동안 watchdog latch, `cause=2`, 실모터 정지 확인
- watchdog clear/rearm 뒤 모터 전류 약 0.13 A 복귀 확인
- RTL timeout은 50,000,000 cycle @ 100 MHz = 500 ms 설계값이다. 이번 시험이 증명하는 것은 차단이
  1.010 s halt 구간 안에서 일어났다는 사실뿐이며, 정확한 물리 차단 시간은 JD1 오실로스코프
  single-shot 실측 전까지 알 수 없다

원본과 artifact 해시는
[`artifacts/safety_supervisor_hardware_2026-09-15.md`](../artifacts/safety_supervisor_hardware_2026-09-15.md)에
정리했다. `x` 명령은 저장된 실제 이상 window 한 개를 PL FFT/NPU에 통과시키는 검증 명령이며,
자연 발생 고장을 뜻하지 않는다.
