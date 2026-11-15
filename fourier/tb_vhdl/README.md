# 현재 HDL 검증 코드

현재 회귀 검사는 이 폴더의 VHDL/SV TB를 사용한다.
동등성 비교에 사용하는 Verilog 참조 회로와 TB는 `fourier/rtl`, `fourier/tb`에 보관한다.

TB는 확인 항목 → 입력/출력 신호 → 이름 기반 DUT 포트 연결 → 클럭/주변장치 모델 →
자극과 자동 판정 → timeout 순서로 읽는다.
비교 TB의 `_v`는 VHDL, `_r`는 참조 Verilog 출력이다.
`output_check_proc`는 `check_signal()`로 한 신호씩 비교해 실패한 신호 이름을 출력한다.

| TB | 확인 항목 |
|---|---|
| [tb_mac.sv](tb_mac.sv) | signed INT8 전체 65,536쌍과 bias/hold |
| [tb_core.sv](tb_core.sv) | 20개 입력, BRAM 결과 11개, 입력 보존, busy와 reset 중단 |
| [tb_axi.sv](tb_axi.sv) | 채널 도착 순서, backpressure/strobe, 상태·제어·SPI 레지스터 |
| [tb_spi.sv](tb_spi.sv) | 단일/연속 2바이트 전송과 reset 중단 |
| [tb_fault_latch.sv](tb_fault_latch.sv) | 연속 이상, 포화, clear/재발생과 idle 입력 |
| [tb_safety_supervisor.sv](tb_safety_supervisor.sv) | warning/derate/latch/watchdog |
| [tb_fft_npu_vhdl.sv](tb_fft_npu_vhdl.sv) | 20개 기준 입력의 NPU 각 층과 18클럭 |
| [tb_core_equivalence.sv](tb_core_equivalence.sv) | 원본/VHDL 코어의 모든 외부 포트 클록별 비교 |
| [tb_pid_equivalence.sv](tb_pid_equivalence.sv) | 2,000회 PI 입력의 duty/적분/필터/busy/done 비교 |
| [tb_motor_equivalence.sv](tb_motor_equivalence.sv) | 모터·안전·인코더·PWM·telemetry 클록별 비교 |
| [tb_reset_sync_vhdl.vhd](tb_reset_sync_vhdl.vhd) | 초기/비동기 인가, 두 클럭 해제와 재인가 |
| [tb_mac_pe_vhdl.vhd](tb_mac_pe_vhdl.vhd) | reset, clear 우선, signed MAC, hold와 wrap |
| [tb_fft_npu_native_vhdl.vhd](tb_fft_npu_native_vhdl.vhd) | COMPONENT/binding 방식의 20개 FFT/NPU 단독 검사 |

기존 자극 순서·대기 시간·seed·판정 조건을 유지했다.
프로젝트 루트에서 `python3 tools/run_vhdl_validation.py`로 13개 검사를 실행한다.
실행마다 새 폴더에 소스 지문과 실제 XSim 로그를 저장한다.
