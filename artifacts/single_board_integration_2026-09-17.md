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
