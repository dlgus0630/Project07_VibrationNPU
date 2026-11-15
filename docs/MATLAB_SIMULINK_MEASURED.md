# MATLAB·Simulink 2차: 원본 실측 자료만 사용하는 재현 분석

이 경로는 실제 보드에서 보관한 센서·모터 기록을 MATLAB에서 분석하고 Simulink에서 그대로
재생한다. 이전 `RUN_RESEARCH_STUDY('all')`의 질량·강성·감쇠·편심 등 가정한 기계 파라미터,
합성 가진력, 가상 XYZ 센서와 별도이다. 실행 진입점은 **`RUN_MEASURED_STUDY`**다.

실측 X축 자료만으로 검증 가능한 결과를 먼저 만든다. 3차원 표현은 **주파수 × 수집 window ×
실측 기반 PSD [counts²/Hz]**의 waterfall이다. XYZ 변위나 모터의 6자유도 운동을 실제 측정한 것처럼
표현하지 않는다. 현재 원본에 Y/Z 가속도, 각속도, 변위 또는 자세 측정 열이 없기 때문이다.

## 1. 실행

MATLAB에서 이 프로젝트(`Project07_VibrationNPU`)를 현재 폴더로 정한다.

```matlab
report = RUN_MEASURED_STUDY;
```

기본 실행은 실제 진동 6개 run과 모터 5개 capture를 읽고, 분석 그림·CSV·MAT 자료 및 별도의
Simulink 재생 모델을 만든다. Simulink를 사용할 수 없으면 분석은 수행하고 모델 실행 상태를
`UNAVAILABLE`로 기록한다. MATLAB 분석과 그림에는 추가 DSP·Signal Processing·Statistics
Toolbox가 필요하지 않다. `.slx` 생성과 실행에는 **Simulink**가 필요하며, 원본의 SHA-256 검사는
일반 MATLAB 환경에 포함된 JVM을 사용한다.

MATLAB Online에서는 PC의 ZIP을 **파일 올리기**로 MATLAB Drive에 먼저 업로드한다.
로컬 작업 폴더의 파일은 MATLAB Drive에 자동으로 복사되지 않는다. 압축 해제 전
`dir('*.zip')`으로 현재 MATLAB 폴더의 실제 파일 이름을 확인한다.

이전 압축 해제 폴더를 가리키는 Simulink 캐시 설정이 남아 있으면 `getConfig`에서
폴더가 없다는 오류가 발생할 수 있다. 현재 프로젝트 폴더에서 아래 명령으로 경로를 지정한다.

```matlab
Simulink.fileGenControl('set', ...
    'CacheFolder', fullfile(pwd,'reports','measured','sim_cache'), ...
    'CodeGenFolder', fullfile(pwd,'reports','measured','sim_codegen'), ...
    'keepPreviousPath', false, 'createDir', true);
report = RUN_MEASURED_STUDY(struct('Visible','off'));
```

진입점도 이전 설정을 읽을 수 없으면 현재 스터디 폴더를 지정하도록 처리한다.
읽을 수 있었던 기존 설정은 실행 종료 후 복원한다.
설정 방법은 [MathWorks fileGenControl 문서](https://www.mathworks.com/help/simulink/slref/simulink.filegencontrol.html)를 따른다.

Simulink 없이 MATLAB 분석만 실행하려면 다음과 같이 한다.

```matlab
options = struct('BuildSimulink', false, 'IncludeMotor', true, 'Visible', 'off');
report = RUN_MEASURED_STUDY(options);
```

모터 기록을 제외하고 진동 실측만 분석할 수 있다.

```matlab
report = RUN_MEASURED_STUDY(struct('IncludeMotor', false));
```

배포용 파일은 `artifacts/matlab_measured_input.zip`이다. 압축을 풀어 프로젝트의
`RUN_MEASURED_STUDY.m`이 있는 폴더에서 실행한다. 출력은 `reports/measured`에 저장된다.
기존 연구 경로와 기존 golden 검증 스크립트는 별도로 유지한다.

ZIP은 기존 폴더와 구분되는 **`Project07_VibrationNPU_Measured/`**에 풀린다. 필요한 원본
CSV·JSON·실측 학습 가중치·MATLAB 코드가 함께 있으므로 MATLAB에서 추가 데이터 다운로드나
Python 실행은 필요 없다. 가정 기반 `matlab/research/`와 가상 plant 코드는 이 실행 패키지에
포함하지 않는다. 관련 연구 가이드 문서는 두 경로를 비교하기 위한 참고 자료로만 들어 있다.

| 출력 위치 | 내용 |
|---|---|
| `reports/measured/measured_vibration_replay.slx` | 실측 frame의 FFT/NPU 재생 모델 |
| `reports/measured/measured_motor_telemetry_replay.slx` | 모터 원본 telemetry 재생 모델 |
| `reports/measured/vibration` | 실측 진동 분석 CSV·MAT·PNG·FIG 및 run별 재생 결과 |
| `reports/measured/motor` | 모터 관측 통계 및 capture별 측정 곡선 |
| `reports/measured_offline` | MATLAB 없이 수행한 별도 Python 감사 결과 |

`.slx` 두 파일은 Simulink 생성이 성공했을 때 존재한다. Python 감사 산출물은 MATLAB 또는
Simulink 실행 결과를 의미하지 않는다.

Python 미리보기 `measured_preview_3d.png`는 직사각 창의 프레임별 진폭 스펙트럼(counts)을
사용하고, MATLAB의 `measured_spectrum_3d.png`는 periodic Hann PSD(counts²/Hz)를 사용한다.
두 그림의 세로축 단위와 창 정규화가 다르므로 높이를 직접 비교하지 않는다. 정수 NPU 입력은
두 경로 모두 원본 raw 값이며, 이러한 시각화용 처리를 거치지 않는다.

## 2. 무엇을 실제로 측정했는가

### 2.1 진동 센서 원본

수집 장치는 Zybo Z7-20과 MPU-6500이다. 원본 CSV는
`measurements/final_50pct/`에 있으며, 각 CSV와 같은 이름의 JSON이 수집 조건과 당시 bitstream·ELF의
해시를 기록한다. `data/dataset_source.json`이 각 원본의 SHA-256과 학습/검증 run 분리를 연결한다.

| 원본 run | 조건 label | windows | 원래 용도 |
|---|---:|---:|---|
| `normal_50_01` | 정상 0 | 60 | 학습 |
| `normal_50_02` | 정상 0 | 60 | 학습 |
| `normal_50_03` | 정상 0 | 60 | 검증 |
| `fault_ripple_01` | 주입 토크 리플 1 | 60 | 학습 |
| `fault_ripple_02` | 주입 토크 리플 1 | 60 | 학습 |
| `fault_ripple_03` | 주입 토크 리플 1 | 60 | 검증 |

전체는 **360 windows × 64 samples = 23,040개 X축 원시 ADC code**다. 수집 메타데이터의
설정은 ±2 g, 명목 1 kHz, 전원 12 V, duty 50%이다. 전원과 duty는 실험 설정 메타데이터이며
동시 수집한 전압·PWM 파형은 아니다. 정상/이상 label도 실험 조건 label이다. 따라서 이상 검출
결과가 증명하는 범위는 정상과 이 방법으로 주입한 토크 리플의 구분이다.

원본 열의 의미는 다음과 같다.

| 열 | 의미 | 처리 |
|---|---|---|
| `run_id`, `condition`, `label` | 수집 run 및 실험 조건 | 원래 값을 보존 |
| `window` | 해당 run의 window 번호 0~59 | 순서 보존 |
| `sample_index` | window 내부 순서 0~63 | 누락·중복·재정렬 검사 |
| `raw_x` | X축 int16 센서 code | 변형 없이 재생 |
| `dt_us` | window 내부 직전 sample과의 측정 간격 | 원본 64개를 함께 보존 |
| `host_time_s` | 해당 window 수신 완료 뒤 호스트가 기록한 시각 | window 메타데이터로만 사용 |

`raw_x`에 중력과 센서 offset이 포함될 수 있다. 원본 재생 및 정수 NPU 계산에서는 이를
제거하거나 진폭을 정규화하지 않는다. 스펙트럼 관찰을 위해 평균을 뺀 값은 별도 파생량이다.
기본 그래프 단위는 **sensor counts**이며, 보정 실험 없이 counts를 정밀한 SI 가속도로
해석하지 않는다.

### 2.2 모터 제어 원본

`artifacts/experiments/` 아래에서 다음 5개 CSV를 명시적으로 선택한다.

| 파일 | 행 수 | counter 기반 시간 범위 [s] | 기록 종류 |
|---|---:|---:|---|
| `open_loop_identification.csv` | 2,466 | 0~24.65 | 실제 open-loop duty 실험 |
| `step_original_gains.csv` | 2,486 | 0~24.85 | 원래 PI gain에서의 실제 응답 |
| `step_candidate_gains.csv` | 2,489 | 0~24.88 | 변경 PI gain에서의 실제 응답 |
| `disturbance_2026-09-16_v4_final.csv` | 5,970 | 0~59.69 | 실제 외란 시험 |
| `disturbance_2026-09-16_v5_repeat.csv` | 5,970 | 0~59.69 | 외란 반복 시험 |

이 파일명 중 `identification`이 있어도 이번 경로는 전달함수나 질량·관성 모델을 식별하지
않는다. duty와 encoder 속도 등 실제로 기록된 값만 재생한다. 외란 시험 기록에 전압 열이
없으므로 “12→9 V” 같은 전압 파형을 생성해 측정 입력으로 넣지 않는다.

모터 기록에는 물리 센서 측정값과 제어기 내부 관측값이 함께 있다. `measured_q12`는 encoder
기반 속도 추정 register이고, `reference_q12`는 속도 명령, `duty_q12`는 출력 duty 명령,
`integral_q12`는 PI 적분 register, `armed/fault/enabled`는 상태 bit다. 뒤의 세 가지는
별도 아날로그 센서 측정값이 아니다.

기존 수집 프로그램 `tools/capture_telemetry.py`의 단위 변환을 그대로 검사한다.

\[
\mathrm{RPM}_{\rm full}=\frac{1800\times60}{988.427},\qquad
\mathrm{RPM}=q_{12}\frac{\mathrm{RPM}_{\rm full}}{4096},\qquad
\mathrm{duty}[\%]=q_{12}\frac{100}{4096}.
\]

여기서 988.427은 원래 exporter의 CPR 값이다. 새로 추정한 기계 파라미터가 아니다.
CSV에 이미 저장된 `target_rpm`, `measured_rpm`, `duty_percent`를 이 식과 대조하고,
그림에는 **CSV에 저장된 변환값**을 사용한다. 단위 변환의 일치는 회전계로 RPM을 독립
교정했다는 의미와 다르다.

## 3. 시간축을 엄격하게 구분하기

### 3.1 진동 window 내부의 실제 간격

첫 sample의 `dt_us`는 0이다. 한 window의 상대 sample 시각은 다음과 같다.

\[
t_{j,0}=0,\qquad t_{j,n}=10^{-6}\sum_{k=1}^{n}\Delta t_{j,k}.
\]

6개 run의 63개 유효 간격을 모두 합친 평균은 **998.8286 μs**다. 역수는 약
1001.17 Hz이지만, FFT/NPU 구현은 명목 1 kHz를 계약으로 사용한다. 64개 sample의 첫 점부터
마지막 점까지는 63개 간격이다. 명목 FFT 관찰 구간 `N/fs = 64 ms`와 양 끝점 간격 `63/fs`
를 혼동하지 않는다.

`host_time_s`는 한 window의 64개 행에서 동일하다. `tools/capture_dataset.py`가 64개를 모두
수신한 다음 `time.time()`을 한 번 호출하기 때문이다. 인접 window의 host stamp 차이는
평균 약 **0.38402 s**다. UART 출력과 요청·수집 지연 등이 포함되므로 host 시각을 센서의
sample 동기 시각으로 사용할 수 없다. 두 window를 1 ms 간격으로 바로 이어 붙이면 존재하지
않는 연속 진동 기록이 만들어진다. 이 경로는 window 경계를 유지하고 그 공백을 채우지 않는다.

### 3.2 모터 time_s는 독립적인 실측 clock이 아니다

모터 CSV의 `time_s`는 exporter가 `sample/100.0`으로 만든 **sequence counter 기반 명목 시간**이다.
호스트 수신 시각이나 독립 측정한 sample 간격이 아니다. loader는 `sample` 및 `time_s`가
단조 증가하고 두 열이 이 관계를 만족하는지 확인한다. 누락 counter가 있으면 누락 수를
보고하고 원래 sample을 그대로 보존한다. 현재 선택한 5개 capture의 counter 누락은 0이다.

진동 원본과 모터 원본은 수집 날짜와 실험이 다르며 공통 trigger도 없다. 두 그림을 하나의
물리 시간축에 맞추거나, 진동 peak와 모터 속도 변화를 동시 발생한 인과 관계로 설명하지 않는다.

### 3.3 Simulink 시간은 재생 순서

재생 모델의 tick은 **물리적 1초가 아니라 하나의 원본 기록 단위**다. 진동 모델은 tick마다
원래의 64-sample frame 전체를 공급하고, 모터 모델은 tick마다 CSV의 한 행을 공급한다.
원래 `dt_us`, window 메타데이터, 모터 `time_s`/`sample`은 별도 데이터로 보존한다.

이 선택으로 Simulink solver가 측정되지 않은 중간 sample을 보간하거나, window 사이의
측정 공백을 이어 주는 일을 방지한다. Scope의 기본 simulation time은 재생 순서이며,
센서의 물리 시간 또는 FPGA 연산 latency를 뜻하지 않는다.

## 4. MATLAB 분석과 3차원 시각화

분석은 두 계산 경로를 분리한다.

1. **측정 신호 관찰**: 원본 counts, window 내부 시각, timing 품질과 window별 스펙트럼을
   그림으로 확인한다. 평균 제거와 창 함수를 쓰는 스펙트럼은 관측 자료로부터 계산한 파생량이다.
2. **기존 정수 구현 재현**: `fft64_fixed.m` 및 `npu_int8.m`에 원래 64개 code를 직접 넣는다.
   시각화 전처리 결과를 NPU 입력으로 대체하지 않는다.

64-point FFT의 명목 주파수 간격은 다음과 같다.

\[
\Delta f=\frac{1000}{64}=15.625\ \mathrm{Hz},\qquad
f_{\rm Nyquist}=500\ \mathrm{Hz}.
\]

3차원 그림의 축은 주파수 [Hz], **window 번호**, PSD [counts²/Hz]다. window 축을 연속 시간으로
해석하지 않는다. 각 곡선은 하나의 실제 64-sample window에서 계산된다. 이 방식은 어느
주파수 대역이 run 동안 강해지거나 변하는지 관찰하게 해 주며, 기계 구조물의 공간 좌표를
측정했다는 주장을 하지 않는다.

관측 길이가 짧기 때문에 가까운 주파수를 분해하는 데 한계가 있다. FFT zero padding을
해도 새로운 측정 정보나 주파수 분해능은 생기지 않는다. 32 Hz 주입 조건이 있다고 해서
모든 에너지가 정확히 32 Hz 한 점에 모이는 것도 아니다. 유한 window, leakage, 회전과
구동의 다른 성분 및 고정소수점 처리의 영향을 함께 해석해야 한다.

진단용 PSD는 각 frame에서 평균을 제거한 후 periodic Hann을 적용한다.

\[
u_n=x_n-\bar{x},\quad w_n=\tfrac12-\tfrac12\cos(2\pi n/N),\quad
P[k]=\frac{|\operatorname{FFT}(w_nu_n)[k]|^2}{f_s\sum_n w_n^2}.
\]

실수 신호의 단측 PSD로 만들 때 DC와 Nyquist를 제외한 bin은 2배 한다. 주파수 축은 명목
`fs=1000`이며, `dt_us` 변동을 보간하거나 비균일 Fourier 변환으로 보정한 결과가 아니다.
따라서 실제 평균 간격과 jitter 통계를 함께 보고한다. 서로 분리된 64-sample window의
periodogram을 그리는 것이므로 연속 긴 신호의 STFT라고 부르지 않는다.

`measured_raw_frames`는 각 run의 첫 frame과 원래 상대 시각, `measured_spectrum_3d`는
모든 window의 3차원 PSD, `measured_quality`는 DC·AC RMS·간격 변동·호스트 수신 간격,
`measured_confusion`은 학습/기존 검증을 분리한 혼동행렬이다. 그림은 PNG와 MATLAB에서
다시 열 수 있는 FIG로 저장된다. 수치 자료는 `measured_runs.csv`, `measured_windows.csv`,
`measured_spectra.csv`, `training_confusion.csv`, `existing_validation_confusion.csv`에 저장된다.

### 4.1 기존 FFT·NPU의 수식 계약

FFT butterfly는 단계마다 `/2`와 음의 무한대 방향 정수 나눗셈, int16 포화를 적용한다.
4개 특징은 DC를 제외한 FFT bin 집합 `[1..6], [7..12], [13..20], [21..31]`에서 계산한다.

\[
z_b=\min\!\left(127,\left\lfloor
\frac{\sum_{k\in B_b}(|R_k|+|I_k|)}{32}
\right\rfloor\right).
\]

이 값은 \(\sqrt{R_k^2+I_k^2}\) 진폭이나 PSD가 아니라 하드웨어에서 사용하는 정수 특징이다.
현재 `data/model.json`의 가중치·bias·shift를 읽어 4→4→2 추론을 수행한다.

\[
h=\operatorname{clip}_{[0,127]}\left(\left\lfloor\frac{W_1z+b_1}{2^{s_1}}\right\rfloor\right),
\quad \ell=\operatorname{clip}_{[-128,127]}\left(\left\lfloor\frac{W_2h+b_2}{2^{s_2}}\right\rfloor\right).
\]

class 1 판정은 \(\ell_1>\ell_0\)이며 동점은 class 0이다. logit은 softmax 확률이나 신뢰구간이
아니다. 이번 실행은 기존 실측 학습 모델을 다시 평가하며, 가중치를 새로 학습하지 않는다.

### 4.2 학습 결과와 검증 결과 구분

run 1·2는 학습, run 3은 원래 검증으로 분리한다. 가까운 window를 무작위로 섞어 검증 수를
늘리지 않는다. 현재 보관된 정수 모델의 기존 검증 기준은 **118/120 = 98.33%**, 혼동행렬은
실제 정상 60개 중 정상 58·이상 2, 실제 주입 토크 리플 60개 중 정상 0·이상 60이다.
이 숫자는 보관된 검증 run 120개 window와 현재 정수 모델의 재현 기준이다.

6개 run 전체를 재생하더라도 학습 240 windows의 정확도를 검증 120 windows와 합쳐서
일반화 성능으로 보고하지 않는다. 측정 당시 동일 조건의 window들은 서로 상관될 수 있으므로,
이를 독립적인 360번 실험으로 간주해 신뢰구간을 계산하는 것도 부적절하다.

### 4.3 모터의 관측 통계

`motor_measured_summary.csv`는 record 수, counter 명목 시간 범위, 누락 수, RPM 범위,
duty 평균·최대·포화 sample 수, fault 및 disabled sample 수를 기록한다. 추종 오차는
`armed=1`, `enabled=1`, `fault=0`, `reference_q12>0`인 **실제 기록 sample**에서만 계산한다.

\[
e_k=r_k-y_k,\qquad
\mathrm{RMSE}=\sqrt{\frac1M\sum e_k^2},\qquad
\mathrm{MAE}=\frac1M\sum |e_k|.
\]

이는 startup과 과도응답을 포함하는 sample 가중 기술 통계다. gain 비교에서 step 시점,
목표 변화량, 초기 조건과 분석 구간이 다르면 이 전체-run 값만으로 우열을 단정할 수 없다.
목표가 0으로 기록된 open-loop에는 추종 RMSE·MAE를 부여하지 않고 `NaN`으로 둔다.
적분 register 곡선은 기록된 내부 상태이며 식별한 적분기 모델의 출력이 아니다.

## 5. 별도의 Simulink 모델

생성되는 모델 이름은 다음과 같다.

| 모델 | 입력 | 계산/표시 |
|---|---|---|
| `measured_vibration_replay.slx` | 원본 X축 64개/frame | 정수 FFT 특징·NPU 재현, 원본 보존 비교 |
| `measured_motor_telemetry_replay.slx` | 원본 Q12/상태 7개 및 원본 CSV 환산값 3개/row | 실제 제어 기록 관찰 |

진동 모델은 기본으로 `normal_50_03`, 모터 모델은 `step_candidate_gains`를 저장한다.
전체 재생 검증에서는 진동 6개 run과 모터 5개 capture를 각각 실행한다. 모델 내부에는
가상 motor plant, 새 PI 응답 계산, 가상 fault/voltage source가 없다. 실제 `.slx` 파일은
MATLAB/Simulink에서 생성되는 실행 산출물이며, `.m` 확장자를 이름만 바꾼 파일이 아니다.

모터 raw source의 열 순서는 고정이다.

```text
[reference_q12 measured_q12 duty_q12 integral_q12 armed fault enabled]
```

이미 CSV에 저장된 단위 환산 source의 열 순서는 다음과 같다.

```text
[target_rpm measured_rpm duty_percent]
```

출력과 원본 입력의 정수 일치/순서 보존을 확인하는 것은 재생 배선과 계산 구현 검증이다.
실물 모터를 새로 운전한 시험 또는 진동과 PI의 물리적 폐루프 동작 시험을 대체하지 않는다.

모든 `From Workspace` 입력은 `Interpolate='off'`와
`OutputAfterFinalValue='Holding final value'`를 함께 지정한다. 기본 `Extrapolation`과
보간 끄기는 호환되지 않는다. 입력 배열은 원본 n개 기록, 재생 시각은 0..n-1이며
`StopTime=n-1`로 종료한다. 끝값을 복제한 추가 입력 행은 사용하지 않는다.
설정 근거는 [MathWorks From Workspace 문서](https://www.mathworks.com/help/simulink/slref/fromworkspace.html)다.

## 6. 재현성, 오류 처리, 검증 상태

진동 loader는 CSV/JSON 해시를 기존 source manifest와 대조하고, 각 run의 sample 순서,
64개 frame 길이, int16 범위, 기록된 timing과 실험 조건을 검사한다. 이어서 기존
`data/train_samples.csv`와 `data/val_samples.csv`가 해당 실측 run의 원래 분리·순서와 정확히
일치하는지 확인한다. 원본과 metadata 또는 split이 다르면 실행을 중단한다.

모터 loader는 지정한 5개 원본만 읽고 열 이름, 유한값, 정수 범위, 단조 counter와 명목 시간,
상태 bit, Q12와 RPM/duty 환산 일치를 검사한다. 각 원본의 SHA-256을 결과 표에 남긴다.
원본이 없거나 잘못됐을 때 가상 파형으로 대신 실행하지 않는다. SHA-256은 해당 파일의
동일성을 추적하며 센서 교정이나 실험 진실성을 자체적으로 인증하는 장치는 아니다.

이 작성 환경에는 MATLAB/Simulink 실행기가 없다. 따라서 Python 독립 감사 및 MATLAB
구문 검사의 통과와 실제 MATLAB 실행 성공은 구분한다. **실제 `.slx` 생성, 모델 compile,
`sim` 실행, 그래픽 렌더링은 사용자의 MATLAB 환경에서 확인해야 한다.** 실행 전인 상태를
MATLAB 실행 PASS로 기록하지 않는다.

작성 환경에서 수행한 검사는 새 MATLAB 파일 7개의 MISS_HIT 문법 검사, 실측 재현·변조 검출
Python 테스트 21개, 모터 5개 CSV의 19,381개 기록에 대한 열/단위/카운터 검사다. 원본 진동
360개 window와 기존 검증 118/120을 재현했고, ZIP을 임시 폴더에 다시 풀어 필요한 원본과
해시를 재검사했다. 자세한 실행 범위는 `reports/measured_offline/VALIDATION.md`에 기록한다.

실행 후에는 원본 hash와 360개 frame 보존, 학습/검증 분리 결과, 재생 비교 결과 및 출력 그림을
함께 검토한다. MATLAB 버전·Simulink 버전과 실행 로그를 연구 결과에 함께 보관하면 다른
환경에서 재현할 때의 차이를 추적할 수 있다.

관련 자료: [프로젝트 설계](../DESIGN.md), [실측 수집 도구](../tools/capture_dataset.py),
[모터 telemetry 수집 도구](../tools/capture_telemetry.py),
[기존 가정 기반 6자유도 연구 경로](MATLAB_SIMULINK_RESEARCH.md).
