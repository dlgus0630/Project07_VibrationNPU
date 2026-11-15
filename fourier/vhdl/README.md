# VHDL 코드 읽는 순서

먼저 최상위 `*_struct.vhd`에서 `U_*` 연결을 보고, 해당 기능 파일의 이름 있는
`PROCESS`를 읽는다. 상태 레지스터, 다음 상태, 데이터 계산, 카운터를 나누었으며
한 레지스터는 한 프로세스에서만 기록한다. 정수 연산·상태 순서·출력 클럭은 기존 회로를 따른다.

## 모듈 연결

```text
axi_vibration_top.vhd                 Vivado 연결용 VHDL-93 포트
└─ axi_vibration_struct.vhd           entity axi_vibration_impl / structural
   ├─ U_REGS       axi_registers_rtl.vhd
   ├─ U_CORE       vibration_core_fsm.vhd
   │  ├─ U_FFT     fft64_features_fsm.vhd
   │  └─ U_NPU     npu_2pe_fsm.vhd
   │     ├─ U_PE0  mac_pe_rtl.vhd
   │     └─ U_PE1  mac_pe_rtl.vhd
   ├─ U_MISO_SYNC  input_sync_rtl.vhd
   └─ U_SPI        mpu_spi_fsm.vhd

fourier_motor_control.vhd             Vivado 연결용 VHDL-93 포트
└─ fourier_motor_struct.vhd           entity fourier_motor_impl / structural
   ├─ U_RESET      ../../common/reset_sync.vhd
   ├─ U_RUN        motor_run_control_rtl.vhd
   ├─ U_SAFETY     safety_supervisor_rtl.vhd
   ├─ U_ENCODER    encoder_speed_rtl.vhd
   │  └─ U_DIVIDER unsigned_divider_rtl.vhd
   ├─ U_PID        pid_controller_fsm.vhd
   ├─ U_QUADRATURE encoder_quadrature_rtl.vhd
   └─ U_PWM        pwm_period_rtl.vhd
```

`fault_latch_rtl.vhd`는 기존 연속 이상 latch의 단독 검증용 기준 기능이다.
현재 모터의 warning·derate·watchdog 통합 경로는 `U_SAFETY`가 담당한다.
`vibration_types.vhd`는 공통 정수 형식과 `.mem` 읽기,
`vibration_regs.vhd`는 AXI 주소·응답·초기 게인을 정의한다.

파일 이름의 `struct`는 연결, `fsm`은 순서 제어, `rtl`은 개별 회로를 뜻한다.
기존 포트·entity 이름을 유지하므로 `pid_controller_fsm.vhd`의 entity 이름은 `pid_fixed`다.
설계 파일에서는 `ENTITY work.이름(rtl)`로 연결 대상을 직접 지정하고,
학습용 VHDL TB에서는 `COMPONENT` 선언과 명시적 binding을 함께 보여 준다.

## 프로세스 구성

현재 설계는 패키지 2개와 entity 20개, 이름 있는 프로세스 **88개**로 구성한다.
최상위 연결 파일 4개에는 프로세스가 없다. 아래 개수는 TB를 제외한 설계 코드 기준이다.

| 파일 | 개수 | 프로세스와 담당 동작 |
|---|---:|---|
| [axi_registers_rtl.vhd](axi_registers_rtl.vhd) | 6 | `write_address_proc` 주소 보관, `write_data_proc` 데이터 보관, `write_response_proc` 응답, `register_write_proc` 제어 기록, `status_latch_proc` 상태 유지, `register_read_proc` 읽기 응답 |
| [vibration_core_fsm.vhd](vibration_core_fsm.vhd) | 7 | `clocked_proc`, `nextstate_proc` 상태 제어, `result_capture_proc` 결과 저장, `result_index_proc` 기록 순번, `handshake_proc` busy/done, `cycle_count_proc` 시간 계수, `result_write_proc` BRAM 데이터 선택 |
| [fft64_features_fsm.vhd](fft64_features_fsm.vhd) | 11 | `address_select_comb_proc` 주소/종료 조건, `butterfly_math_proc` 복소 곱, `butterfly_output_comb_proc` 합/차와 포화, `clocked_proc`, `nextstate_proc`, `load_index_proc`, `butterfly_index_proc`, `fft_memory_proc`, `butterfly_reg_proc`, `band_sum_proc`, `feature_out_proc` |
| [npu_2pe_fsm.vhd](npu_2pe_fsm.vhd) | 11 | `input_select_comb_proc` 입력 선택, `weight_select_comb_proc` 가중치/bias 선택, `quantize_comb_proc` 양자화, `clocked_proc`, `nextstate_proc`, `input_latch_proc`, `mac_index_proc`, `hidden_result_proc`, `logit_result_proc`, `handshake_proc`, `cycle_count_proc` |
| [mac_pe_rtl.vhd](mac_pe_rtl.vhd) | 1 | `mac_accumulate_proc` reset/bias/누산/hold |
| [input_sync_rtl.vhd](input_sync_rtl.vhd) | 1 | `input_sync_proc` MISO 2단 동기화 |
| [mpu_spi_fsm.vhd](mpu_spi_fsm.vhd) | 4 | `spi_divider_proc` 반주기 계수, `transaction_proc` 전송 제어, `receive_shift_proc` 수신 비트, `receive_result_proc` 수신 결과 |
| [motor_run_control_rtl.vhd](motor_run_control_rtl.vhd) | 6 | `switch_sync_proc` 스위치 동기화, `arm_control_proc` 운전 허용, `sample_tick_proc` 주기, `pid_start_proc` PI 시작, `fault_injection_proc` 기존 SW3 duty 자극, `drive_select_proc` duty 선택 |
| [safety_supervisor_rtl.vhd](safety_supervisor_rtl.vhd) | 3 | `classification_count_proc` 연속/전체 이상 횟수, `watchdog_count_proc` heartbeat 대기, `fault_latch_proc` 원인과 latch |
| [encoder_speed_rtl.vhd](encoder_speed_rtl.vhd) | 9 | `window_speed_comb_proc` 창 합/곱셈, `speed_limit_comb_proc` 속도 제한, `encoder_sync_proc`, `period_count_proc`, `window_count_proc`, `divider_request_proc`, `period_speed_proc`, `speed_snapshot_proc`, `speed_output_proc` |
| [unsigned_divider_rtl.vhd](unsigned_divider_rtl.vhd) | 1 | `divide_proc` 비트별 나눗셈 |
| [pid_controller_fsm.vhd](pid_controller_fsm.vhd) | 15 | 조합 계산 5개와 상태·레지스터 처리 10개. 아래 표에서 계산과 저장을 구분한다. |
| [encoder_quadrature_rtl.vhd](encoder_quadrature_rtl.vhd) | 7 | `phase_decode_comb_proc` 위상 전이표, `encoder_sync_proc`, `phase_tracking_proc`, `timeout_count_proc`, `direction_proc`, `position_proc`, `fault_status_proc` |
| [pwm_period_rtl.vhd](pwm_period_rtl.vhd) | 4 | `duty_scale_comb_proc` duty 환산, `pwm_output_comb_proc` 출력 비교, `period_count_proc` PWM 주기, `duty_latch_proc` 주기 시작 duty 저장 |
| [fault_latch_rtl.vhd](fault_latch_rtl.vhd) | 1 | `fault_count_proc` 연속 이상 latch |
| [reset_sync.vhd](../../common/reset_sync.vhd) | 1 | `reset_sync_proc` 비동기 인가/2클럭 동기 해제 |

### PI 계산과 저장

`*_comb_proc`는 입력이 바뀌면 계산하는 조합 회로다. `VARIABLE`은 한 계산을 단계별로
풀어 쓰기 위한 중간값이며, 클럭을 기다리는 레지스터를 추가하지 않는다.
클럭 프로세스는 FSM의 정해진 상태에서 계산 결과를 저장한다.

| 조합 프로세스 | 계산 | 저장하는 프로세스 |
|---|---|---|
| `proportional_term_comb_proc` | P항: Kp × 오차, Q16 소수점 조정 | `multiply_proc` |
| `integral_step_comb_proc` | 이번 적분 증가량: Ki × Ts × 오차 | `multiply_proc`가 하위 합을 저장 |
| `integral_sum_comb_proc` | 이전 적분 + 증가량. 하위 합과 carry를 이용해 상위 합 결합 | `multiply_proc` → `integral_candidate_proc` |
| `measurement_filter_comb_proc` | 측정값 변화의 1/4 필터 | `derivative_filter_proc` |
| `anti_windup_select_comb_proc` | 출력 한계를 더 벗어나게 하면 이전 적분 유지 | `integral_update_proc` |

나머지 클럭/상태 프로세스는 `clocked_proc`, `nextstate_proc`, `sample_input_proc`,
`proposed_output_proc`, `output_pipeline_proc`, `duty_output_proc`다.
적분 계산은 기존 `PRODUCTS` → `PRODUCTS_HI` 두 상태를 유지한다.
`derivative`는 필터 진단 출력이고, 실제 제어 계산의 D항은 기존처럼 0이다.

표기에 쓰인 `signed`는 부호 있는 수로 해석, `resize`는 값의 비트 폭 맞춤,
`shift_right`는 산술 우측 이동, `&`는 비트 연결을 뜻한다. 게인 곱에 대한 16비트 우측 이동은
Q16 소수점 조정이며, 음수에서도 원본의 내림 방향을 유지한다.

## 먼저 열어 볼 파일

1. [fourier_motor_struct.vhd](fourier_motor_struct.vhd): 모터 회로 전체 연결.
2. [motor_run_control_rtl.vhd](motor_run_control_rtl.vhd): 스위치부터 PI 시작과 duty 선택까지.
3. [pid_controller_fsm.vhd](pid_controller_fsm.vhd): `clocked_proc` → `nextstate_proc` → 각 계산 프로세스.
4. [axi_vibration_struct.vhd](axi_vibration_struct.vhd): AXI·FFT/NPU·SPI 전체 연결.
5. [vibration_core_fsm.vhd](vibration_core_fsm.vhd): FFT 시작부터 BRAM 결과 기록까지.

프로세스들은 같은 클럭에서 동시에 동작한다. 파일 위에서 아래로 차례대로 실행되는 것이 아니다.
클럭 프로세스의 `<=`는 해당 클럭의 이전 값을 읽고 값을 예약한다. 이 때문에 프로세스를 나눌 때
레지스터를 새로 넣지 않았고, 동시에 발생하는 clear/start/done의 우선순위도 유지했다.

## 학습용 단독 TB

| 파일 | 확인 항목 |
|---|---|
| [tb_reset_sync_vhdl.vhd](../tb_vhdl/tb_reset_sync_vhdl.vhd) | TC1 초기/비동기 리셋, TC2 두 클럭 해제, TC3 재인가 |
| [tb_mac_pe_vhdl.vhd](../tb_vhdl/tb_mac_pe_vhdl.vhd) | reset, clear 우선, signed 곱과 bias, hold, INT32 wrap |
| [tb_fft_npu_native_vhdl.vhd](../tb_vhdl/tb_fft_npu_native_vhdl.vhd) | 기존 20개 입력의 feature·hidden·logits·class와 NPU 18클럭 |

각 TB는 DUT/확인 항목 → 시간 상수 → 입력/출력 신호 → COMPONENT/binding → PORT MAP →
클럭 생성 → TC 자극/ASSERT 순서로 작성했다. 결과 메시지는 영어, 학습 주석은 한국어다.
입력과 기대값은 기존 `data/*.mem`을 읽는다.

전체 검증 명령과 검증 범위는 [VHDL 전환 기록](../../docs/VHDL_MIGRATION.md)에 정리한다.
현재 사용하는 비교 TB와 TC 구성은 [TB 안내](../tb_vhdl/README.md)를 따른다.
