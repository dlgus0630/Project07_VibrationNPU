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
- status `0x04`: busy bit0, done bit1, rejected-start bit2
- class `0x08`, total cycle `0x0C`, NPU cycle `0x10`
- feature `0x20..0x2C`, logits `0x30..0x34`
- SPI command `0x40`, SPI response `0x44`

START는 idle에서만 수락하고 DONE은 모든 결과 기록 뒤 올라간다. AXI AW/W는 독립 수신하며
B/R backpressure 동안 응답을 유지한다. PS는 accelerator busy 동안 BRAM을 접근하지 않는다.

## 보드 출력

PS FCLK0은 100 MHz다. `JE1..4`는 MPU-6500/9250 SPI, `JD1..3`은 L298N ENA/IN1/IN2다.
모터 PWM은 20 kHz이며 SW2..1로 0/25/50/75%를 고른다. reset 뒤 SW0을 OFF에서 ON으로
바꿔야 arm되고 BTN0 또는 SW0 OFF로 즉시 차단된다. SW3가 ON이면 정상 duty 선택을 대신해
25%와 75% duty를 32 Hz로 교대한다. 이때 평균 duty는 정상 비교 조건인 50%와 같다.
