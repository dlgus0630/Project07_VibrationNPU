# VHDL 전환 기록

대상은 `Project07_VibrationNPU`의 FPGA RTL 15개 모듈이다. 기존 수치 형식, 가중치,
AXI 주소, BRAM 배치, 상태 전이와 출력 사이클을 유지하며 구현 언어를 VHDL로 바꾼다.
ARM 프로그램의 `golden.c`, `golden.h`, `main.c`, 모델 헤더는 C로 유지한다.

## 소스 구성

- `fourier/vhdl/`: FFT·NPU·AXI·SPI·PID·encoder·PWM·안전 회로.
- `common/reset_sync.vhd`: 비동기 assertion·동기 해제 리셋.
- `fourier/vhdl/vibration_types.vhd`: 정수 배열과 기존 `.mem` 읽기.
- `fourier/rtl/*.v`, `common/reset_sync.v`: 기존 회로의 원본 비교 기준.
- `fourier/tb_vhdl/`: 기준값 및 Verilog/VHDL 동시 실행 비교 테스트.

기능별 코드 구성은 [모듈 연결과 프로세스 목록](../fourier/vhdl/README.md)에서 확인한다.
`axi_vibration_struct.vhd`와 `fourier_motor_struct.vhd`는 연결만 담당한다.
AXI 레지스터와 운전 명령은 각각 `axi_registers_rtl.vhd`, `motor_run_control_rtl.vhd`로 나눴다.
FFT·NPU·코어·PI는 상태 레지스터, 다음 상태, 데이터, 카운터 프로세스로 나눴다.
전체 설계는 패키지 2개, entity 20개, 이름 있는 프로세스 88개다.
PI의 조합 계산도 P항·적분 증가량·적분 합·측정값 필터·anti-windup 선택의 5개 프로세스로 나눴다.

Vivado는 합성 파일로 VHDL만 읽는다. 테스트벤치와 비교 기준 Verilog는 검증 시에만 사용한다.
`data/*.mem`의 twiddle, 가중치, bias와 shift는 기존 파일을 그대로 읽는다.

## Vivado 최상위 연결

내부 회로는 VHDL 2008이다. Vivado 2024.2의 블록 디자인 module reference에 맞춰
`axi_vibration_top.vhd`, `fourier_motor_control.vhd`는 VHDL-93 연결 파일로 둔다.
각각 `axi_vibration_impl`, `fourier_motor_impl`의 동일한 포트로 연결하며 레지스터를 추가하지 않는다.
두 구현 entity는 각각 `axi_vibration_struct.vhd`, `fourier_motor_struct.vhd`에 있다.

연결 파일은 `python3 tools/generate_vhdl_wrappers.py`로 생성한다. Vivado 인터페이스 속성은
architecture 선언부에 둔다. [AMD UG994의 VHDL 속성 사용법](https://docs.amd.com/r/en-US/ug994-vivado-ip-subsystems/General-Usage)을 따른다.

VHDL-93은 같은 목록의 generic을 다른 generic의 기본식에서 참조할 수 없으므로,
모터 연결 파일의 `WATCHDOG_CYCLES=-1`은 elaboration 단계에서 기존 `CLK_HZ/2`로 바꾼다.
명시적으로 지정한 0 이상의 값은 그대로 전달된다. 기본 100 MHz에서 50,000,000클록이다.

## 소프트웨어 검증

프로젝트 폴더에서 실행한다.

```bash
python3 tools/run_vhdl_validation.py
python3 tools/check_vhdl_preservation.py
```

| 검사 | 확인 내용 |
|---|---|
| `tb_fft_npu_vhdl` | 기존 20개 입력의 feature·hidden·logits·class, NPU 18클록 |
| `tb_mac` | signed INT8 곱 65,536개, bias와 hold |
| `tb_core` | 20개 입력, BRAM 소유권·11개 결과 write·busy·reset abort |
| `tb_axi` | AW/W 도착 순서, backpressure, byte strobe, 오류·상태·제어 레지스터 |
| `tb_spi` | 읽기·쓰기, 16비트 원자적 읽기, reset abort |
| `tb_fault_latch` | 기존 연속 이상 latch 계약 |
| `tb_safety_supervisor` | warning·derate·classifier/watchdog latch |
| `tb_core_equivalence` | 20개 입력에서 Verilog/VHDL의 모든 외부 출력과 사이클 비교 |
| `tb_pid_equivalence` | 양·음 게인·포화·리셋을 포함한 2,000회 입력의 클록별 출력 비교 |
| `tb_motor_equivalence` | PI·인코더·PWM·warning·derate·latch·watchdog와 telemetry의 클록별 비교 |
| `tb_reset_sync_vhdl` | VHDL 단독 TB: 초기/비동기 리셋, 2클럭 해제, 해제 중 재인가 |
| `tb_mac_pe_vhdl` | VHDL 단독 TB: reset, clear 우선, signed 곱, bias, hold, INT32 wrap |
| `tb_fft_npu_native_vhdl` | VHDL 단독 TB: 20개 입력의 feature·hidden·logits·class와 NPU 18클럭 |

기존 `tb_fft_npu`의 내부 complex bin 검사는 9월 17일 로그에 보존한다.
현재 VHDL 테스트는 외부 정수 특징·층별 출력과 코어 포트의 클록별 비교 범위를 기록한다.
각 실행은 새로운 `build/vhdl_validation/run_*/`에 소스 SHA-256, 테스트별 로그와 결과 JSON을 저장한다.

처음 언어를 전환한 [10개 검사 기록](evidence/vhdl_2026-11-15/)과
모듈·프로세스 구조를 정리한 뒤의 [13개 검사 기록](evidence/vhdl_structure_2026-11-15/)을 나누어 보관한다.
PI 조합 계산을 단계별로 풀어 쓴 현재 소스의
[13개 검사·모터 합성 기록](evidence/vhdl_pid_readability_2026-11-15/)도 별도로 보관한다.
기존 RTL·펌웨어·데이터의 Git 기준 비교와 캡처 manifest의 SHA-256을 함께 확인한다.
가독성 정리를 요청한 `fourier/firmware/golden.c`는 보관한 원본과 수치 비교를 수행한다.
보존 검사에서는 가독성을 정리한 C 파일을 수치·프로토콜 비교 후 별도 항목으로 기록한다.
원본 Verilog 회로·모델 상수·실측 데이터의 변경은 허용하지 않는다.
검사 결과는 [골든 모델 검증 기록](evidence/golden_model_readability_2026-11-15/)에 보관한다.
남은 펌웨어·HDL·TB를 같은 기준으로 정리한 현재 소스의 기록은
[전체 가독성 정리 검증](evidence/readability_complete_2026-11-15/)을 따른다.
`main.c`, `host_check.c`, `golden.h`도 원본과 펌웨어 프로토콜·구조체 배치를 비교한 뒤 별도로 기록한다.

추가한 VHDL TB는 DUT와 TC 목록, 시간 상수, 입력/출력 신호, COMPONENT와 binding,
PORT MAP, 클럭 생성, 자극과 ASSERT 순서로 작성했다. 기존 비교 TB도 함께 실행한다.

## 빌드 연결과 결과 보존

`vivado/common.tcl`은 VHDL 파일과 컴파일 순서를 지정하고, 생성 wrapper도 VHDL로 설정한다.
`vivado/run_simulations.tcl`은 기존 MATLAB 선행 gate 확인 후 위 VHDL 검사를 실행한다.
독립 검사 도구는 공식 `matlab.pass`, `sim.pass`를 수정하지 않는다.

구조 정리 후 블록 디자인 검증은 `build/vhdl_structure_bd/fourier/fourier.xpr`에서 수행했다.
가속기와 모터의 별도 out-of-context 합성은 `vivado/check_vhdl_synthesis.tcl`로 확인한다.
블록 디자인 생성과 단위 합성은 routed timing 결과와 구분한다.

README의 WNS **+0.091 ns**, WHS **+0.020 ns**와 실측 수치는 기존 저장 결과다.
원본 보고서·CSV·계측 사진·MATLAB 배열을 그대로 보존한다. VHDL 검증 기록은 별도 경로에 남긴다.
