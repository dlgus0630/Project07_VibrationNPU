# README 화면과 그래프의 출처

README는 실제 도구 캡처, 사용자 제공 대표 이미지, 저장 수치의 재시각화, 코드 구조 설명을 구분한다.
캡처일은 2026-09-25이며 구현·시뮬레이션·MATLAB 결과의 원래 생성일은 각 항목을 따른다.
이 문서의 구현 수치와 실물 시험 결과는 보존된 보고서·파형·계측 사진을 기준으로 한다.

## 1. 이미지별 원본

| README 이미지 | 원본과 만드는 방법 | 증거의 범위 |
|---|---|---|
| `npu_hardware_main.png` | 사용자가 첨부한 대표 이미지 원본을 그대로 복사 | 시스템 구성 소개. 표시 숫자를 이번 검증값으로 추출하지 않음 |
| `vivado_block_design.png` | 저장된 `build/fourier/.../system.bd`를 Vivado 2024.2에서 read-only로 열고 화면 캡처 | 실제 IP Integrator 연결 |
| `vivado_block_design.svg` | 같은 BD에서 `write_bd_layout -format svg`로 내보냄 | Vivado 원본 벡터 도면, 설명용 재작도 아님 |
| `vivado_timing_summary.png` | 최종 `impl_1`을 열고 `report_timing_summary` 실행 후 실제 화면 캡처 | 9월 17일 routed checkpoint의 WNS/WHS |
| `xsim_motor_safety.png` | 저장된 `tb_fourier_motor_behav.wdb`를 XSim에서 열고 신호와 확대 구간 선택 | 기존 RTL behavioral simulation의 이상 연속 판정·정지 |
| `simulink_npu_verified_thumbnail.png` | 9월 17일 `fourier_npu_algorithm.slx` 내부 `metadata/thumbnail.png` 그대로 추출 | 실제 저장된 기존 모델 미리보기, 새 GUI 캡처 아님 |
| `matlab_saved_fft.png` | 9월 17일 `matlab_reference.mat` + 동일 case 입력을 Python/Matplotlib으로 시각화 | MATLAB에 저장된 정수 기준값, 새 MATLAB 실행 아님 |
| `matlab_saved_npu_tensors.png` | 같은 `.mat`의 expected_f/h/o 중 실측 16개를 Python/Matplotlib으로 시각화 | feature·hidden·logits 정수 코드, 합성 경계 입력 4개는 그림에서 제외 |
| `measured_python_preview_3d.png` | `tools/check_measured_replay.py`의 실측 원본 검증 미리보기 복사 | 실제 X축의 평균 제거 rectangular DFT 크기, MATLAB Hann PSD와 다름 |
| JD1 PWM JPG 3장 | `measurements/scope_captures_2026-09-15/`의 기존 계측 사진 | 9월 15일 classifier latch 시험, 새 PI 실험 사진 아님 |

Mermaid 그림은 해당 코드의 연결과 처리 순서를 설명한 도식이다. Vivado/Simulink 화면 캡처로 표기하지 않는다.
새 실측·6자유도 MATLAB 경로는 실행 환경이 없어 `.slx` 생성·컴파일·시뮬레이션을 이번에 검증하지 못했다.

## 2. 최종 구현 수치 정정

기존 README에는 여러 빌드 단계의 값이 함께 들어 있었다. 현재 보존된 최종 파일을 기준으로 정리했다.

- `build/fourier/fourier.runs/impl_1/system_wrapper_routed.dcp`: 2026-09-17 구현 결과.
- 같은 run의 `system_wrapper_timing_summary_routed.rpt`: 2026-09-17 19:33:43.
- `reports/fourier/timing.rpt`: 2026-09-17 19:34:22.
- 위 결과의 WNS **+0.091 ns**, WHS **+0.020 ns**, TNS/THS **0.000 ns**.
- `reports/fourier/utilization.rpt`: **LUT 12,201 / register 8,187 / BRAM tile 1 / DSP 8**.
- `reports/fourier/drc.rpt`: **Error 0, Warning 23**.
- GUI에서 동일 checkpoint를 다시 보고한 `capture_timing_summary.rpt`도 WNS/WHS가 일치한다.

`+0.119/+0.030 ns`, `12,228/8,119`는 기존 문서에 남아 있던 값이며 현재 최종 결과 파일과 다르다.
이전 서술은 [README 이력](README_VALIDATION_HISTORY.md)에 보존했다.
`artifacts/timing.rpt`도 오래된 별도 결과이므로 현재 최종 보고서로 섞어 쓰지 않았다.
원본 보고서와 9개 테스트 로그는 [evidence](evidence/)에 바이트 변경 없이 복사했다.

## 3. 실제 Vivado 화면 다시 열기

로컬 `build/` 결과가 있는 환경에서 프로젝트 폴더를 기준으로 다음 Tcl을 사용한다.

```tcl
open_project -read_only build/fourier/fourier.xpr
open_bd_design build/fourier/fourier.srcs/sources_1/bd/system/system.bd
write_bd_layout -force -format svg -orientation landscape docs/images/vivado_block_design.svg
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -name README_Timing_Summary
```

파형은 저장된 결과를 정적으로 연다. 이는 회귀 테스트 재실행이 아니다.

```tcl
open_wave_database -noautoloadwcfg build/fourier_sim/fourier_sim.sim/sim_1/behav/xsim/tb_fourier_motor_behav.wdb
open_wave_config docs/evidence/motor_safety_detail.wcfg
```

WCFG에는 캡처 당시 WDB의 로컬 경로가 기록된다. 다른 컴퓨터에서는 Vivado에서 WDB 위치를 다시 지정한다.
표시 신호·진법·확대 범위만 조정했으며 파형 데이터를 변경하지 않았다.
테스트벤치 `CLK_HZ=320000`은 실행 시간을 줄이기 위한 파라미터이고 `clk`의 실제 생성은 10 ns 주기다.
이 테스트벤치 시간축을 실물의 PWM 주기나 watchdog 지연으로 해석하지 않는다.

FFT/NPU 전용 캡처를 위해 9월 14일의
`build/safety_extension_dev/safety_extension_dev.sim/sim_1/behav/xsim/tb_axi_behav.wdb`도
읽기 전용으로 확인했다. `/tb_axi/dut/core/` 아래 신호 이름은 있지만 내부 파형 값의 이력이
없고, 최상위 `clk`·`rdata` 등만 표시된다. 따라서 이를 내부 연산 파형 증거로 게시하지 않았다.
전용 파형은 현재 소스의 MATLAB gate를 갱신한 뒤 `tb_fft_npu`를 다시 실행하고,
`start`, `done`, `nstart`, `ndone`, `feat`, `hidden`, `logits`, `ncycles`를 기록해야 한다.
기존 9월 17일 회귀 PASS 로그와 이번에 실제로 캡처한 모터 파형은 그대로 보존한다.

## 4. MATLAB 그래프와 Simulink 내보내기

기존 MATLAB `.mat`의 20개 case는 독립 Python 정수 FFT/NPU와 비교해 모든 저장 배열의 일치를 확인했다.
이 비교는 MATLAB을 새로 실행했다는 뜻이 아니다.
`train_export.py`가 선택한 실측 validation frame 16개와 영·최대 양수·최대 음수·impulse의
산술 경계 시험 4개로 구성된다. 마지막 4개는 합성 테스트 벡터이며 실측 전용 replay에는 포함하지 않는다.

```bash
python3 tools/render_readme_npu_reference.py
```

실제 MATLAB 그래프와 새 Simulink 모델의 루트·하위 블록을 생성하려면 MATLAB/Simulink에서 실행한다.

```matlab
RUN_MATLAB_CHECKS
RUN_MEASURED_STUDY
EXPORT_README_FIGURES
```

이 순서는 실측 원본·Golden 소스·도구가 모두 있는 전체 저장소에서 실행한다. 실측 전용 ZIP은
`RUN_MEASURED_STUDY`를 실행해 `reports/measured/`의 그림을 사용하며, 연구 ZIP에는 실측 입력이 없다.

`EXPORT_README_FIGURES`는 실측 분석과 Simulink 정수 재생 비교가 성공한 상태를 확인한 후
`docs/images/matlab_exports/`에 PNG/FIG·블록 다이어그램·실행 상태를 저장한다.
최종 점검에서 입력·계산 소스·생성 출력의 SHA-256과 현재 Golden 검증 기록을 대조하도록 보강했다.
예전 성공 JSON에 출력 지문이 없거나 파일이 달라졌으면 위 검증 순서를 다시 실행해야 한다.
현재는 정적 구문 검사만 통과했고 실제 실행은 남아 있다.

## 5. 파일 지문

[파일 지문 manifest](evidence/capture_manifest.json)에 원본 XPR/BD/DCP/WDB, 보고서,
MATLAB 기록, 대표 이미지와 게시용 이미지의 SHA-256을 기록한다. 원본 파일·그림·캡션의 대응을 추적하기 위한
기록이며 현재 수정된 전체 소스가 과거 bitstream으로 다시 구현됐다는 의미는 아니다.
