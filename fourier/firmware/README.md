# C 펌웨어 읽는 순서

[main.c](main.c)는 앱 초기화, 주기 작업, UART 명령 분기를 담당한다.
각 명령의 실제 계산과 I/O는 아래 기능 모듈에 둔다.

```text
main.c                         초기화 → heartbeat/telemetry → execute_command
├─ app_platform.c              BSP 타이머, us 환산, heartbeat
├─ app_telemetry.c             PL 상태 → little-endian 16바이트 프레임 → UART
├─ sensor_spi.c                명령 조립 → 완료/timeout → 센서 설정/64개 수집
├─ app_inference.c             C 계산 → BRAM 입력 → PL 실행 → 결과 비교/RESULT
│  └─ golden.c                 FFT + INT8 NPU 정수 기준 모델
└─ motor_commands.c            안전 상태, open-loop 계단, 게인/anti-windup/위치
```

공통 주소·마스크·주기는 [app_registers.h](app_registers.h)에 모았다.
센서 설정표는 주소 이름과 값을 나란히 두고, 첫 쓰기 실패에서 중단한다.
SPI 명령 구성과 완료 대기를 분리해 각 비트와 timeout의 의미를 읽을 수 있게 했다.

ARM 앱의 C 소스는 위 **7개**다. 모든 해당 `.h`와 기존 `model_data.h`를 함께 사용한다.
[host_check.c](host_check.c)는 PC 검사 프로그램이며 별도 `main()`을 가진다.
기준 파일 열기·입력 읽기·결과 비교·종료를 별도 함수로 구성한다.

## 골든 모델

[golden.c](golden.c)의 `infer_integer()`에서 전체 처리 순서를 먼저 읽는다.
각 단계의 실제 계산은 같은 파일의 이름 있는 함수에 있다. 공개 함수 선언과
`inference_result`의 배치는 [golden.h](golden.h)를 유지한다.

```text
infer_integer
├─ prepare_fft_input                 원본 64개 입력 정렬
│  └─ reverse_fft_index              6비트 인덱스 뒤집기
├─ run_fft_stages                    6단계 FFT
│  └─ apply_fft_butterfly            A ± B*W
│     ├─ multiply_by_twiddle         복소수 곱을 네 곱으로 전개
│     └─ scale_fft_output            /2 내림과 INT16 포화
├─ extract_band_features             네 주파수 대역의 특징
│  └─ select_frequency_band          bin 구간 선택
├─ run_hidden_layer                  4개 은닉 뉴런, ReLU
├─ run_output_layer                  2개 출력 점수, signed INT8
└─ logits 비교                       동점은 클래스 0
```

공통 함수 `floor_shift()`는 음수도 아래쪽 정수로 내림한다.
예를 들어 `-3/2`를 `-2`로 처리해 FPGA의 산술 우측 이동과 맞춘다.
`clamp_value()`는 범위를 벗어난 값을 경계값으로 제한한다.

복소수 곱은 `real_times_real`, `imag_times_imag`, `real_times_imag`,
`imag_times_real`로 나누고, 곱을 합친 후에 Q1.15 소수점을 조정한다.
반올림 위치를 바꾸면 결과가 달라지므로 곱마다 먼저 반올림하지 않는다.
FFT는 각 단계의 butterfly 출력에서 `/2`와 INT16 포화를 수행한다.

대역 특징은 bin `1..6`, `7..12`, `13..20`, `21..31`의
`|실수부|+|허수부|` 합을 `/32`하고 `0..127`로 제한한다.
은닉층도 `0..127`, 출력층은 `-128..127`로 제한한다.
가중치·bias·shift·twiddle은 기존 [model_data.h](model_data.h)를 읽는다.

C 함수는 호출한 순서대로 실행된다. VHDL 프로세스가 동시에 동작하는 방식과 구분한다.
골든 모델의 공개 함수와 결과 구조체는 기존 PC 검사와 ARM 앱에서 함께 사용한다.

## 결과 확인

프로젝트 루트에서 실행한다.

```bash
python3 tools/offline_check.py
python3 tools/check_golden_equivalence.py
python3 tools/check_firmware_equivalence.py
python3 tools/check_vhdl_preservation.py
```

첫 검사는 기존 20개 기준 입력과 Python 모델을 확인한다. 두 번째 검사는 보관한 원본 C와
현재 C를 비교한다. FFT 실수·허수 각 64개, 특징 4개, 은닉값 4개, 점수 2개, 클래스 1개를
각 윈도우에서 비교하며 구조체 padding은 비교하지 않는다.

펌웨어 비교는 가상 BSP에 원본/수정본의 실제 `main()`을 연결한다.
20개 명령 시나리오에서 MMIO 읽기·쓰기 순서/값, UART 바이트, 출력 문자열을 비교한다.
센서 값 `-32768/-1/0/1/32767`의 부호 해석도 포함한다.
정상 수집과 잘못된 ID/설정, SPI/data-ready/PL timeout, 잘못된 샘플 간격, 결과 불일치를 포함한다.
PC 검사기의 8개 성공/오류 경우와 결과 구조체의 크기/필드 위치도 비교한다.
설치된 Cortex-A9 BSP로 7개 모듈을 컴파일하고 하나의 ELF로 링크한다.
가상 BSP의 시간은 소프트웨어 시험용 값이다.

원본 실측 360개 윈도우와 경계값·난수 시험 입력은 보고서에서 구분한다.
기존 측정 CSV·사진·ELF·타이밍 보고서는 보존하고,
[골든 모델 정리 검증 기록](../../docs/evidence/golden_model_readability_2026-11-15/)에 검사 결과를 저장한다.
전체 모듈 정리 후의 기록은 [가독성 정리 검증](../../docs/evidence/readability_complete_2026-11-15/)에 보관한다.
