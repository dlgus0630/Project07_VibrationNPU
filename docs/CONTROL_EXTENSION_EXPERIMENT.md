# PI 확장 실험: 시스템 식별 · 모델기반 PI 비교 · anti-windup 수치화

## 목적

지금까지의 PI는 `Project07_MotorControl`(Basys3)에서 손으로 튜닝한 고정 게인(Kp=0.9,
Ki*Ts≈0.06, 둘 다 Q16)을 그대로 이식한 것이다. 이 문서는 그 게인이 실제 모터 특성에 맞는지
검증하기 위해: 1) open-loop 데이터로 모터 모델을 식별하고, 2) 식별된 모델 기반 게인과 원래
게인을 동일 조건에서 비교하고, 3) anti-windup을 켰을 때와 껐을 때의 차이를 수치로 남긴다.

Zybo의 telemetry frame은 `Project07_MotorControl`의 16바이트 포맷과 동일하다. 이 저장소의
`tools/capture_telemetry.py`는 그 decoder를 보존하면서 `--send-command`로 같은 serial
connection에 실험 명령까지 보낸다 — 터미널과 캡처 도구가 포트를 동시에 여는 일이 없다. 분석은
이 저장소에 포함한 `tools/analyze_step.py`와 `matlab/IDENTIFY_MOTOR.m`을 사용한다. PL에는
런타임 튜닝 레지스터(AXI `0x068`/`0x06c`/`0x070`/`0x074`)를 추가했고, UART 명령은 전부 절대
지정이다(토글 아님) — 이전 상태를 몰라도 스크립트로 원하는 상태에 확정적으로 들어간다: `p`(open-loop
여기 시퀀스), `g`/`G`(원래/candidate 게인), `w`/`W`(anti-windup 켜기/끄기).

## 사전 확인

재플래시 직후, 아무것도 쓰지 않은 리셋 기본값이 기존 고정 게인과 정확히 같은지 먼저 확인한다.

```text
f  (SAFETY 상태 출력으로 정상 부팅 확인)
```

호스트에서 AXI 레지스터를 직접 읽어도 된다(JTAG `mrd -force -value`):
`0x43c00070`=`58982`(Kp Q16), `0x43c00074`=`3932`(Ki*Ts Q16), `0x43c00068`=`2`(bit1
anti_windup_enable=1, bit0 open_loop_enable=0). 다르면 실험을 시작하지 않는다.

## 1. Open-loop 시스템 식별 캡처

SW0으로 arm한 뒤(SW2..1은 무관, open-loop이 override한다), UART 터미널을 닫고 아래 명령 하나만
실행한다. 캡처 도구가 포트를 단독으로 열어 `p`를 전송하고 25% → 37.5% → 50% → 37.5% → 25%
계단 입력(각 5초)을 기록한다. 같은 포트를 터미널과 캡처 도구에서 동시에 열지 않는다.

```text
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 30 \
  --send-command p --output artifacts/experiments/open_loop_identification.csv
```

`p`가 실행되는 동안 firmware가 100 Hz binary telemetry를 직접 내보낸다. `OPEN_LOOP_DONE` 뒤에는
open-loop과 이 명령이 임시로 켠 telemetry가 자동으로 꺼지고 이전 PI 폐루프 상태로 복귀한다.

## 2. MATLAB Online에서 모델 식별

CSV를 프로젝트에 넣고 실행한다(열 이름이 이미 `IDENTIFY_MOTOR.m`이 기대하는 것과 같다 —
`time_s`, `duty_percent`, `measured_rpm`, `enabled`, `fault`):

```matlab
model = IDENTIFY_MOTOR('artifacts/experiments/open_loop_identification.csv');
```

`IMC_Kp_Q16`, `IMC_KiTs_Q16` 두 값을 받는다. 이 값은 `pid_fixed.v`가 이미 쓰는 것과 정확히 같은
컨벤션(Kp는 Q16, Ki는 "Ki*Ts를 Q16"으로 표현)이라 변환 없이 그대로 쓴다.

`fourier/firmware/main.c`의 `CANDIDATE_KP_Q16`/`CANDIDATE_KI_TS_Q16`을 이 값으로 바꾸고 ELF만
재빌드한다(비트스트림은 그대로 — 게인이 이제 레지스터이므로 재합성 불필요).

## 3. 원래 게인 vs 모델기반 게인 비교

두 번 모두 같은 step을 재현한다: SW2로 목표를 고정해 둔 채 SW0으로 arm해 안정화하고, 캡처가
시작된 뒤 `EVENT 1 NOW`가 뜨면 SW1을 켜서 다음 단계로 올린다(기존 `docs/HARDWARE.md`/오늘
외란시험과 같은 SW2..1 레벨 체계). `--send-command`가 게인 전환과 캡처 시작을 한 번에 묶으므로
별도로 UART 터미널을 열 필요가 없다.

```text
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 20 --mark-after 5 \
  --send-command tg --output artifacts/experiments/step_original_gains.csv
```

```text
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 20 --mark-after 5 \
  --send-command tG --output artifacts/experiments/step_candidate_gains.csv
```

각각 지표를 뽑아 비교한다.

```text
python3 tools/analyze_step.py artifacts/experiments/step_original_gains.csv
python3 tools/analyze_step.py artifacts/experiments/step_candidate_gains.csv
```

rise time, overshoot, settling time, steady-state error 네 지표를 표로 남긴다.

## 4. Anti-windup 수치화

포화를 유발할 만큼 큰 step(가능하면 최대인 75% 목표, 가벼운 부하 조건)으로 두 번 캡처한다. 게인은
원래 값으로 고정한 채(3번 실험 뒤라면 마지막이 `G`였을 수 있으니, 아래 `g` 전송으로 먼저 원래
게인으로 되돌린다) anti-windup만 바꾼다.

```text
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 3 \
  --send-command tg --output artifacts/experiments/_reset_gains.csv
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 15 --mark-after 3 \
  --send-command tw --output artifacts/experiments/windup_on.csv
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 15 --mark-after 3 \
  --send-command tW --output artifacts/experiments/windup_off.csv
```

실험이 끝나면 반드시 `w`를 한 번 더 보내 anti-windup을 켜진 상태로 되돌려 놓는다(원래의 안전한
기본값).

```text
python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 3 \
  --send-command tw --output artifacts/experiments/_rearm_windup.csv
```

`analyze_step.py`로 `windup_on.csv`/`windup_off.csv`의 overshoot/settling time을 비교한다 —
anti-windup이 꺼진 쪽이 포화 복원 후 더 크고 느린 overshoot를 보여야 한다(적분이 출력 포화
시점보다 늦게, 더 큰 값까지 쌓이기 때문).

## 결과 기록

수치 결과는 `artifacts/single_board_integration_2026-09-16.md`(또는 실험 당일 날짜의 새 파일)에
원본 CSV 경로와 함께 남긴다. README에는 결정적인 결과(식별된 모델 정확도, 게인 비교 수치,
anti-windup 차이)만 요약해 추가한다.
