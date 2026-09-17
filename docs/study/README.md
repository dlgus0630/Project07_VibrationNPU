# 공부용 주석 사본

이 폴더는 **실제로 커밋된 소스 코드(`fourier/rtl`, `fourier/firmware`, `common`)를 건드리지
않고**, 똑같은 내용에 아주 자세한 한국어 주석을 단 "학습용 사본"입니다. 포트폴리오에 제출하는
진짜 코드는 지금처럼 주석이 거의 없는 깔끔한 스타일을 유지하고, 이 폴더는 오직 공부용입니다.

## 왜 이렇게 나눴는가

- 실제 코드: `fourier/rtl/*.v`, `common/*.v`, `fourier/firmware/*.c` — 손대지 않음, 그대로 커밋.
- 이 폴더: 같은 파일명·같은 경로 구조로, 한 줄 한 줄 무엇을 하는지 + 왜 이렇게 짰는지 설명.

## 추천 읽는 순서

전체 시스템은 "센서 → 진동 분류(FFT+NPU) → 안전 판단 → 모터 제어"로 데이터가 흐릅니다. 이
순서대로 읽으면 전체 그림이 잡힙니다.

### 1단계 — 아주 작은 부품부터 (재사용되는 저수준 블록)
1. [common/reset_sync.v](common/reset_sync.v) — 비동기 리셋을 동기 리셋으로 바꾸는 표준 패턴
2. [fourier/rtl/unsigned_divider.v](fourier/rtl/unsigned_divider.v) — 나눗셈기(1클럭에 1비트씩)
3. [fourier/rtl/pwm_period.v](fourier/rtl/pwm_period.v) — PWM 파형 생성기
4. [fourier/rtl/mac_pe.v](fourier/rtl/mac_pe.v) — 곱셈-누산기 1개(신경망의 최소 단위)
5. [fourier/rtl/mpu_reg_spi.v](fourier/rtl/mpu_reg_spi.v) — SPI 센서 통신 엔진

### 2단계 — 진동 분류 파이프라인 (센서 데이터 → 정상/이상 판정)
6. [fourier/rtl/fft64_features.v](fourier/rtl/fft64_features.v) — 64점 FFT + 주파수 대역 특징 추출
7. [fourier/rtl/npu_2pe.v](fourier/rtl/npu_2pe.v) — 2개 MAC PE로 돌리는 작은 신경망(MLP)
8. [fourier/rtl/vibration_core.v](fourier/rtl/vibration_core.v) — FFT와 NPU를 순서대로 묶는 상위 제어기
9. [fourier/firmware/golden.h](fourier/firmware/golden.h),
   [fourier/firmware/golden.c](fourier/firmware/golden.c) — 위 FFT+NPU와 **완전히 같은 계산**을
   순수 C로 구현한 독립 검증용 코드(ARM에서도 돌고, PC에서도 돈다)
10. [fourier/firmware/host_check.c](fourier/firmware/host_check.c) — golden.c를 PC에서 자동
    테스트하는 프로그램

### 3단계 — 모터 제어 파이프라인 (엔코더 → 속도 추정 → PI 제어 → PWM)
11. [fourier/rtl/encoder_speed_hybrid.v](fourier/rtl/encoder_speed_hybrid.v) — 엔코더 펄스로
    속도를 추정(저속/고속 두 가지 방식을 섞음)
12. [fourier/rtl/encoder_quadrature.v](fourier/rtl/encoder_quadrature.v) — 두 번째 채널(C2)로
    방향과 고장(비정상 신호, 정지, 오버플로우)을 검출
13. [fourier/rtl/pid_fixed.v](fourier/rtl/pid_fixed.v) — 고정소수점 PI 제어기(+anti-windup)

### 4단계 — 안전 계층과 전체 통합
14. [fourier/rtl/fault_latch.v](fourier/rtl/fault_latch.v) — (초기 버전) 연속 이상 판정 latch
15. [fourier/rtl/safety_supervisor.v](fourier/rtl/safety_supervisor.v) — 최종 버전 안전 감독자
    (경고 → 제한 → 정지 + PS heartbeat watchdog)
16. [fourier/rtl/fourier_motor_control.v](fourier/rtl/fourier_motor_control.v) — 위 11~15번을
    전부 하나로 묶는 모터 제어 최상위 모듈
17. [fourier/rtl/axi_vibration_top.v](fourier/rtl/axi_vibration_top.v) — ARM(PS)이 AXI 버스로
    이 모든 것을 제어/관찰하는 레지스터 인터페이스
18. [fourier/firmware/main.c](fourier/firmware/main.c) — ARM에서 돌아가는 실제 애플리케이션
    (센서 초기화, UART 명령 처리, 위 레지스터들을 읽고 쓰는 주체)

## 배경지식이 필요한 용어 먼저 짚고 가기

- **Verilog-2001 / RTL**: 하드웨어(회로)를 텍스트로 설계하는 언어. `always @(posedge clk)`는
  "클럭이 0→1로 바뀌는 순간마다 아래를 실행"이라는 뜻이고, 이게 바로 "레지스터(플립플롭)"를
  만듭니다. `wire`는 그냥 배선(조합 논리 결과), `reg`는 값을 저장하는 레지스터입니다 —
  소프트웨어의 변수와 달리, `reg`라고 항상 진짜 하드웨어 저장소가 생기는 건 아니고(때로는 배선으로
  최적화됨), 문법적으로 "always 블록 안에서 대입 가능한 것"이라는 뜻에 가깝습니다.
- **상태 기계(FSM)**: `localparam IDLE=0, ...; case(state) ... endcase` 패턴이 반복해서
  나오는데, 이게 "지금 몇 번째 단계인지"를 기억하면서 한 클럭에 한 단계씩 진행하는 표준적인
  하드웨어 설계 방식입니다. 소프트웨어의 함수 호출과 달리, 하드웨어는 "한 클럭 안에 너무 많은
  계산을 한 번에 하면 신호가 제때 도착하지 못한다"는 물리적 제약이 있어서, 복잡한 계산을 여러
  클럭(여러 상태)으로 쪼갭니다. 이게 오늘 이 프로젝트에서 반복해서 나온 "타이밍 클로저를 위해
  한 상태를 두 상태로 쪼갰다"는 이야기의 배경입니다.
- **고정소수점(Fixed-point) / Q-format**: FPGA는 부동소수점(float) 연산이 비싸서, 정수 연산으로
  소수를 흉내 냅니다. "Q16"이면 정수값을 2^16으로 나눈 게 실제 값이라는 뜻입니다(예:
  `58982`(Q16) = `58982/65536` ≈ `0.9`). 곱셈 후에는 `>>>` 산술 시프트로 다시 스케일을
  맞춥니다.
- **AXI4-Lite**: ARM(소프트웨어)과 FPGA 회로(하드웨어)가 대화하는 표준 버스 프로토콜. 주소를 주고
  받는 채널(AW/AR), 데이터를 주고받는 채널(W/R), 완료를 알리는 채널(B)이 분리되어 있어서 이
  프로젝트의 `axi_vibration_top.v`처럼 "여러 레지스터가 있는 주변장치"를 만들 때 반복되는
  핸드셰이크 패턴이 있습니다.
