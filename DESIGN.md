# 설계 계약

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
- status `0x04`: busy bit0, done bit1, rejected-start bit2, fault latch bit3
- class `0x08`, total cycle `0x0C`, NPU cycle `0x10`
- feature `0x20..0x2C`, logits `0x30..0x34`
- SPI command `0x40`, SPI response `0x44`

START는 idle에서만 수락하고 DONE은 모든 결과 기록 뒤 올라간다. AXI AW/W는 독립 수신하며
B/R backpressure 동안 응답을 유지한다. PS는 accelerator busy 동안 BRAM을 접근하지 않는다.

status bit3은 새로 추가한 모터 fault latch 상태이며 읽기 값은
`{28'd0, motor_fault_latched, sticky_error, sticky_done, visible_busy}`다. 기존 펌웨어는
`0x04`에서 bit1과 bit0/bit2만 검사하므로 bit3 추가로 동작이 바뀌지 않는다.

## 보드 출력

PS FCLK0은 100 MHz다. `JE1..4`는 MPU-6500/9250 SPI, `JD1..3`은 L298N ENA/IN1/IN2다.
모터 PWM은 20 kHz이며 SW2..1로 0/25/50/75%를 고른다. reset 뒤 SW0을 OFF에서 ON으로
바꿔야 arm되고 BTN0 또는 SW0 OFF로 즉시 차단된다. SW3가 ON이면 정상 duty 선택을 대신해
25%와 75% duty를 32 Hz로 교대한다. 이때 평균 duty는 정상 비교 조건인 50%와 같다.

## 연속 이상 판정 latch

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
