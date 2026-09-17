# 2026-09-17: PI 런타임 확장 · 시스템 식별 · encoder C2 quadrature

2026-09-15 결정("석사급 최종판")에 남아 있던 확장 두 묶음(MotorControl 제어 성능 확장, encoder
신뢰성 확장)을 완료한 세션의 상세 원본 데이터. 요약은 `HANDOFF.md`의 "2026-09-17 PI 런타임
확장 · 시스템 식별 · encoder C2 quadrature (완료)" 절 참고.

## RTL/펌웨어 확장 요약

- `pid_fixed.v`: Kp/Ki를 AXI 런타임 입력(`kp_gain`/`ki_gain`, Q16)으로 변경, `anti_windup_enable`
  입력 추가. 리셋 기본값은 원래 하드코딩 값(58982/3932/enabled=1)과 동일.
- `fourier_motor_control.v`: `open_loop_enable`/`open_loop_duty`로 PI 우회 경로 추가,
  `encoder_quadrature` 인스턴스 추가.
- `axi_vibration_top.v`: 새 레지스터 `0x068`(ctrl2)/`0x06c`(open_loop_duty)/`0x070`(kp_gain)/
  `0x074`(ki_gain)/`0x078`(quad status)/`0x07c`(quad_position)/`0x080`(quad_illegal_count).
- `fourier/rtl/encoder_quadrature.v`(신규): 방향/illegal/timeout/overflow fault 검출, 순수
  관측용.
- `fourier/firmware/main.c`: UART 명령 `p`(open-loop 시퀀스), `g`/`G`(게인 절대 지정),
  `w`/`W`(anti-windup 절대 지정), `t`/`T`(텔레메트리 절대 지정, 기존 토글에서 변경).
- `fourier/constraints/zybo_z7_20.xdc`: `encoder_b` → JD07(U14).
- `tools/capture_telemetry.py`(Zybo 자체 복사본에 `--send-command` 옵션 추가, MotorControl
  원본에는 없음), `tools/analyze_step.py`, `matlab/IDENTIFY_MOTOR.m`을 이 저장소에 복사.

XSim: 9/9 PASS(`tb_axi`, `tb_fourier_motor` 확장 포함).

## Open-loop 시스템 식별

명령: `python3 tools/capture_telemetry.py --port /dev/ttyUSB1 --duration 30 --send-command p --output artifacts/experiments/open_loop_identification.csv`

결과: frames=2466, dropped=0, bad_checksum=0. duty 전환 시점(설계 100 Hz 가정 `time_s` 기준):

| time_s | duty |
|---|---|
| 0.00 | 25.0% |
| 4.93 | 37.5% |
| 9.86 | 50.0% |
| 14.79 | 37.5% |
| 19.73 | 25.0% |
| (종료 24.65) | — |

각 구간 ~4.93초(설계 5초 대비 오차 1.4%), 25%p 이상 duty excitation, 24.65초 캡처 —
`IDENTIFY_MOTOR.m` 최소 요구(20%p, 10초) 초과 충족.

`IDENTIFY_MOTOR.m` 결과:

| PlantGain (RPM/duty-pu) | Tau (s) | DeadTime (s) | Train RMSE | Validation RMSE | Test RMSE | TestFit % | IMC_Kp | IMC_Ki (1/s) | IMC_Kp_Q16 | IMC_KiTs_Q16 |
|---|---|---|---|---|---|---|---|---|---|---|
| 71.361 | 0.6196 | 0.06 | 1.015 | 1.6612 | 0.86655 | **40.261** | 1.396 | 2.253 | 91486 | 1477 |

TestFit 40.3%은 1차 FOPDT/ARX 선형 모델이 실제 모터 비선형성(정지마찰, 인코더 양자화 노이즈
등)을 완전히 설명하지 못함을 의미 — 정직하게 낮은 값으로 기록한다. RMSE 자체는 절대값으로는
작다(<2 RPM, 전체 스케일 ~30 RPM 대비).

`CANDIDATE_KP_Q16=91486`, `CANDIDATE_KI_TS_Q16=1477`을 `main.c`에 반영, ELF만 재빌드.

## 원래 게인 vs candidate 게인 step 비교

두 캡처 모두 0→75%(target 81.9484 RPM) 단일 step, SW0 재arm으로 적분 0 확인 후 캡처.

- `step_original_gains.csv`: `--send-command tg`, 전환 sample=7(0.07s), 2486 frame, drop 0.
- `step_candidate_gains.csv`: `--send-command tG`, 전환 sample=85(0.85s), 2489 frame, drop 0.

`analyze_step.py` 원시 결과는 두 캡처 모두 전이 직후(0.1s 근처) 인코더 추정이 순간적으로
109.26 RPM까지 튀는 노이즈 스파이크(단일 샘플, 다음 프레임에 정상 복귀)가 있어 peak/overshoot
계산이 왜곡됐다. 이웃 샘플과의 편차로 스파이크를 제외한 robust 재계산 결과:

| | 원래 게인 (Kp=0.9, Ki=6/s) | candidate 게인 (Kp=1.396, Ki=2.25/s) |
|---|---|---|
| Robust overshoot | **11.10%** (peak 91.04 RPM @t=2.61s) | **3.68%** (peak 84.96 RPM @t=3.28s, 원시값과 동일) |
| 정상상태 속도 | 81.73 RPM | 81.37 RPM |
| 정상상태 오차 | -0.27% | -0.71% |

원래 게인의 11.10%는 아래 anti-windup ON 실험(같은 조건: 원래 게인, 0→75% step)의 원시
overshoot=11.1%와 정확히 일치 — 두 독립 캡처의 교차검증.

결론: candidate(모델기반) 게인은 Ki가 원래의 약 40%(6→2.25/s)로 줄어 overshoot는 크게 감소
(11.1%→3.7%)하지만 응답 속도가 느려진다(rise ~0.07s→~1.5s 체감) — IMC 튜닝의 전형적인
"보수적" 트레이드오프가 정성적으로 그대로 나타났다.

## Anti-windup ON/OFF 비교

원래 게인, 0→75% step, SW0 재arm으로 적분 0 확인 후 캡처(적분이 자연히 0으로 안 돌아가는 경우
`SW0 OFF→ON`으로 강제 리셋 — PI는 error=0에서 integral을 그대로 유지하므로 이전 시행의 잔여
integral이 남을 수 있음, 실제로 -4096(하드 클램프)에서 안 풀리는 것을 2회 관측·재arm으로 해결).

- `windup_on.csv`: `--send-command tw`(anti-windup ON, 기본값), 전환 sample=869(8.69s),
  2495 frame drop 0. 전이 구간(t=8.7~9.2s)에서 duty가 83%대에서 안정되며 매끄럽게 상승 —
  깨끗한 데이터.
- `windup_off.csv`: `--send-command tW`(anti-windup OFF), 여러 차례 재시도 끝에(중간 시행들은
  이전 세션에서 텔레메트리가 계속 켜진 채 남아 대량의 stale 시퀀스가 섞여 dropped가
  60000+로 나오는 문제가 반복됨 — `capture_telemetry.py`에 `t`/`T` 전송 후 0.2초 대기 +
  재차 `reset_input_buffer()`를 추가해 해결) 최종적으로 sample=258(2.58s) 전환, 2487 frame
  drop 0 확보.

수치 비교(`analyze_step.py`, 두 캡처 모두 peak_integral/peak_duty 직접 비교로 robust 검증):

| | ON | OFF |
|---|---|---|
| peak integral_q12 | 3399 (t=9.47s) | 3389 (t=3.65s) |
| peak duty | 85.5% | 85.4% |
| 정상상태 integral 평균(마지막 2s) | 3317 | 3297 |

**정직한 결론**: 이번 step 크기(0→75%, duty 최대 ~85%)에서는 `reject_update`의 트리거 조건
(`proposed_value>4096`, 즉 duty 100% 포화)이 거의 발동하지 않아 anti-windup 유무의 실질적
차이가 미미했다. 이는 anti-windup 로직이 무의미하다는 뜻이 아니라, 이 시스템의 게인/step 조건이
duty 100% 포화까지 밀어붙이지 않을 만큼 보수적으로 튜닝돼 있다는 방증이다(XSim에서는 encoder
피드백을 완전히 차단한 극단적 조건으로 실제 차이를 확인했다 — `tb_fourier_motor.v`의 anti-windup
테스트 참고). 더 강한 포화 조건(물리적 부하, 더 큰 reference)에서 재시험하면 차이가 더 뚜렷할
것으로 예상되나, 손으로 부하를 주는 비정량적 방법은 쓰지 않기로 하고 여기서 멈췄다.

## 전원 외란(disturbance) 시험

폐루프 PI 동작 중 PSU 전압을 12V→9V→12V로 수동 조작해 외란 거부(disturbance rejection) 성능을
확인. `capture_telemetry.py`로 60초 캡처, 조작 시점은 사전 동기화 없이 준비되는 대로 진행 후
CSV에서 실제 전환 시점을 사후 확인하는 방식(watchdog latency 실험과 동일 방법론).

- v1: 조작이 캡처 윈도우 밖에서 발생(전 구간 duty 65~67%로 안정, 전압을 7V까지 내렸다가 다시
  올렸으나 그마저도 윈도우 밖) — 폐기, 재시도.
- v2: 짧은 실수(t=8~9s, 94.5%까지 튐)와 실제 조작(t=22~32s, 66→83.5%)이 섞여 깨끗한 단일
  사이클이 아님 — 폐기, 재시도.
- v3: 깨끗한 단일 사이클 확보, 채택(`artifacts/experiments/disturbance_2026-09-17_v3.csv`).

**v3 타임라인**(target=54.632 RPM 고정, 원래 게인 Kp=58982/Ki·Ts=3932, anti-windup ON):

| 구간 | 시각 | duty | measured RPM |
|---|---|---|---|
| 기준 정상상태 | t=0~3.6s | 65.3~65.5% | 54.2~54.6(target 대비 오차 <1%) |
| 전압 강하 시작(12V→9V) | t≈3.6~4.4s | 65.5%→80.8%로 상승(PI가 낮아진 공급전압을 보상) | 순간 50.2까지 처짐, 곧 회복 |
| 강하 후 새 정상상태 | t=4.4~8.4s | 80.6~82.7% | 54.2~54.6(target 유지, 정상상태오차 <1%) |
| 전압 복귀 시작(9V→12V) | t≈8.41~8.45s | 82.6%에서 하강 시작 | - |
| overshoot 피크 | t=8.69s | 69.7% | **61.70 RPM(+12.9% overshoot)** |
| 정착(±2% 밴드 재진입, 이후 이탈 없음) | t=9.89s | 63.1%대로 수렴 중 | 밴드(53.54~55.72) 진입 |

**정착시간**(복귀 시작 t≈8.43s 기준): 약 1.46초. **overshoot**: +12.9%(target 대비, 계산:
(61.70-54.63)/54.63).

**해석**: 전압 강하 구간(약 0.8초에 걸친 전이) 동안 PI가 duty를 65%→81%로 끌어올려 RPM을 target
근처로 유지했다(정상상태오차 <1% — 외란 자체는 잘 거부됨). 이 4초간 낮은 전압 상태를 버티려고
적분항이 높은 값까지 누적된 상태에서 전압이 갑자기 12V로 복귀하자, 아직 덜 풀린 큰 적분값이
한동안 과도한 duty를 계속 명령해 순간적으로 실제 필요량보다 더 많은 토크가 걸리며 +12.9%
overshoot이 발생했고, 이후 약 1.5초에 걸쳐 적분값이 정상 수준으로 수렴하며 재안정됐다 —
"외란은 잘 거부하지만 외란이 사라지는 순간엔 적분누적값이 못 따라와 반대 방향으로 overshoot이
생긴다"는 PI 제어의 전형적 특성을 실측 데이터로 확인한 사례.

## Encoder C2 quadrature 실물 배선

- 배선: C1(A상, 기존 JD04) + C2(B상, 신규 JD07=U14).
- 배선 직전(B상 플로팅): `quad status=0x0`(정상), `quad illegal_count=1`(플로팅 노이즈로 인한
  1건, 검출기가 실제로 동작함을 보여줌).
- 배선 직후, 회전 없이: `quad status=0`, `illegal_count=1`(그대로, 더 안 늘어남 — 신호 안정).
- 최초 회전 시험(SW0 재arm, SW2 on, 50%): `quad status=1`(direction=1, RTL이 처음 정의한
  "backward"), `quad position` 매우 큰 음수(4294523595 unsigned = -443701 signed), 계속 감소 —
  실측 회전 방향과 RTL의 forward/backward Gray-code 매핑이 반대였음. illegal_count는 여전히
  1(신호 자체는 깨끗, 극성만 반대).
- `encoder_quadrature.v`의 case문에서 valid_forward/valid_backward에 매핑된 두 Gray-code
  walk를 스왑(00→10→11→01→00을 forward로 재정의). `tb_fourier_motor.v`의 quadrature 테스트도
  같이 갱신. XSim 9/9 재확인, ad-hoc 재빌드(WNS +0.119 ns), 재프로그램.
- 재검증(SW0 재arm, SW2 on): `quad status=0`(direction=0, 실제 정방향과 일치), `quad
  position=551454`(매끄럽게 증가), `illegal_count=1`(그대로), `measured_speed=1834`
  (reference 2048 대비 -10.4%, 정상 범위), `armed=1`. **방향 극성이 실측 기준으로 정확히
  맞춰졌다.**

## overflow_fault 실물 검증

32비트 position 카운터를 실제로 넘치려면 수십억 pulse가 필요해(4 count/pulse, CPR ~988 기준
약 5.4억 회전) 애초엔 XSim 검증만 하고 실물은 생략했다. 대안으로 `0x07c`(quad_position)를
read-only에서 read-write로 바꿔, AXI로 `+-2^31` 경계 바로 앞(`0x7ffffffe`)까지 프리셋한 뒤 진짜
인코더 전이 몇 개만으로 실제 오버플로우를 유발하는 방식을 추가했다.

**RTL 변경**: `encoder_quadrature.v`에 `position_wr_en`/`position_wr_value` 입력 추가, position
갱신 로직을 state-tracking과 분리해 "쓰기 > forward 이동 > backward 이동" 우선순위로 재구성.
`axi_vibration_top.v`의 `0x07c`가 read-write가 됨(쓰면 `quad_position_wr_en`을 한 사이클
pulse). `fourier/firmware/main.c`에 UART 명령 `o` 추가(프리셋 값 `0x7ffffffe` 고정).
XSim에 동일 시나리오 테스트 추가, 9/9 유지. ad-hoc 재빌드(WNS +0.091 ns, WHS +0.020 ns,
DRC 0), 재프로그램.

**실물 시험 절차(3회 반복)**: `o`로 프리셋 → 레지스터로 `position=2147483646`,
`overflow_fault=0` 확인 → SW0 arm → SW2를 짧게(약 0.5~1초) 켰다 끔(모터를 잠깐만 회전) →
레지스터 재확인.

| 회차 | 시작 position | 종료 position(raw, unsigned) | 증가량 | signed 재해석 | overflow_fault |
|---|---|---|---|---|---|
| 1 | 2147483646 | 2147496257 | 12611 | -2147471039(음수, wrap 확인) | 1 |
| 2 | 2147483646 | 2147488524 | 4878 | -2147478772(음수, wrap 확인) | 1 |
| 3 | 2147483646 | 2147485758 | 2112 | 음수(wrap 확인) | 1 |

3회 모두 raw 레지스터 값이 `2^31`(2147483648)을 넘어섰고, 이를 32비트 부호 있는 정수로
재해석하면 매번 정확히 음수로 wrap됐다 — 시뮬레이션이 아니라 실제 하드웨어의 32비트 부호 검사
arithmetic이 진짜 인코더 전이로 검증됐다. 매 회차 후 SW0 OFF→ON으로 fault를 clear하고 `o`로
재프리셋해 독립 시행을 보장했다. (각 회차에 `timeout_fault`도 함께 떴는데, 모터가 짧게 돌다
멈추는 전환 구간에서 duty가 0이 아닌 채로 잠깐 유지된 부수적 현상이며 overflow 검증과는
무관하다.)

## gate 재검증

소스가 이 세션에서 두 번 바뀌었다(1차: RTL 확장 전체, 2차: candidate 게인 상수 반영) — 매번
MATLAB Online 공식 gate를 다시 통과시켰다.

- 1차 digest `16437f3e1b508433403bd304207f331f5668ba9c2bfedea4cb68aa4656dd4337`(이게 최종 digest
  — 2차는 이 표에 반영 안 된 이전 시도용 중간 digest였으나 동일한 절차로 재검증했다)
- 공식 XSim: `XSIM REGRESSION PASS fourier`
- 공식 `tools/run.py build`: 기본 route로 바로 타이밍 통과(WNS +0.119 ns, WHS +0.030 ns,
  DRC Error 0) — 이번엔 AggressiveExplore 복구가 필요 없었다.
- Vitis platform/FSBL/app 재빌드 PASS, 실물 재프로그램 후 UART/레지스터 정상 확인.

최종 artifact 해시는 `HANDOFF.md`의 "gate와 artifact의 정확한 현재 상태" 절 참고.

### gate 재검증 3차 — docs/study 학습자료 추가, PYTHONHOME 빌드 버그 수정 (최종)

이후 `docs/study/`(전체 RTL/firmware 한국어 학습용 주석 사본, 19개 파일)를 추가하면서
`tools/gates.py`/`matlab/source_digest.m`/`tools/package_matlab.py`의 `EXCLUDED` 세트에
`'docs'`를 추가해 이 폴더가 gate digest에 영향을 주지 않게 했다(1차 digest 재사용).
공식 build 재실행 중 `vivado/build_bitstream.tcl`에 `run_simulations.tcl`에는 있던
PYTHONHOME/PYTHONPATH 초기화 두 줄이 빠져 있던 걸 발견해 추가했다(순수 빌드 스크립트 버그,
RTL/로직과 무관 — Vivado 배치 실행 시 내부 Python gate 호출이 Vivado 번들 Python과 충돌해
죽는 문제였다). 이 한 줄 변경으로도 소스 digest가 바뀌어 MATLAB Online을 한 번 더
재검증했다.

- 최종 digest `ee3afdf9d5068a2cb192feb5193601d15e72ea3093173fb9d48f5b292b73cc0f`
- 공식 XSim: 9/9 PASS 재확인
- 공식 `tools/run.py build`: 기본 route로 타이밍 통과(WNS +0.091 ns, WHS +0.020 ns,
  DRC Error 0) — synth/impl 도중 세션이 한 번 끊겼으나 route_design까지 이미 완료된 상태라
  전체를 처음부터 재시작해 다시 통과시켰다. `DIGILENT_BOARD_REPO` 환경변수가 없어
  `create_fourier.tcl`의 board part 조회가 실패하는 문제도 발견해
  `~/.Xilinx/Vivado/2024.2/xhub/board_store/.../boards`를 지정해 해결했다(둘 다 인프라
  문제였고 RTL/펌웨어는 변경 없음).
- Vitis platform/FSBL/app 재빌드 PASS, FSBL 해시는 PS7 설정 불변으로 이전과 바이트 단위
  동일(`528b430...`). 실물 재프로그램 후 `r` 명령으로 `replay_normal`/`replay_fault` 둘 다
  `match=1` 확인(CPU golden model과 PL 하드웨어 결과 bit-exact 일치).

최종 artifact 해시(이 3차 재검증 기준)는 `HANDOFF.md`의 "gate와 artifact의 정확한 현재 상태"
절 참고 — 이 절이 최신 유효 해시다.
