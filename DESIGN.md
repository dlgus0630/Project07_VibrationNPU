# 설계 계약

## 구현 언어

FPGA RTL은 `fourier/vhdl/`와 `common/reset_sync.vhd`의 VHDL을 사용한다.
이 문서의 수치·주소·타이밍 계약은 기존 Verilog 구현에서 그대로 유지한다.
`fourier/rtl/*.v`는 비교 기준이며, ARM의 공개 인터페이스·모델 상수와 실측 자료는 유지한다.
C 기준 모델은 [역할별 함수](fourier/firmware/README.md)로 정리하고 원본 정수 결과와 비교한다.
Vivado 최상위 연결 호환성과 검증 범위는 [VHDL 전환 기록](docs/VHDL_MIGRATION.md)을 따른다.
실제 모듈 계층과 프로세스별 역할은 [VHDL 코드 구성](fourier/vhdl/README.md)을 따른다.
`*_struct.vhd`는 모듈을 연결하고, 기능 파일에서는 상태·데이터·카운터의 기록 책임을 나눈다.

## 수치 형식

| 데이터 | 형식과 처리 |
|---|---|
| MPU X축 raw | signed INT16, ±2 g에서 16384 count/g |
| FFT real/imag | signed INT16, butterfly마다 `/2`, 최종 FFT(x)/64 |
| twiddle | signed Q1.15 |
| band sum | unsigned 32-bit, `abs(Re)+abs(Im)` |
| MLP 입력/hidden | INT8 범위 0..127 |
| weight | signed INT8 |
| accumulator/bias | signed INT32 |
| logits | signed INT8, -128..127 |

FFT는 64-point DIT, bit-reversed load, natural-order output이다. 특징 대역은 bin `1..6`,
`7..12`, `13..20`, `21..31`이며 각 합을 5-bit 오른쪽 shift 후 127에서 포화한다.
MLP는 `4 -> 4 ReLU -> 2`, MAC PE는 2개다. 동점이면 class 0이다.

## 주소

- AXI control: `0x43C00000`, 4 KiB
- BRAM: `0x40000000`, 4 KiB
- BRAM input: word 0..63
- BRAM result: feature 256..259, hidden 260..263, logits 264..265, class 266
- control `0x00`: START bit0, DONE/error clear bit1
- status `0x04`: busy bit0, done bit1, rejected-start bit2, fault latch bit3,
  warning bit4, derated bit5, watchdog fault bit6
- class `0x08`, total cycle `0x0C`, NPU cycle `0x10`
- feature `0x20..0x2C`, logits `0x30..0x34`
- SPI command `0x40`, SPI response `0x44`
- heartbeat `0x48`: bit0 write pulse, firmware period 100 ms
- safety telemetry `0x4C`: consecutive `[7:0]`, warning bit8, derated bit9,
  fault cause `[11:10]`, lifetime abnormal count `[31:16]`

START는 idle에서만 수락하고 DONE은 모든 결과 기록 뒤 올라간다. AXI AW/W는 독립 수신하며
B/R backpressure 동안 응답을 유지한다. PS는 accelerator busy 동안 BRAM을 접근하지 않는다.

status bit3 이상은 PL 안전 supervisor 상태다. 가속기 완료 확인은 기존처럼 bit0..2만 사용하므로
안전상태 추가가 FFT/NPU polling 계약을 바꾸지 않는다. `0x4C`의 fault cause bit0은 분류기 trip,
bit1은 heartbeat watchdog trip이다.

## 보드 출력

PS FCLK0은 100 MHz다. `JE1..4`는 MPU-6500/9250 SPI, `JD1..3`은 L298N ENA/IN1/IN2다.
모터 PWM은 20 kHz이며 SW2..1로 0/25/50/75%를 고른다. reset 뒤 SW0을 OFF에서 ON으로
바꿔야 arm되고 BTN0 또는 SW0 OFF로 즉시 차단된다. SW3가 ON이면 정상 duty 선택을 대신해
25%와 75% duty를 32 Hz로 교대한다. 이때 평균 duty는 정상 비교 조건인 50%와 같다.

## 안전 supervisor와 연속 이상 판정

검증된 v1 `fault_latch`는 기준선으로 남겨 두고, 확장판에서는 `safety_supervisor`가 run-length와
watchdog를 함께 소유한다. 첫 class 1은 warning, 두 번째 연속 class 1은 derated 상태를 만들며
`fourier_motor_control`이 요청 duty를 최대 25%로 제한한다. 세 번째 연속 class 1은 latch를 세워
PWM과 IN1을 0으로 만든다. trip 전 class 0은 run-length와 warning/derated를 0으로 복구한다.
latch와 fault cause는 정상 판정으로 해제되지 않으며 SW0 OFF 또는 reset만 해제한다.

ARM 펌웨어는 AXI `0x48`에 100 ms마다 heartbeat를 기록한다. 모터가 arm된 동안 500 ms 이상
heartbeat가 없으면 분류 결과와 독립적으로 watchdog cause를 latch한다. heartbeat 처리와 모터 보호는
동일한 100 MHz PL clock domain이며, PS가 정지해도 watchdog counter와 PWM 차단은 계속 동작한다.
누적 abnormal count는 SW0 clear 뒤에도 유지되고 FPGA reset에서만 0이 된다.

## v1 연속 이상 판정 latch 실측 기준선

`fault_latch`는 `class_valid` 펄스가 뜬 사이클에서만 판정을 갱신한다. `class_id`가 1이면
`consec_count`를 1 증가시키고 0이면 `consec_count`만 0으로 되돌린다. `consec_count`는
unsigned 8-bit이며 `CONSEC`에서 포화하므로 이상 구간이 길어져도 wrap하지 않는다.
`consec_count`가 `CONSEC-1`에 도달한 상태에서 다시 class 1이 들어오면 `latched`가 1이 된다.
`CONSEC` 기본값은 3이다.

`latched`는 정상 판정으로 해제되지 않고 `clear` 또는 `rst`로만 내려간다. `clear`는 펄스가
아니라 레벨 `!sw_sync[0]`이므로 SW0이 내려가 있는 동안에는 계속 해제 상태로 유지되며 SW0을
다시 올려야 판정이 재개된다. BTN0은 `reset_sync`를 거쳐 `rst`를 만들므로 latch도 함께
지우지만, 어떤 정지 뒤에도 재기동에는 SW0 OFF -> ON이 필요하므로 기록이 지워졌다는 이유만으로
모터가 다시 돌지는 않는다.

`fourier_motor_control`의 `enabled` 조건에 `!fault_latched`가 포함되므로 latch가 서면 모터 PWM과
IN1이 함께 0이 된다. `motor_fault` 출력은 Zybo LD1(M15)로 낸다.

임계값 3은 2026-09-14 2차 실측에 근거한다. 이상 구간에서는 3번째 window에서 3연속이 성립했고
64 ms window 기준 192 ms에 해당한다. 정상 구간에서는 단발 오검출 2건이 있었으나 연속 발생이
최대 1회여서 3연속이 한 번도 성립하지 않았다.

최종 통합 실측에서도 정상 window는 class 0 `3/3`이었고, SW3 토크 리플 전환 후 판정열
`0,1,1,1,0,0`의 세 번째 연속 class 1에서 latch가 설정됐다. AXI status는 `0x0000000A`,
보드 출력은 `LD0 OFF / LD1 ON`, 모터 전류는 0.13 A에서 0.01 A로 감소하며 실제 회전이
정지했다. SW0 OFF clear와 재arm 뒤 0.13 A로 재회전했다. UART 판정 사이에 사용자 확인 시간이
포함됐으므로 host timestamp는 차단 지연시간 측정값으로 사용하지 않는다.

`fault_latch`와 `fourier_motor_control`은 같은 100 MHz 클럭과 같은 리셋 도메인에서 동작하고
`class_valid`/`class_id`도 그 도메인에서 생성되므로 두 모듈 사이에 CDC 동기화 단을 두지 않는다.
비동기 입력인 SW만 기존과 같이 `sw_meta`/`sw_sync` 2단 동기화를 거친 뒤 `clear`로 쓴다.

## MATLAB·Simulink 6자유도 연구 확장

`RUN_RESEARCH_STUDY('all')`은 6자유도 하우징과 마운트의 결합 동역학, XYZ 가속도 센서,
기존 X축 정수 FFT/NPU, 안전 상태 관찰과 MATLAB 3차원 재생을 연결한다. 새 연구 경로는
`RUN_MATLAB_CHECKS`의 기존 golden 계약과 검증 마커를 대체하지 않는다. 학습 모델은 현재도
실측 X축 정상/주입 토크 리플용이며, 합성 불평형·불정렬 시나리오의 판정은 지정한 입력에 대한
모델 반응으로 기록한다. 안전 상태 표시는 prescribed excitation에 대한 관찰이며 기계적 폐루프
정지 응답을 의미하지 않는다.

좌표계, 마운트 행렬 유도, ZOH 이산화, 센서식, 모드/FRF/PSD/STFT, 64 ms 프레임 계약과
재현 실험은 [MATLAB·Simulink 연구 가이드](docs/MATLAB_SIMULINK_RESEARCH.md)를 따른다.
새 경로는 이 작업 환경에 MATLAB이 없어 실행 검증되지 않았으며 사용자의 MATLAB에서 생성·실행
결과를 확인해야 한다.

## MATLAB·Simulink 2차 실측 전용 재현

`RUN_MEASURED_STUDY`는 `measurements/final_50pct`의 실제 X축 360 windows와 원본 모터
telemetry 5개 capture만 사용한다. 기존 source manifest의 hash·학습/검증 run 분리를
검사하고, 원본 64-sample 단위의 정수 FFT/NPU와 제어기 telemetry를 별도 Simulink 모델에서
재생한다. 기계 파라미터나 미측정 Y/Z 축을 생성하지 않는다.

3차원 표현은 주파수 × window × 실측 기반 PSD [counts²/Hz]다. 약 0.384 s 간격의 host window 시각은
연속 센서 시각으로 쓰지 않으며 모터 `time_s`는 `sample/100`의 명목 시간으로 표시한다.
Simulink tick도 원본 재생 순서로 취급한다. 입력 출처, 시간 계약, 통계 해석과 실행 방법은
[실측 MATLAB·Simulink 가이드](docs/MATLAB_SIMULINK_MEASURED.md)를 따른다. 이 경로도
작성 환경에는 MATLAB이 없어 실제 `.slx` 생성·실행 성공 여부는 MATLAB 환경에서 확인해야 한다.
