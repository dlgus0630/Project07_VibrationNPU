# VHDL RTL 설계와 검증

FPGA의 FFT·INT8 NPU·AXI·SPI·모터 제어·안전 회로를 VHDL RTL로 구성한다.
설계는 **패키지 2개, entity 20개, 이름 있는 프로세스 88개**로 나누며,
상태 제어·데이터 계산·카운터·출력 레지스터의 역할을 각 프로세스에 명시한다.
ARM 앱과 정수 기준 모델은 C, 분석·검증은 MATLAB·Python, 빌드는 Tcl을 사용한다.

## 소스 구성

- `fourier/vhdl/`: FFT·NPU·AXI·SPI·PID·encoder·PWM·안전 회로.
- `common/reset_sync.vhd`: 비동기 assertion·동기 해제 리셋.
- `fourier/vhdl/vibration_types.vhd`: 정수 배열과 `.mem` 테이블 읽기.
- `fourier/rtl/*.v`, `common/reset_sync.v`: 동등성 검증용 참조 RTL.
- `fourier/tb_vhdl/`: 기준값 및 Verilog/VHDL 동시 실행 비교 테스트.

모듈·신호 연결은 [구조도](architecture/README.md), 실행 조건은 [상태천이도](state_diagrams/README.md)에서 확인한다.
기능별 코드 구성은 [모듈 연결과 프로세스 목록](../fourier/vhdl/README.md)에서 확인한다.
`axi_vibration_struct.vhd`와 `fourier_motor_struct.vhd`는 연결만 담당한다.
AXI 레지스터와 운전 명령은 각각 `axi_registers_rtl.vhd`, `motor_run_control_rtl.vhd`로 나눴다.
FFT·NPU·코어·PI는 상태 레지스터, 다음 상태, 데이터, 카운터 프로세스로 나눴다.
전체 설계는 패키지 2개, entity 20개, 이름 있는 프로세스 88개다.
PI의 조합 계산도 P항·적분 증가량·적분 합·측정값 필터·anti-windup 선택의 5개 프로세스로 나눴다.

Vivado는 합성 파일로 VHDL만 읽는다. 테스트벤치와 비교 기준 Verilog는 검증 시에만 사용한다.
`data/*.mem`에서 twiddle, 가중치, bias와 shift를 읽는다.

## Vivado 최상위 연결

내부 회로는 VHDL 2008이다. Vivado 2024.2의 블록 디자인 module reference에 맞춰
`axi_vibration_top.vhd`, `fourier_motor_control.vhd`는 VHDL-93 연결 파일로 둔다.
각각 `axi_vibration_impl`, `fourier_motor_impl`의 동일한 포트로 연결하는 구조 계층이다.
두 구현 entity는 각각 `axi_vibration_struct.vhd`, `fourier_motor_struct.vhd`에 있다.

연결 파일은 `python3 tools/generate_vhdl_wrappers.py`로 생성한다. Vivado 인터페이스 속성은
architecture 선언부에 둔다. [AMD UG994의 VHDL 속성 사용법](https://docs.amd.com/r/en-US/ug994-vivado-ip-subsystems/General-Usage)을 따른다.

VHDL-93은 같은 목록의 generic을 다른 generic의 기본식에서 참조할 수 없으므로,
모터 연결 파일의 `WATCHDOG_CYCLES=-1`은 elaboration 단계에서 `CLK_HZ/2`로 계산한다.
명시적으로 지정한 0 이상의 값은 그대로 전달된다. 기본 100 MHz에서 50,000,000클록이다.

## 소프트웨어 검증

프로젝트 폴더에서 실행한다.

```bash
python3 tools/run_vhdl_validation.py
python3 tools/check_vhdl_preservation.py
```

| 검사 | 확인 내용 |
|---|---|
| `tb_fft_npu_vhdl` | 20개 기준 입력의 feature·hidden·logits·class, NPU 18클록 |
| `tb_mac` | signed INT8 곱 65,536개, bias와 hold |
| `tb_core` | 20개 입력, BRAM 소유권·11개 결과 write·busy·reset abort |
| `tb_axi` | AW/W 도착 순서, backpressure, byte strobe, 오류·상태·제어 레지스터 |
| `tb_spi` | 읽기·쓰기, 16비트 원자적 읽기, reset abort |
| `tb_fault_latch` | 연속 이상 latch 계약 |
| `tb_safety_supervisor` | warning·derate·classifier/watchdog latch |
| `tb_core_equivalence` | 20개 입력에서 Verilog/VHDL의 모든 외부 출력과 사이클 비교 |
| `tb_pid_equivalence` | 양·음 게인·포화·리셋을 포함한 2,000회 입력의 클록별 출력 비교 |
| `tb_motor_equivalence` | PI·인코더·PWM·warning·derate·latch·watchdog와 telemetry의 클록별 비교 |
| `tb_reset_sync_vhdl` | VHDL 단독 TB: 초기/비동기 리셋, 2클럭 해제, 해제 중 재인가 |
| `tb_mac_pe_vhdl` | VHDL 단독 TB: reset, clear 우선, signed 곱, bias, hold, INT32 wrap |
| `tb_fft_npu_native_vhdl` | VHDL 단독 TB: 20개 입력의 feature·hidden·logits·class와 NPU 18클럭 |

참조 RTL의 `tb_fft_npu` 내부 complex bin 검사는 2026-09-17 로그에서 확인한다.
현재 VHDL 테스트는 외부 정수 특징·층별 출력과 코어 포트의 클록별 비교 범위를 기록한다.
각 실행은 새로운 `build/vhdl_validation/run_*/`에 소스 SHA-256, 테스트별 로그와 결과 JSON을 저장한다.

현재 소스의 검증 자료는 [전체 RTL·펌웨어 검증 기록](evidence/readability_complete_2026-11-15/)에 정리한다.
C 정수 모델은 10,651개 입력의 중간값·결과를, 펌웨어는 명령 20개 시나리오와 PC 검사 8개 경우를 비교한다.
모델 상수·실측 CSV·계측 사진·기준 RTL은 SHA-256으로 관리한다.

VHDL TB는 DUT와 TC 목록, 시간 상수, 입력/출력 신호, COMPONENT와 binding,
PORT MAP, 클럭 생성, 자극과 ASSERT 순서로 작성했다. 동등성 비교 TB도 함께 실행한다.

## 빌드와 검증 자료

`vivado/common.tcl`은 VHDL 파일과 컴파일 순서를 지정하고, 생성 wrapper도 VHDL로 설정한다.
`vivado/run_simulations.tcl`은 MATLAB 선행 gate 확인 후 위 VHDL 검사를 실행한다.
독립 검사 결과는 실행별 폴더에 저장하고, 공식 `matlab.pass`, `sim.pass`는 각 선행 검증 단계에서 관리한다.

블록 디자인 검증은 `build/vhdl_structure_bd/fourier/fourier.xpr`에서 수행했다.
가속기와 모터의 별도 out-of-context 합성은 `vivado/check_vhdl_synthesis.tcl`로 확인한다.
블록 디자인 생성과 단위 합성은 routed timing 결과와 구분한다.

[BD 검증 로그](evidence/readability_complete_2026-11-15/block_design.log) ·
[가속기 합성](evidence/readability_complete_2026-11-15/synthesis_accelerator.log) ·
[모터 합성](evidence/readability_complete_2026-11-15/synthesis_motor.log) ·
[Vitis 앱 빌드](evidence/readability_complete_2026-11-15/vitis_build.log)

README의 WNS **+0.091 ns**, WHS **+0.020 ns**는 2026-09-17 Verilog 참조 구현의 routed 기록이다.
보드 사진·CSV·MATLAB 배열은 [자료 출처](SCREENSHOT_PROVENANCE.md)의 날짜별 원본을 따른다.
VHDL의 논리 검사·단위 합성·BD 검증은 [현재 소스의 로그·파일 지문](evidence/readability_complete_2026-11-15/)으로 연결한다.
