# 화면·그래프·검증 자료의 출처

프로젝트 자료는 VHDL 구현 검증, 저장된 보드·routed 기록, MATLAB 기준 데이터,
분석 코드의 출력으로 구분한다. 각 그림은 아래 원본과 생성 절차에 연결한다.

## 1. 검증 대상과 날짜

| 대상 | 날짜·방법 | 자료 |
|---|---|---|
| VHDL RTL | 2026-11-15 XSim 13개 시험, 단위 합성·BD 검증 | [현재 소스의 검증 기록](evidence/readability_complete_2026-11-15/) |
| Verilog 참조 구현 | 2026-09-17 routed checkpoint와 회귀 로그 | [저장 보고서·로그](evidence/) |
| 보드 계측 | 2026-09-15~17 PWM·모터·센서 기록 | [계측 사진](../measurements/scope_captures_2026-09-15/) · [모터 CSV](../artifacts/experiments/) |
| MATLAB 정수 기준 모델 | 2026-09-17에 저장된 `.mat`·`.slx` | [기준 배열](evidence/2026-09-17_matlab_reference.mat) · [Simulink 모델](evidence/2026-09-17_fourier_npu_algorithm.slx) |
| 실측·6자유도 스터디 코드 | 독립 Python 수치 참조·정적 구문 검사 | [실측 코드](../tools/check_measured_replay.py) · [동역학 참조](../tools/check_research_reference.py) |

README의 Vivado/XSim 화면 캡처일은 2026-09-25다. 구현·시뮬레이션 결과의 생성일은 위 표를 따른다.

## 2. 이미지별 원본

| README 이미지 | 원본·생성 방법 | 표시 내용 |
|---|---|---|
| `npu_hardware_main.png` | 사용자 제공 대표 이미지 | Zybo·모터·전원·오실로스코프 구성 |
| `vivado_block_design.png` | 저장된 `system.bd`를 Vivado 2024.2에서 열어 캡처 | IP Integrator 연결 |
| `vivado_block_design.svg` | 같은 BD의 `write_bd_layout -format svg` 출력 | Vivado 벡터 도면 |
| `vivado_timing_summary.png` | 2026-09-17 참조 구현의 `impl_1`에 `report_timing_summary` 적용 | Routed WNS·WHS |
| `xsim_motor_safety.png` | 저장된 `tb_fourier_motor_behav.wdb`를 XSim에서 열어 캡처 | 참조 RTL의 분류·출력 제한·정지 파형 |
| `simulink_npu_verified_thumbnail.png` | 2026-09-17 `.slx`의 `metadata/thumbnail.png` | 저장된 정수 NPU 모델의 내장 미리보기 |
| `matlab_saved_fft.png` | MATLAB 기준 `.mat`과 동일 입력을 Python/Matplotlib으로 렌더링 | 원시 입력과 저장된 정수 FFT 결과 |
| `matlab_saved_npu_tensors.png` | 같은 `.mat`의 `expected_f/h/o`를 Python/Matplotlib으로 렌더링 | 실측 16개 입력의 feature·hidden·logits |
| `measured_python_preview_3d.png` | `tools/check_measured_replay.py` 출력 | 실측 X축의 평균 제거·rectangular DFT 크기 |
| JD1 PWM JPG 3장 | 2026-09-15 오실로스코프 원본 사진 | 50%·25% PWM과 latch 정적 LOW |
| `docs/architecture/*.svg`, `*.png` | VHDL 포트·PORT MAP·BD·XDC 기반 도면 | 모듈 계층·신호명·폭·방향 |
| `docs/state_diagrams/*.svg`, `*.png` | 상태 전이 추출과 프로세스 분석 | 핵심 FSM 4장과 시스템 동작도 7장 |

Mermaid와 모듈·상태 도면은 코드 구조를 설명하는 설계 자료다.
MATLAB 기준 그래프는 저장된 수치의 시각화이며, 내보내기 도구와 데이터 지문을 함께 제공한다.

## 3. 저장된 routed 보고서

기준은 2026-09-17 Verilog 참조 구현의 최종 저장 파일이다.

| 파일·항목 | 값 |
|---|---|
| `system_wrapper_routed.dcp` | 2026-09-17 구현 checkpoint |
| `system_wrapper_timing_summary_routed.rpt` | 2026-09-17 19:33:43 |
| `reports/fourier/timing.rpt` | 2026-09-17 19:34:22 |
| WNS / WHS | +0.091 ns / +0.020 ns |
| TNS / THS | 0.000 ns / 0.000 ns |
| LUT / register | 12,201 / 8,187 |
| BRAM tile / DSP | 1 / 8 |
| DRC | Error 0 / Warning 23 |

[GUI에서 재확인한 보고서](evidence/capture_timing_summary.rpt)도 같은 WNS·WHS를 기록한다.
단계별 값과 분석 과정은 [검증 이력](README_VALIDATION_HISTORY.md)에 보관한다.

## 4. Vivado·XSim 자료 열기

로컬 `build/` 결과가 있는 프로젝트에서 실행한다.

```tcl
open_project -read_only build/fourier/fourier.xpr
open_bd_design build/fourier/fourier.srcs/sources_1/bd/system/system.bd
write_bd_layout -force -format svg -orientation landscape docs/images/vivado_block_design.svg
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -name README_Timing_Summary
```

저장된 파형과 표시 설정은 다음과 같이 연다.

```tcl
open_wave_database -noautoloadwcfg build/fourier_sim/fourier_sim.sim/sim_1/behav/xsim/tb_fourier_motor_behav.wdb
open_wave_config docs/evidence/motor_safety_detail.wcfg
```

WCFG의 WDB 경로는 사용하는 작업 폴더에 맞춘다. 파형의 표시 신호·진법·확대 범위를 설정한다.
저장된 테스트벤치의 `clk` 주기는 10 ns이고 내부 `CLK_HZ=320000`은 축약 시간 설정이다.
보드의 실제 PWM 주기와 watchdog 지연은 원본 계측 자료의 시간축을 따른다.

## 5. MATLAB 기준 데이터와 그림 생성

정수 기준 `.mat`에는 실측 validation frame 16개와 산술 경계 입력 4개가 있다.
실측 그래프는 앞의 16개를, 전체 정수 비교는 20개를 사용한다.
산술 경계 입력은 영·최대 양수·최대 음수·impulse다.
독립 Python 정수 FFT/NPU와 저장 배열 전체를 비교해 수치 일치를 확인했다.

저장값 그래프 생성 도구는 Python/Matplotlib이다.

```bash
python3 tools/render_readme_npu_reference.py
```

MATLAB 분석 그림과 Simulink 블록 이미지는 전체 저장소에서 다음 순서로 내보낸다.

```matlab
RUN_MATLAB_CHECKS
RUN_MEASURED_STUDY
EXPORT_README_FIGURES
```

`EXPORT_README_FIGURES`는 실측 재생 비교와 입력·계산·출력 지문을 확인하고
`docs/images/matlab_exports/`에 PNG/FIG·Simulink 그림을 저장하도록 구성한다.
이 내보내기 함수의 검증 근거는 정적 구문 검사다.
실측 전용 ZIP의 시작점은 `RUN_MEASURED_STUDY`, 출력 폴더는 `reports/measured/`다.

## 6. 파일 지문

[Capture manifest](evidence/capture_manifest.json)는 원본 XPR/BD/DCP/WDB·보고서·MATLAB 기록·
대표 이미지·게시용 이미지의 SHA-256을 기록한다.
모듈·신호 도면은 [signal manifest](architecture/signal_manifest.json),
상태 도면은 [state manifest](state_diagrams/state_manifest.json)로 소스와 연결한다.
