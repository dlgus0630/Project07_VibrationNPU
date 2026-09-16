# 단일보드 통합 실물 시험 — 2026-09-16

Zybo Z7-20 한 보드에서 PI/encoder 폐루프 속도제어(신규 이식)와 FFT/NPU 진동분류 +
safety supervisor(기존)가 동시에 동작하는 것을 처음으로 실물 확인한 기록이다. "다음 작업
순서" 4번(단일보드 통합 실물 시험)의 첫 실측이며, 아래에 적은 대로 아직 완결(PASS 확정)은
아니다.

## 시험 구성

- Board: Zybo Z7-20, JTAG로 프로그램
- artifact: `artifacts/fourier.bit`(SHA-256
  `80c8eecc15f429ece95afbe8eefb97f93e195ee6106bb85a48a9667b4e862c1c`),
  `artifacts/fourier_app.elf`(SHA-256
  `5b7d81b0deefedaa711cbb9573d46c421678a246c72505cfa48dc1a98e0fdbdd`) — 둘 다 `HANDOFF.md`
  "gate와 artifact의 정확한 현재 상태" 절에 기록된 해시와 동일, 이번 시험 전에 이미 스테이징·
  해시 기록 완료된 것을 그대로 사용
- 센서 bring-up: `WHO_AM_I,0x70`, `SENSOR_MODEL,MPU-6500`, `SENSOR_READY,1` — 정상
- 스위치: SW0 arm, SW2 = 10 (speed_reference 고정값 2048)

## 시험 1: 폐루프 속도제어 확인 (PASS)

SW0로 arm한 상태에서 모터가 물리적으로 회전하는 약 6초 동안 JTAG `mrd -force`로 AXI
레지스터 0x50/0x54/0x58/0x5c/0x60
(motor_speed_reference/motor_measured_speed/motor_requested_duty/motor_pid_integral/
motor_armed_status)를 4회 읽었다.

| 회차 | speed_reference | measured_speed | requested_duty | pid_integral | armed |
|---:|---:|---:|---:|---:|---:|
| 1 | 2048 | 2040 | 2839 | 2832 | 1 |
| 2 | 2048 | 2043 | 2822 | 2818 | 1 |
| 3 | 2048 | 2045 | 2821 | 2816 | 1 |
| 4 | 2048 | 2043 | 2812 | 2808 | 1 |

- speed_reference는 스위치 설정값(2048)에서 4회 모두 불변
- measured_speed는 2040~2045로 reference 대비 약 0.4% 이내에서 추종
- armed는 4회 모두 1
- requested_duty는 2808~2839로 완전히 고정되지는 않고 소폭 변동

이식된 `encoder_speed_hybrid.v` + `pid_fixed.v`가 실제 하드웨어에서 폐루프를 닫는다는 것을
처음으로 확인했다(이전까지는 XSim에서만 검증됨). 이 시험은 PASS로 기록한다.

## 시험 2: 폐루프 속도제어 중 진동분류 실행 — 주기적 패턴 발견

모터를 폐루프로 계속 회전시킨 상태(SW3 토크 리플 등 인위적 조작 없음, 물리적으로 아무것도
바꾸지 않음)에서 firmware의 `s`(sample+infer) UART 명령을 총 18회 실행했고, 대부분의 실행
뒤 `f`(safety status) 명령으로 상태를 확인했다.

RESULT 라인 형식:
`RESULT,source,class,cpu_us,pl_cycles,npu_cycles,e2e_us,match,f0,f1,f2,f3,h0,h1,h2,h3,o0,o1`
(f0-f3 = 4-band INT8 feature, h0-h3 = hidden layer, o0/o1 = NPU 최종 출력 logit, 2-class)

SAFETY 라인 형식:
`SAFETY,warning,W,derated,D,latched,L,watchdog,WD,cause,C,consecutive,N,abnormal_total,T`

### 원본 데이터 (18회, 순서대로, 누락·반올림 없음)

| run | class | cpu_us | pl_cycles | npu_cycles | e2e_us | match | f0 | f1 | f2 | f3 | h0 | h1 | h2 | h3 | o0 | o1 | safety (해당 시 기록) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 1 | 847 | 833 | 18 | 26 | 1 | 5 | 2 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | warning=1,derated=0,latched=0,watchdog=0,cause=0,consecutive=1,abnormal_total=1 |
| 2 | 1 | 849 | 833 | 18 | 26 | 1 | 4 | 1 | 3 | 9 | 0 | 0 | 0 | 0 | -61 | 60 | (미폴링) |
| 3 | 0 | 849 | 833 | 18 | 26 | 1 | 2 | 1 | 1 | 2 | 10 | 10 | 13 | 13 | 19 | -22 | warning=0,derated=0,latched=0,watchdog=0,cause=0,consecutive=0,abnormal_total=2 |
| 4 | 1 | 849 | 833 | 18 | 26 | 1 | 4 | 1 | 4 | 7 | 0 | 0 | 0 | 0 | -61 | 60 | warning=1,derated=0,consecutive=1,abnormal_total=3 |
| 5 | 1 | 849 | 833 | 18 | 27 | 1 | 4 | 3 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | warning=1,derated=1,consecutive=2,abnormal_total=4 |
| 6 | 0 | 849 | 833 | 18 | 26 | 1 | 1 | 1 | 1 | 1 | 16 | 15 | 21 | 20 | 65 | -68 | warning=0,derated=0,consecutive=0,abnormal_total=4 |
| 7 | 1 | 848 | 833 | 18 | 26 | 1 | 3 | 1 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | consecutive=1,abnormal_total=5 |
| 8 | 1 | 849 | 833 | 18 | 27 | 1 | 3 | 2 | 1 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | derated=1,consecutive=2,abnormal_total=6 |
| 9 | 0 | 848 | 833 | 18 | 26 | 1 | 0 | 1 | 1 | 2 | 16 | 16 | 22 | 20 | 68 | -72 | consecutive=0,abnormal_total=6 |
| 10 | 1 | 849 | 833 | 18 | 27 | 1 | 4 | 2 | 3 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | consecutive=1,abnormal_total=7 |
| 11 | 1 | 849 | 833 | 18 | 27 | 1 | 4 | 1 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | derated=1,consecutive=2,abnormal_total=8 |
| 12 | 0 | 848 | 833 | 18 | 26 | 1 | 0 | 1 | 1 | 1 | 19 | 18 | 25 | 24 | 89 | -93 | consecutive=0,abnormal_total=8 |
| 13 | 1 | 849 | 833 | 18 | 26 | 1 | 4 | 1 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | consecutive=1,abnormal_total=9 |
| 14 | 1 | 849 | 833 | 18 | 27 | 1 | 5 | 2 | 2 | 8 | 0 | 0 | 0 | 0 | -61 | 60 | derated=1,consecutive=2,abnormal_total=10 |
| 15 | 0 | 849 | 833 | 18 | 26 | 1 | 0 | 1 | 1 | 1 | 19 | 18 | 25 | 24 | 89 | -93 | consecutive=0,abnormal_total=10 |
| 16 | 1 | 849 | 833 | 18 | 27 | 1 | 4 | 2 | 2 | 9 | 0 | 0 | 0 | 0 | -61 | 60 | consecutive=1,abnormal_total=11 |
| 17 | 1 | 849 | 833 | 18 | 27 | 1 | 4 | 2 | 3 | 10 | 0 | 0 | 0 | 0 | -61 | 60 | derated=1,consecutive=2,abnormal_total=12 |
| 18 | 0 | 849 | 833 | 18 | 27 | 1 | 0 | 1 | 1 | 1 | 19 | 18 | 25 | 24 | 89 | -93 | consecutive=0,abnormal_total=12 |

모든 run에서 `match=1`(CPU/PL 일치), `pl_cycles=833`, `npu_cycles=18` 고정.

### 핵심 관찰 (실측 확인, 추정 아님)

- class 순서가 18회 전부에서 `1,1,0`이 정확히 6회 반복되는 패턴이다. 예외 없이 정확히
  이 패턴이며 경계선에서 흔들리는 노이즈성 결과가 아니다.
- 12/18 = 66.7%가 abnormal(class 1)로 판정됨.
- class 1일 때 최종 NPU 출력 logit `o0=-61, o1=60`이 18회 중 12회 전부 비트 단위로 완전히
  동일하다.
- class 0일 때는 `o0 ∈ {19, 65, 68, 89}`, `o1 ∈ {-22, -68, -72, -93}`로 class 1 쪽보다는
  퍼져 있지만 좁은 범위에 몰려 있다.
- safety_supervisor는 설계된 RTL 로직대로 정확히 동작했다: 2회 연속 abnormal마다 예외 없이
  `derated=1`이 설정됐고, 그 직후 정상 판정이 나오면 즉시 `warning`/`derated`가 0으로
  돌아가고 `consecutive`가 0으로 리셋됐다. `1,1,0` 패턴 특성상 연속 abnormal이 항상 2에서
  끊기므로 3연속(latch) 조건은 이번 시험에서 한 번도 발생하지 않았다.
- safety supervisor의 실시간 반응 로직(2연속→derate, 정상 복귀 시 즉시 clear)은 통합 시스템
  실물에서 PASS로 확정한다.

## 두 가지 미검증 가설 (결론 아님)

이 주기 패턴이 왜 발생하는지는 아직 규명되지 않았다. 다음 두 가설 모두 테스트하지 않았다.

1. **PI 폐루프 duty 변동에 의한 실제 진동 변화 가설**: 시험 1에서 requested_duty가
   2808~2839로 완전히 고정되지 않고 변동했다. 이 변동이 실제로 주기적인 기계적/전기적
   진동을 유발했고, 그 진동 특성이 NPU 학습 당시(스위치로 고정한 open-loop duty, PI 제어
   상태에서는 한 번도 학습하지 않음)와 달라서 발생했을 가능성.
2. **PI 제어 tick과 샘플링 윈도 간 위상 앨리어싱 가설**: PI의 10 ms 제어 tick과 진동
   샘플링 윈도 사이에 동기화/앨리어싱이 생겨, 실제 진동 내용과 무관한 샘플링 위상 인공물이
   주기적으로 나타났을 가능성.

두 가설을 구분하려면 오실로스코프로 PI duty 전환 시점과 진동 샘플링 윈도 타이밍을 상호
대조하거나, 더 미세한 위상 추적과 함께 더 많은 샘플을 로깅해야 한다. 이 근본원인 조사는
사용자가 2026-09-16에 직접 보류하기로 결정했으며, 이번 세션에서는 수행하지 않았다.

## 상태 요약

- 폐루프 PI/encoder 속도제어: 실물 PASS(시험 1)
- safety supervisor 반응 로직(통합 시스템 상): 실물 PASS(시험 2 중 관찰)
- 진동분류 결과: PI 폐루프 구동 중 정확한 주기 패턴(`1,1,0` 반복)을 보였고, 원인 미규명
  상태로 open question 기록. "단일보드 통합 실물 시험" 항목을 완결(done)로 표시하지 않는다.

## 텔레메트리 실제 전송 주기 불일치 (최초 기록 — 아래 "근본원인 규명·수정 완료" 절로 대체됨)

같은 세션에서 "다음 작업 순서" 5번(12→9→12 V 외란 시험) 시도 중 발견됐다. 아래 "외란 시험
시도" 절보다 먼저 적는 이유는, 그 절의 시간축 보정이 이 발견에 의존하기 때문이다.

**이 절은 당시 시점(근본원인 미규명)의 기록이다. 근본원인은 같은 세션 안에서 이후 규명·수정
완료됐다 — 최신 상태는 바로 아래 "텔레메트리 주기 버그 — 근본원인 규명·수정 완료" 절을
참고한다. 이 절은 조사 경과 기록으로 남겨둔다.**

- 설계값: `fourier/firmware/main.c`의 `TELEMETRY_US 10000`은 100 Hz 텔레메트리 스트리밍을
  의도한다. UART 명령 대기 중이 아닌 idle 경로는 `usleep(1000)`(명목 1 ms)을 쓰므로 100 Hz는
  이론상 쉽게 달성돼야 한다.
- 실측값: `Project07_MotorControl/tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 20`
  실행 결과 20 실제 초 동안 정확히 **499 frame**, 즉 **≈24.95 Hz** — 설계값 100 Hz의 약 1/4에
  그쳤다.
- capture tool은 dropped frame 0건, checksum error 0건을 보고했다. 수신된 frame의 sequence
  number는 깨끗하게 증가한다. 이는 통신/캡처 문제가 아니라 firmware 자체가 실제로 ~25 Hz로만
  frame을 생성하고 있음을 뜻한다.
- (당시) 근본원인은 규명되지 않았다. 미검증 후보 두 가지: (a) 이 플랫폼/BSP 설정에서
  XilTimer의 `usleep()`이 요청값보다 실제로 약 4배 길게 대기할 가능성, (b) 아직 특정하지
  못한 다른 loop-iteration 비용. 사용자가 이번 세션에서 조사를 보류하기로 직접 결정했으며,
  더 파고들지 않았다. **→ 이후 실제 원인은 (a), (b) 둘 다 아니었다. 아래 절 참고.**
- 실무적 영향(당시 기록): `capture_telemetry.py`의 CSV `time_s` 컬럼은
  `sample_number / 100.0`으로 100 Hz를 가정해 고정 계산되므로, Zybo 캡처에서는 **틀린 값**이다
  — 실제 경과 시간을 약 4배 과소평가한다. 캡처 도구의 `EVENT 1 NOW`/`EVENT 2 NOW` 벽시계
  표식은 capture PC의 `time.monotonic()` 기반이라 이 문제의 영향을 받지 않는다. 영향을 받는
  것은 CSV의 `time_s` 컬럼과, 이를 그대로 사용해 계산하는 값(초 단위 rise time, settling
  time)뿐이다 — ~25 Hz 실측치로 보정하지 않으면 이런 값들은 신뢰할 수 없다.

## 텔레메트리 주기 버그 — 근본원인 규명·수정 완료 (같은 세션 후속)

위 절 작성 이후 같은 세션 안에서 근본원인을 실제로 찾아 수정했다. 추측이 아니라 Vitis가
생성한 실제 BSP 헤더를 전처리기로 직접 전개해 확인했다.

- **근본원인**: Xilinx가 자동생성하는 `xtimer_config.h`의 BSP 매크로가
  `#define XSLEEPTIMER_FREQ XPAR_CPU_CORE_CLOCK_FREQ_HZ/2`로 정의돼 있다(괄호 누락).
  `fourier/firmware/main.c`의 `micros()` 함수는 `t*1000000U/COUNTS_PER_SECOND`를 계산하는데,
  이 매크로가 그대로 치환되면 `(t*1000000U/666666687)/2`가 된다 — 좌에서 우로 평가되는 C
  연산자 우선순위 때문에 결과가 `실제 마이크로초 / 4`가 된다(true_microseconds/4). 이 때문에
  10 ms마다 텔레메트리를 보내야 하는 조건이 실제로는 40 ms마다만 참이 됐다 — 설계값 100 Hz
  대신 25 Hz가 나온 이유와 정확히 일치한다.
- 이 버그는 이 firmware가 출력하는 모든 ARM 측 latency 수치(`RESULT` 라인의 `cpu_us`,
  `e2e_us`/elapsed)에도 똑같이 적용된다 — 전부 실제값의 약 1/4로 과소 표시된다. `plcycles`는
  영향받지 않는다 — PL 하드웨어 카운터 값이지 `micros()`를 거치지 않는다.
- 배제한 원인들: 클럭 설정(CPU 666.67 MHz, Global Timer prescaler)은 확인 결과 정확했다 —
  이번 버그는 클럭 설정 오류가 아니라 자동생성 헤더의 순수 C 연산자 우선순위/괄호 결함이다.
  `usleep()` 구현(별도 함수, 이 매크로를 거치지 않음)의 버그도 아니다. firmware의
  D-cache-disabled 모드와도 무관하다 — Global Timer 레지스터 읽기는 Device/strongly-ordered
  메모리 영역이라 원래 캐시되지 않는다.
- **수정**: 사용자 작성 파일 `fourier/firmware/main.c` 1줄만 변경했다(자동생성 BSP 파일은
  건드리지 않았으므로 BSP 재생성 후에도 유지되고, "생성된 코드 직접 수정 금지" 원칙과도
  무관하다).
  ```c
  // 수정 전:
  static uint32_t micros(uint64_t t){return (uint32_t)(t*1000000U/COUNTS_PER_SECOND);}
  // 수정 후:
  static uint32_t micros(uint64_t t){return (uint32_t)(t*1000000U/(COUNTS_PER_SECOND));}
  ```
- Vitis에서 기존 platform 기준으로 ELF만 재빌드했다(`app.build()`, XSA/bitstream 변경 없음 —
  순수 firmware 수정이므로). JTAG로 보드에 재프로그램하는 도중 디버거가 "Cannot halt
  processor core, timeout"을 보고해 `rst -srst` + 전체 bitstream 재플래시 + `ps7_init` 복구
  절차를 거쳤다 — 이 프로젝트에서 이전에도 겪은 알려진 복구 가능 패턴이며 새로운 문제는
  아니다.
- **검증(수정 후 실측)**: `capture_telemetry.py --duration 8` 실행 결과 8.0초 동안 796 frame
  = **99.5 Hz**(수정 전 24.95 Hz 대비). 예측한 4배 보정(24.95 × 4 ≈ 99.8)과 측정 잡음 범위
  내에서 정확히 일치한다. **수정 확인됨(CONFIRMED FIXED)**.
- **부수 사항(중요, 아직 재측정 안 됨)**: 이 버그는 과거 모든 세션에서 이 firmware가
  `RESULT` 라인으로 출력한 `cpu_us`/`e2e_us` 값에도 똑같이 적용됐을 가능성이 매우 높다 —
  예를 들어 `HANDOFF.md`에 이미 기록된 "ARM 기준 실행시간: 847 us",
  "end-to-end 평균 latency: 26.38 us" 같은 값들이 실제로는 약 4배 더 컸을 가능성이 크다.
  **이 값들은 이번 세션에서 재측정하지 않았다** — 재측정하려면 `b`/`s` 벤치마크 명령을 다시
  실행하고 새 수치와 비교해야 한다. 과거 `HANDOFF.md` 수치는 당시 버그 있는 코드가 실제로
  출력한 값이므로 삭제·수정하지 않는다 — 다만 약 4배 낙관적일 수 있다는 경고를 명확히
  남긴다(HANDOFF.md 쪽에도 별도 표기).

## 외란 시험 시도 (12V→~9V→12V, 비정밀) — 최초 기록, 아래 절로 대체됨

**이 절은 당시(수동 타이밍, 정밀 재시험 이전) 시점의 기록이다. 같은 세션 안에서 이후 정밀한
재시험 두 회차를 완료했고, "다음 작업 순서" 5번은 그 결과로 충족된 것으로 본다. 최신
결론은 바로 아래 "외란 시험 — 정밀 재시험 완료(Run 1, Run 2)" 절을 참고한다. 이 절은 조사
경과와 방법론 시행착오 기록으로 남겨둔다 — 아래 재시험 방법론(사전 타이밍 대신 "준비되면
바로" 방식)에 도달하기까지의 과정을 보여준다.

"다음 작업 순서" 5번(12→9→12 V 외란 시험)을 시도했다.
`Project07_MotorControl/docs/TELEMETRY_EXPERIMENT.md`의 "전원 외란 복원" 절차를 이 저장소에
맞게 준용했다.

### 시험 구성

- PSU: 12.0 V, 0.5 A current limit
- 스위치: SW0 + SW2 arm (speed_reference=2048, capture 도구 기본 CPR=988.427 기준 목표
  약 54.63 RPM)
- UART `t` 명령으로 텔레메트리 스트리밍 활성화
- 캡처: `Project07_MotorControl/tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 20
  --mark-after 5 --second-mark-after 10
  --output artifacts/experiments/disturbance_2026-09-16.csv` (파일은 이미 저장소에 있음,
  재생성하지 않음)
- 절차: 어시스턴트 채팅 메시지가 뜬 시점부터 사용자가 마음속으로 초를 세어, 약 5초 뒤 PSU
  전압을 낮추고 약 5초 더 뒤(총 10초)에 원상 복구 — 동기화된 트리거가 아니라 수동 카운트

### 사용자가 확인한 두 가지 비정밀 요소

1. 타이밍이 근사치였다 — 정확히 5초/10초 지점이 아니었다.
2. PSU 다이얼을 내릴 때 과도하게 돌려서 전압이 순간 약 7 V까지 떨어졌다가 다시 약 9 V로
   보정됐다. 즉 12 V→9 V 단일 계단이 아니라 더 크게 떨어졌다 올라온 형태였다.

### 관측 데이터 (보정된 시간축)

위 "텔레메트리 실제 전송 주기 불일치" 절에 따라 CSV의 `time_s` 컬럼은 100 Hz 가정으로 틀려
있다. 아래는 `실제 시간(초) ≈ sample index / 24.95`로 보정한 매핑이며, CSV 자체의 `time_s`
컬럼 값이 아니다.

| sample index | 보정 시각 | duty | measured RPM | 비고 |
|---|---|---|---|---|
| 0–100 | ~0–4 s | ~66.1% | ~54.3–54.5 | 12 V 정상상태, reference 54.63 RPM |
| 120 | ~4.8 s | 80.83% | 48.50 | 외란 응답 시작 |
| 140 | ~5.6 s | 99.90%(근접 포화) | 49.78 | 회복 중, duty 포화 |
| 160 | ~6.4 s | 99.95% | 53.99 | |
| 180 | ~7.2 s | 94.36% | 56.45 | reference 소폭 overshoot |
| 200–420 | ~8–16.8 s | ~82–88% | 54.3–56.4 | reference 근처 장시간 유지(의도한 9V 유지 ~5초보다 김 — 사용자의 복구 조작이 의도한 10초 지점보다 늦었던 것과 일치) |
| 440–480 | ~17.6–19.2 s | 81.9%→70.8% | — | 원래 ~66% baseline 방향으로 회귀 중, 20초 캡처 종료 시점까지 duty/measured가 원래 66%/54.4 RPM baseline으로 완전히 복귀하지는 못함 |

이 시험 동안 안전 warning/derate/latch는 한 번도 트리거되지 않았다(이 시험은 텔레메트리
스트리밍이며 진동분류 classifier 경로와는 무관 — classifier는 이번 시험에서 동작하지 않았다).

### 결론 (당시 기록 — 아래 절로 대체됨)

사용자가 2026-09-16에 직접 결정: 이 결과는 통합 폐루프 시스템이 실제 전원 외란에 반응하고
회복한다는 **정성적·비공식 확인**으로만 취급한다 — 큰 음의 전압 외란에서 duty가 거의 100%까지
포화됐다가 baseline 쪽으로 서서히 풀리는 모습은 PI+anti-windup 동작 방향이 옳다는 것을 보여
준다. 하지만 이것은 "다음 작업 순서" 5번이 요구하는, Basys3의 `ANALYZE_DISTURBANCE` 기반
결과와 같은 수준의 엄밀한(정밀한 전압 계단, 알려진 타이밍) **정량적 결과가 아니다**. 정밀한
재시험은 이번 세션에서 하지 않고 향후 세션으로 미뤘다.

**→ 이 결론은 같은 세션 안에서 이후 진행한 정밀 재시험으로 대체됐다. 아래 절 참고.**

## 외란 시험 — 정밀 재시험 완료(Run 1, Run 2) (같은 세션 후속, 최신·유효 결과)

텔레메트리 주기 버그 수정 이후, `Project07_MotorControl/tools/capture_telemetry.py`로
`/dev/ttyUSB1`을 대상으로 여러 차례 재시험을 시도했다.

### 중간 시도들 (수정 후에도 여전히 부정확했던 시도, 참고용으로만 보존)

- `artifacts/experiments/disturbance_2026-09-16_v2.csv`: 전압을 너무 천천히 돌려 계단이
  아니라 약 10초짜리 완만한 ramp가 됐다 — artifact로는 보존하되 정량적 근거로 쓰지 않는다.
- `artifacts/experiments/disturbance_2026-09-16_v3.csv`: 사전 타이밍 표식이 크게 어긋나
  t=40s 부근에 약 5초짜리 짧은 blip 하나만 잡혔다 — 사용 불가.
- `artifacts/experiments/drop_only_2026-09-16.csv`: 사용자가 준비되기 전에 캡처가 시작돼
  대부분 미사용.

이 반복 실패의 공통 원인은 사전 타이밍 방식(어시스턴트의 "지금" 신호와 사용자의 실제 PSU
조작 사이 채팅 전달 지연) 자체였다.

### 확정된 방법론

사전 타이밍 표식 대신, 어시스턴트가 긴 캡처(`--duration 60`)를 먼저 시작해두고 사용자에게
"준비되는 대로" 전압을 바꾸라고만 안내한 뒤, 캡처가 끝난 후 (텔레메트리 버그 수정으로 이제
정확해진) `time_s` 컬럼을 직접 조사해 실제 전환 시점을 찾아내는 방식으로 전환했다. 이
방식으로 12V→9V→12V 전 구간이 양쪽 모두 안정화까지 포함해 깨끗하게 잡힌 완전한 60초 캡처를
두 회차 얻었다.

- `artifacts/experiments/drop_only_2026-09-16_v2.csv` — 단독 drop 전환만 깨끗하게 잡힌 회차
  (참고용, 아래 v4/v5에 포함된 정보와 별개로 보존)
- `artifacts/experiments/restore_only_2026-09-16.csv` — 단독 restore 전환만 깨끗하게 잡힌
  회차 (참고용, 아래 v4/v5에 포함된 정보와 별개로 보존)

### Run 1 — `artifacts/experiments/disturbance_2026-09-16_v4_final.csv` (60초, 양쪽 전환+정착 완전 포함)

```
t=0-4s:      12V 정상상태: duty ~64.2%, measured ~54.4 RPM (reference 54.63 RPM)
t=4.5-5s:    12V→9V drop: duty 85.8%로 급상승(peak 86.6% at t=5.5s), measured 46.66 RPM까지
             하강(최소값, reference 대비 -14.6%)
t=5.5-6s:    measured가 55.73 RPM까지 순간 overshoot 후 회복
t=6-16.5s:   9V 정상상태, 완전 정착: duty ~81-82%, measured ~54.4-54.6 RPM (12초간 깨끗한 dwell)
t=17-17.5s:  9V→12V restore: duty 81.3%→65.6%로 하강, measured 59.01 RPM까지 overshoot
             (reference 대비 +8.0%)
t=18-18.5s:  measured 54.87 RPM으로 빠르게 정착
t=18.5-59.5s: 12V 정상상태, 완전 정착: duty ~63.8-64.2%, measured ~54.2-54.6 RPM
             (41초간 깨끗한 dwell, drift 없음)
```

### Run 2 — `artifacts/experiments/disturbance_2026-09-16_v5_repeat.csv` (60초, 동일 방법론 반복 시행)

```
t=0-10s:     12V 정상상태: duty ~63.7%, measured ~54.4 RPM
t=11-12s:    12V→9V drop: duty가 t=12s까지 81.7%로 상승, measured는 순간 하강(1초 해상도에서
             관측된 최소값은 t=11s에서 53.94 RPM — 실제 10ms 단위 최소값은 더 깊을 가능성
             있으나 개별 재추출하지 않음) 후 t=12s에 54.50 RPM으로 회복
t=12-17s:    9V 정상상태, 정착: duty ~81.5-81.9%, measured ~54.3-54.7 RPM (5초간 깨끗한 dwell)
t=18-19s:    9V→12V restore: duty가 77.78%(t=18s)에서 62.13%(t=19s)로 하강, measured는
             t=18s에 56.93 RPM까지 overshoot(reference 대비 +4.2%)
t=20-59s:    12V 정상상태, 완전 정착: duty ~63.8-64.1%, measured ~54.2-54.6 RPM
             (39초간 깨끗한 dwell, drift 없음)
```

### 재현성 평가

Run 1과 Run 2는 동일한 정성·정량 패턴을 보인다 — drop 시 하강 후 회복, restore 시 overshoot
후 회복, 양방향 모두 약 1.5-2초 내 recovery, 전후 안정적 dwell, safety trip 없음. 두 회차
모두 텔레메트리 버그 수정 이후 캡처라 시간축이 정확하다 — 독립된 두 시행에서 일관된 결과가
나왔으므로 재현성 근거로 인정한다.

recovery time은 양방향 모두 외란 시작부터 reference 대비 약 0.5% 이내로 정착할 때까지 약
1.5-2초다. 어느 시점에서도 safety warning/derate/latch가 트리거되지 않았다(이 시험은
진동/classifier 경로를 건드리지 않는다). oscillation, instability는 관측되지 않았고, drop
구간에서 duty가 100% 근접까지 일시적으로 포화되는 것 외에 windup 관련 이상 거동은 없었다.

### 결론(최신, 유효)

"다음 작업 순서" 5번("12 -> 9 -> 12 V 외란 시험을 Zybo 통합판에서 수행")의 원래 의도를
실물·정량·재현 가능한 데이터로 충족한다 — encoder+PI+safety limiter가 FFT/NPU classifier
경로와 같은 PL에서 함께 동작하는 완전 통합 시스템 상에서 얻은 결과다. Basys3 기준선이 쓰는
`ANALYZE_DISTURBANCE` 기반 MATLAB 후처리는 오늘 실행하지 않았다 — 위 수치는 원본 CSV를
직접 조사해 추출한 값이며, MotorControl 문서가 쓰는 정식 MATLAB 파이프라인을 거치지 않았다.
이 차이를 명확히 남긴다 — 향후 세션에서 같은 형식의 정식 rise-time/overshoot/settling-time
지표가 필요하면 이 CSV들에 `ANALYZE_DISTURBANCE`를 돌릴 수 있지만, 위 원본 데이터만으로도
요구된 거동은 이미 명확히 입증됐다.

## Watchdog 지연 미스터리 — 근본원인 규명 완료 (RTL은 정상이었음)

2026-09-15 세션은 JTAG-halt 이분탐색(외부 증상만 관찰 — 모터 전류·LED, 카운터 레지스터
직접 접근 없음)으로 watchdog trip이 **1489~1600 ms**에서 발생한다고 기록했다(RTL 설계값
500 ms의 약 3배, 원인 미규명, 다음 단계로 ILA 필요 명시 — `artifacts/safety_supervisor_hardware_2026-09-15.md`
"Correction" 절, `HANDOFF.md`의 "2026-09-15 오실로스코프·watchdog 후속 실측" 절). 같은 세션
안에서(2026-09-16) 이 근본원인을 실제로 찾았다. 결론을 먼저 적는다.

**watchdog_count RTL 카운터는 처음부터 정상이었다.** 실측 clock rate가 설계값 100 MHz와
0.06% 이내로 일치하고, trip 시점도 설계값 500 ms와 JTAG 폴링 해상도(~50 ms) 이내로 일치한다.
카운터 자체는 한 번도 버그였던 적이 없다. 2026-09-15의 "1.489~1.6초, 약 3배" 관측은 그
세션의 측정 방법론이 만든 인공물이었다 — RTL 결함이 아니다. "다음 작업 순서" 1번은 이제
**해결(RESOLVED)**이며, watchdog 로직 자체에 대한 RTL 수정은 필요하지 않았다.

### 1. AXI로 카운터를 직접 노출 (ILA 대신 더 간단한 방법)

ILA 대신 카운터 값을 AXI 레지스터로 직접 읽을 수 있게 배선했다.

- `safety_supervisor.v`: `watchdog_count_out` 출력 포트 추가
- `fourier_motor_control.v`: `motor_watchdog_count`로 상위 전달
- `axi_vibration_top.v`: 새 read-only 레지스터 `0x43c00064` 추가
- `vivado/create_fourier.tcl`: 넷 배선 갱신
- `fourier/tb/tb_axi.v`, `fourier/tb/tb_fourier_motor.v`: tie-off 갱신
- XSim 9/9 PASS, 동작 변경 없음(순수 관측성 추가)

### 2. 이 변경이 타이밍 closure를 깨뜨림 — 두 건의 파이프라이닝 수정

새 AXI 포트가 이미 여유가 거의 없던 기존 critical path 두 개(하루 종일 여러 빌드에서
+0.009~+0.054 ns 수준으로 버텨온 경로)를 실제 위반으로 밀어넣었다.

- **`fourier/rtl/pid_fixed.v`**: anti-windup 64-bit adder+clamp을 한 조합 사이클에 계산하던
  경로(`i_candidate = i64 + ((3932*e64)>>>16)`, ±4096 비교, `candidate` 레지스터 — 15 logic
  level, 13xCARRY4)를 `PRODUCTS` -> 신규 `PRODUCTS_HI` 두 state로 분리해 캐리 분할을 정확히
  한 클록 파이프라인했다. bit-exact 결과, +10 ns latency만 추가. XSim으로 수정 전후 완료
  타임스탬프가 피코초 단위까지 동일함을 확인: `tb_speed_pi_integration` 123750 ns,
  `tb_fourier_motor` 5158390 ns. `Project07_MotorControl` 기준선과의 divergence 사유를
  코드에 주석으로 남겼다.
- **`fourier/rtl/encoder_speed_hybrid.v`**: `pid_fixed.v` 수정 후 이전에는 더 나쁜 위반에
  가려져 있던 두 번째 near-critical path가 드러났다 — DSP48E1 multiply
  (`bounded_count*RECIP_Q12` -> `window_product`)가 threshold 비교와 clamp mux를 조합으로
  거쳐 한 클록(`sample_tick`)에 `speed_reg`로 들어가는 경로. DSP 출력과 비교/mux 사이에
  `window_product_reg` 파이프라인 레지스터를 추가해 같은 방식으로 수정했다. bit-exact,
  latency만 추가, XSim 검증. 마찬가지로 코드에 divergence 사유를 주석으로 남겼다.
- `unsigned_divider.v`는 조사했으나 무관함을 확인했다 — `encoder_speed_hybrid.v`의 저속
  분기에서만 쓰이는 별개 모듈이며 손대지 않았다.
- 두 RTL 파일이 원래 하드웨어 검증된 `Project07_MotorControl`(Basys3) 기준선의
  byte-identical 복사본이었기 때문에, 두 수정 모두 세션 중 사용자의 별도 승인을 받고
  진행했다.
- 두 수정이 모두 갖춰지기 전에는 여러 Vivado 전략(default, AggressiveExplore, retiming,
  ExtraTimingOpt 조합 — `reports/vivado_watchdog_build*.log`에 시도 1~10으로 기록)을
  일관성 없이 시도했다. **두 RTL 수정이 모두 디스크에 반영된 뒤에는, 이 프로젝트가 하루
  종일 써온 단순한 방법 — 기본 route 후 `phys_opt_design -directive AggressiveExplore` +
  `route_design -directive AggressiveExplore`** — 로 즉시 closure됐다. 여러 전략을
  시도했던 것은 돌이켜보면 불필요했다 — **교훈: Vivado 전략을 과도하게 바꾸기 전에 실제
  RTL 병목부터 고친다.**
- 최종 post-route: **WNS +0.138 ns, WHS +0.017 ns, DRC Error 0**

### 3. Vitis 재빌드·보드 재프로그램

- `platform.update_hw()` + `platform.build()` + `app.build()`로 새 XSA 기준 ELF+FSBL 재빌드
- xsdb JTAG로 재프로그램(`fpga -file`, `ps7_init` 복구 시퀀스 — 이 프로젝트에서 이미 익숙한
  패턴)
- 부팅 배너 정상 확인: `WHO_AM_I,0x70`, `SENSOR_READY,1`

### 4. 진단 방법과 실측 결과

방법: SW0 arm 상태(모터는 물리적으로 구동하지 않음 — PSU는 의도적으로 계속 OFF 유지, 이
진단은 digital `armed` 상태가 1이기만 하면 되고 실제 모터 회전은 필요 없어 이렇게 하는 것이
안전하고 올바름을 확인함), JTAG로 ARM 코어를 정지(`stop`, heartbeat 중단)한 뒤 AXI 레지스터
`0x43c00064`(신규 watchdog_count)와 `0x43c00004`(status, bit6=`motor_watchdog_fault`)를
약 50~60 ms 간격으로 `mrd -force -value`로 폴링하며 `clock milliseconds`로 각 읽기를
타임스탬프했다. halt와 poll을 하나의 끊김 없는 Tcl 세션 안에서 수행하는 것이 핵심이었다 —
초기 한 시도는 halt와 poll 사이에 xsdb를 재연결해 JTAG 재연결 오버헤드로 17초를 낭비했고
그 결과 이전 시행에서 이미 latch된 상태를 읽어버렸다. 각 trip 시행 사이에는 실제 물리적
SW0 OFF->ON 사이클(`clear`는 `!sw_sync[0]`에 배선됨)로 latch를 clear한 뒤 다음 시행을
진행했다.

**Run 1** (`dt` = halt 지시 이후 경과 밀리초):

```
dt=6ms    count=2,611,336
dt=61ms   count=8,085,243
dt=114ms  count=13,447,808
dt=168ms  count=18,864,044
dt=222ms  count=24,234,790
dt=276ms  count=30,454,332
dt=340ms  count=36,004,503
dt=396ms  count=41,629,510
dt=452ms  count=47,216,987
dt=508ms  count=49,999,999 -> FAULT LATCHED (status=72=0x48, watchdog_fault + fault_latched 비트 설정)
```

dt=6ms ~ dt=452ms 구간 slope: (47,216,987-2,611,336) / (452-6)ms = 44,605,651 / 0.446 s =
**100,013,793 counts/sec**(기대값 100,000,000/sec 대비 0.014% 오차 — 측정 잡음 범위 내).
Trip 시점: 508 ms(설계값 500 ms 대비 +1.6% — ~50 ms JTAG 폴링 해상도로 완전히 설명됨, 즉
실제 trip은 [458 ms, 508 ms] 구간 어딘가).

**Run 2** (재현성 확인을 위해 반복, 실제 SW0 OFF->ON latch clear 후):

```
dt=6ms    count=10,401,430
dt=60ms   count=15,845,789
dt=114ms  count=21,199,064
dt=167ms  count=26,539,547
dt=220ms  count=31,861,027
dt=274ms  count=37,238,701
dt=339ms  count=43,740,711
dt=396ms  count=49,426,089
dt=452ms  count=49,999,999 -> FAULT LATCHED
```

dt=6ms ~ dt=396ms 구간 slope: (49,426,089-10,401,430) / (396-6)ms = 39,024,659 / 0.390 s =
**100,063,228 counts/sec**(기대값 대비 0.06% 오차 — 역시 측정 잡음 범위 내). Trip 시점:
452 ms(같은 JTAG 해상도 여유 안에서 설계값 500 ms와 일치).

### 5. 운영상 참고 사항 (부수 발견, 버그 아님)

- `watchdog_count`는 `armed` 신호로 게이트된다(`if(!armed)watchdog_count<=0;`) — 이것은
  의도된 설계다(모터가 실제로 돌 수 있을 때만 watchdog가 의미 있음). 다만 SW0 OFF(미arm)
  상태로 halt-test를 하면 카운터가 0에 영구히 고정되어 trip이 전혀 발생하지 않는다 — 버그가
  아니라 향후 이런 시험을 재현할 때 알아둬야 할 사항이다.
- `fault_latched`/`watchdog_fault` 상태 비트는 ARM resume(`con`)만으로는 자동 clear되지
  않는다 — 실제 SW0 OFF->ON 사이클이 `clear`를 assert해야 한다. 이를 놓쳐 이미 latch된
  상태를 방금 새로 트립된 것처럼 읽은 오염된 폴링 1건이 있었으나, 발견 즉시 원인을 파악하고
  정정한 뒤 재시행했다.

### 결론 (재강조)

watchdog RTL은 설계값 그대로 정확히 동작한다 — 카운터는 참 100 MHz로 돌고(두 독립 시행에서
0.06% 이내), 참 500 ms 근처(측정 452~508 ms, ~50 ms JTAG 폴링 해상도 이내)에서 trip한다.
**카운터 자체는 한 번도 버그였던 적이 없다.** 2026-09-15의 "1.489~1.6초, 약 3배" 관측은 그
세션의 측정 방법론(외부 증상만 관찰 — JTAG-halt + 모터 전류/LED 확인, 레지스터 직접 접근으로
대조하지 않음)이 만든 인공물이었다고 이제 이해된다 — 실제 RTL 결함이 아니었다. 이것으로
"다음 작업 순서" 1번(watchdog 근본원인 규명)을 **해결(RESOLVED)**로 종결한다 — watchdog
로직 자체에는 RTL 수정이 필요하지 않았다(오늘 실제로 이뤄진 RTL 수정 두 건은 관측 레지스터
추가로 필요해진, 기능과 무관한 타이밍 closure용 파이프라이닝이었다).

## 분류 패턴 원인 조사 — deep-reasoner 분석 (Finding 1, Finding 2)

watchdog 근본원인 규명 이후 같은 세션에서, 위 "두 가지 미검증 가설"로 남겨뒀던 `1,1,0` 분류
패턴 open question을 deep-reasoner로 분석했다. 두 가지를 확인했다.

- **Finding 1 (모델 포화, 증명됨)**: class 1일 때 18회 중 12회 전부 비트 단위로 동일했던 NPU
  출력 logit(`o0=-61, o1=60`)은 노이즈나 계산 오류가 아니라 실제 모델 포화 인공물이다. 첫
  레이어 가중치가 전부 음수인 조합에서 feature 크기가 일정 threshold를 넘으면 4개 hidden
  unit이 전부 0으로 clamp되고 출력이 bias 항만 남는 형태로 수렴한다. Python으로 이 경로를
  재구현해 실측 캡처와 bit-exact로 일치함을 확인했다 — 추정이 아니라 증명된 사실이다.
- **Finding 2 (폐루프 리밋 사이클, 구조적 설명·미확정)**: 정확한 call-count-locked 주기성
  (시간이 아니라 `s` 호출 횟수에 고정됨)은 폐루프 리밋 사이클과 부합한다. 분류는 순수히 `s`
  명령에 의해서만 트리거되고, safety supervisor의 `consec_count`/`derated` 상태는 호출 사이에
  시간 기반 decay 없이 무기한 유지되며, `fourier_motor_control.v`(약 77번째 줄)에서 2연속
  abnormal이 duty를 25%로 제한한다. (경험적으로 가정했을 뿐 아직 직접 확인되지 않은 부분):
  duty가 낮아지면 진동이 줄고, 다음 읽기가 정상으로 판정돼 카운터가 리셋되고, 다시 전체
  duty로 복귀하며 반복된다는 가설이다.
- deep-reasoner는 이 가설을 싸게 검증할 실험(E1)을 제안했다: `s`와 `f`(safety status)를
  번갈아 보내며 `derated` 비트와 `consecutive` 카운트가 분류 순서에 정확히 맞물려 예측된
  `0,1,0,0,1,0...` / `1,2,0,1,2,0...` 패턴을 따르는지 확인하는 실험이다.

## 분류 패턴 재현 시도 — acquire() 타이밍 버그 발견·수정, 원본 패턴은 재현 안 됨

위 E1을 실물에서 시도했다(모터 재arm, SW0+SW2 ON, PSU 12V, fault injection 없음).

### TIMING_ERROR 발견과 원인

- E1 첫 시도에서 `s` 명령이 전부 실패했다: `TIMING_ERROR,1,3993`(재시도해도 ~3990~3999 근처
  반복) — `fourier/firmware/main.c`의 `acquire()`가 모든 샘플 윈도를 거부하고 있었다.
- 근본원인: `acquire()`의 샘플별 타이밍 검증 게이트(`if(n && (dt[n]<700 || dt[n]>1300))`)가
  같은 날 앞서 수정한 `micros()` 타이밍 버그(`XSLEEPTIMER_FREQ` 괄호 누락, 위 "텔레메트리
  주기 버그 — 근본원인 규명·수정 완료" 절 참고) 이후 한 번도 다시 보정되지 않았다. 700~1300이라는
  bound는 옛날의(4배 작게 나오던) `micros()` 출력값에 맞춰 암묵적으로 보정돼 있던 값이었다.
  `micros()`가 실제 경과 시간을 정확히 보고하게 된 지금, 센서의 실제 인터샘플 간격(~4ms,
  ≈250Hz, `sensor_init()`의 `SMPLRT_DIV=3`과 일치)은 이제 정확히 ~4000us로 보고되는데, 이는
  재보정되지 않은 옛 700~1300 bound를 벗어난다. 이는 최초 `micros()` 버그 조사 당시 이미
  "collateral" 위험으로 지목했던 바로 그 항목이다(위 절: "acquire() sample-timing gate ...
  real accepted window is 2800-5200 us ... flag only") — 이번에 실제로 발현되어 수정됐다.

### 수정 내용 (`fourier/firmware/main.c`, 두 곳)

```c
// 1) 샘플 타이밍 검증 bound — 보정된 타이머에 맞춰 4배 재조정(앞서 flag된 권장 범위와 일치)
// 수정 전:
if(n && (dt[n]<700 || dt[n]>1300))
// 수정 후:
if(n && (dt[n]<2800 || dt[n]>5200))

// 2) 샘플별 SPI poll timeout — 실제 ~4ms 샘플 주기 위에 여유를 두도록 확장
// 수정 전:
if(micros(ticks()-deadline)>5000U)return -1;
// 수정 후:
if(micros(ticks()-deadline)>8000U)return -1;
```

- ELF만 재빌드(`app.build()`, XSA 변경 없어 `platform.build()` 불필요 — 순수 firmware 수정)하고
  기존 JTAG 복구 절차로 재프로그램.
- 검증: 센서 재초기화 정상(`WHO_AM_I,0x70`, `SENSOR_READY,1`), `s` 단발 성공
  (`RESULT,sensor,0,3389,833,18,107,...`) — `cpu_us=3389`/`e2e_us=107`은 앞서 기록한 보정된
  타이머 벤치마크 수치(`3391.43`/`107.56`)와 근접해 타이머 수정이 유지되고 있음을 교차 확인.

### 재시험 (9회, 원본 관측과 동일 조건: SW0+SW2 arm, PSU 12V, fault injection 없음, 폐루프 구동 중)

| run | class | RESULT |
|---:|---:|---|
| 1 | 0 | `RESULT,sensor,0,3388,833,18,107,1,0,1,1,1,19,18,25,24,89,-93` |
| 2 | 0 | `RESULT,sensor,0,3386,833,18,109,1,0,1,1,1,19,18,25,24,89,-93` |
| 3 | 0 | `RESULT,sensor,0,3387,833,18,106,1,1,1,1,1,16,15,21,20,65,-68` |
| 4 | 0 | `RESULT,sensor,0,3387,833,18,107,1,0,1,1,1,19,18,25,24,89,-93` |
| 5 | 0 | `RESULT,sensor,0,3385,833,18,106,1,0,0,0,1,23,22,30,28,119,-123` |
| 6 | 0 | `RESULT,sensor,0,3386,833,18,107,1,0,0,0,1,23,22,30,28,119,-123` |
| 7 | 0 | `RESULT,sensor,0,3387,833,18,108,1,0,0,1,1,20,19,26,24,94,-98` |
| 8 | 0 | `RESULT,sensor,0,3388,833,18,107,1,1,0,1,2,14,14,18,17,49,-52` |
| 9 | 0 | `RESULT,sensor,0,3386,833,18,109,1,1,0,1,1,17,16,22,21,72,-75` |

- 9회 전부 class=0(정상). 각 run 직후 `f` 확인 결과 9회 전부
  `SAFETY,warning,0,derated,0,latched,0,watchdog,0,cause,0,consecutive,0,abnormal_total,0` —
  변화 없이 유지.
- 원래 관측했던 `1,1,0` 반복 패턴(18회 중 12회 abnormal, 66.7%)은 이번엔 전혀 재현되지
  않았다 — 9회 전부 abnormal 0건.

### Fault injection sanity check (classifier가 죽어있지 않음을 확인)

SW3 ON(실제 물리적 토크 리플 주입, PWM 25%/75% 32Hz 교대, `fourier_motor_control.v`의
`fault_inject` mux로 PI 제어를 완전히 우회)으로 `s` 3회 추가 실행:

| run | class | RESULT |
|---:|---:|---|
| 1 | 1 | `RESULT,sensor,1,3391,833,18,109,1,2,1,3,2,4,3,5,5,-32,30` |
| 2 | 1 | `RESULT,sensor,1,3387,833,18,107,1,2,1,3,2,4,3,5,5,-32,30` |
| 3 | 0 | `RESULT,sensor,0,3388,833,18,109,1,0,1,1,1,19,18,25,24,89,-93` |

- 실제 물리적 외란에서 2/3 abnormal — classifier가 항상 정상만 내도록 고장난 것이 아니라 실제
  신호 내용에 반응한다는 것을 확인했다.
- SW3 OFF -> SW0 OFF(disarm) -> PSU OFF 순서로 안전 종료 확인.

### 결론 — 정확히 무엇이 증명됐고 무엇이 증명되지 않았는가

- **확실히 증명·수정됨**: `acquire()`의 타이밍 검증 bound가 보정된 `micros()`에 맞춰 재보정되지
  않아 100% 샘플 획득 실패(`TIMING_ERROR`)를 일으켰다. 이는 실재하는, 구체적인, 이제 수정된
  버그다 — 원본 `1,1,0` 패턴의 원인이 무엇이었든 이 버그 자체는 독립적으로 참이다.
- **완전히 증명되지 않음**: 이 버그가 원본 `1,1,0` 패턴의 원인이었다는 것. 원본 관측과 이번
  재시험 사이에는 `micros()`/`acquire()` 타이밍 수정뿐 아니라, watchdog 작업을 위한
  `pid_fixed.v`/`encoder_speed_hybrid.v` RTL 파이프라이닝 변경과 watchdog 카운터 AXI 노출까지
  여러 변수가 동시에 바뀌었다 — 한 가지 원인으로 깔끔하게 귀속시킬 수 없다. 특히 짚어둘 점:
  옛(수정 전) `micros()` 아래에서는 dt 값과 700~1300 bound가 동일하게 ~4배 스케일돼
  있었으므로, 그 게이트는 그 당시에도(같은 실제 ~4ms 물리 샘플 주기로) 아마 일관되게
  통과했을 것이다 — 즉 원시 센서 샘플링 자체는 두 관측 시점 사이 SPI/하드웨어 레벨에서 실제로
  다르지 않았을 가능성이 크다. 무엇이 정확히 바뀌었는지는 현재 증거로는 한 가지 메커니즘으로
  못박기 어렵다.
- **확실히 확립된 것**: 현재의, 완전히 수정된 firmware+RTL 상태에서 반복 실측(9회, fault
  injection 없음)은 신뢰성 있고 일관된 정상 판정을 보였다(오탐 0, 잘못된 derate 0). classifier는
  실제 fault injection에는 여전히 정확히 반응한다(2/3 abnormal). 이것이 포트폴리오 관점에서
  실질적으로 중요한 결과다: 통합 시스템은 현재 올바르게 동작하며 이전의 진동 패턴을 보이지
  않는다. 이는 현재의, 검증된, 재현 가능한 상태로 기록하는 것이지, 원본 이상 현상의 정확한
  메커니즘을 완전히 규명한 근본원인 조사로 기록하는 것이 아니다.
- deep-reasoner의 Finding 1(모델 포화가 고정 logit을 설명)과 Finding 2(리밋 사이클이 이런
  패턴이 발생할 수 있는 구조적 메커니즘을 설명)는 그 자체로 유효하고 근거 있는 기술적 결론으로
  기록에 남긴다 — 이번 업데이트로 대체하지 않는다. 실질적인 후속 실험(E1)은 리밋 사이클
  가설의 남은 경험적 공백을 직접 검증하기 전에, 다르고 실재하며 수정 가능한 버그를 먼저
  발견했다는 것이 이번 결과의 요지다.
