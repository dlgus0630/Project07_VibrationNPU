# 스터디 코드의 주석을 읽는 순서

코드 안의 `%`는 설명 주석이며 계산에 사용되지 않는다. `% [주1]`처럼 번호가 붙은 부분은
그 파일에서 특히 헷갈리기 쉬운 내용을 설명하는 각주다. 번호는 **파일마다 새로 시작**한다.
먼저 함수 바로 아래의 목적·입력·출력을 읽고, 본문의 번호/단계 주석을 따라가면 된다.

## 1. 실측값으로 공부할 때

시작 파일은 [RUN_MEASURED_STUDY.m](../RUN_MEASURED_STUDY.m)이다.

| 읽는 순서 | 파일 | 여기서 알아볼 것 |
|---|---|---|
| 1 | [실측 진동 불러오기](../matlab/measured/load_measured_vibration.m) | 왜 원본 해시, 64개 샘플, 수집 순서를 확인하는가 |
| 2 | [실측 진동 분석](../matlab/measured/analyze_measured_vibration.m) | 원본 NPU 입력과 시각화용 평균 제거·PSD가 어떻게 다른가 |
| 3 | [정수 FFT](../matlab/fft64_fixed.m) | 비트 순서, butterfly, 매 단계 `/2`, signed 반올림 |
| 4 | [정수 NPU](../matlab/npu_int8.m) | 특징 4개 → 은닉값 4개 → 점수 2개 → 클래스 |
| 5 | [실측 Simulink 생성](../matlab/measured/build_measured_models.m) | 원본을 어느 블록에 넣고 어떤 중간값을 저장하는가 |
| 6 | [모터 기록 불러오기](../matlab/measured/load_measured_motor.m)와 [분석](../matlab/measured/analyze_measured_motor.m) | 실제 속도·PWM·적분 레지스터와 단위 환산 |

MATLAB에서 설명만 먼저 보려면 함수 경로를 추가한 후 `help`를 사용할 수 있다.

```matlab
addpath('matlab', fullfile('matlab','measured'))
help RUN_MEASURED_STUDY
help load_measured_vibration
help npu_int8
```

## 2. 가정한 물리식으로 공부할 때

[RUN_RESEARCH_STUDY.m](../RUN_RESEARCH_STUDY.m)은 질량·강성·감쇠를 가정하고 계산하는 별도 경로다.
실측 전용 ZIP에는 이 경로의 실행 코드가 포함되지 않으며 전체 프로젝트에서 볼 수 있다.

| 읽는 순서 | 파일 | 여기서 알아볼 것 |
|---|---|---|
| 1 | [파라미터](../matlab/research/vib3d_parameters.m) | 단위와 연구용 가정값 |
| 2 | [운동방정식](../matlab/research/vib3d_plant_matrices.m) | `M*qdd + C*qd + K*q = 힘/토크`와 지지대 위치의 영향 |
| 3 | [가진력](../matlab/research/vib3d_excitation.m)과 [시뮬레이션](../matlab/research/vib3d_simulate.m) | 정해 준 힘이 상태와 센서 출력으로 바뀌는 과정 |
| 4 | [주파수 분석](../matlab/research/vib3d_spectral.m)과 [종합 분석](../matlab/research/vib3d_analyze.m) | PSD, 고유진동수, 주파수 응답, 민감도 |
| 5 | [3D 재생](../matlab/research/animate_vibration_3d.m) | 물리 계산값과 화면 확대배율의 구분 |
| 6 | [자체 검사](../matlab/research/vib3d_self_test.m) | 정적 평형, 에너지, 샘플 간격 수렴을 확인하는 이유 |

## 3. 자주 보이는 기호와 연산

| 표현 | 쉽게 읽는 방법 | 코드에서의 의미 |
|---|---|---|
| `run` | 한 번의 독립 수집 실험 | 같은 실험의 이웃 윈도우를 학습/검증에 섞지 않는다 |
| `frame` / `window` | 한 번에 분석할 샘플 묶음 | 여기서는 X축 64개 값 |
| `x(:)` | 전부 한 열로 세우기 | 행/열 방향 때문에 행렬 곱이 달라지는 것을 막는다 |
| `mean(x,2)` | 각 행의 평균 | 각 64개 샘플 윈도우의 DC 성분 |
| `.^`, `.*` | 원소별 제곱/곱 | 행렬 곱 `*`와 구분한다 |
| `floor(v)` | 아래쪽 정수로 내림 | `floor(-1.5)=-2`; 0 방향 자르기와 다르다 |
| `max(lo,min(hi,v))` | 허용 범위 안으로 제한 | 정수 overflow 대신 포화 처리 |
| `RMS` | 제곱의 평균에 제곱근 | 부호가 바뀌는 진동의 평균적인 크기 |
| `logit` | 클래스별 최종 점수 | 확률이 아니며 여기서는 두 정수 점수를 비교한다 |
| `assert(...)` | 이 조건이 맞아야 진행 | 데이터/차원/계산이 예상과 다르면 즉시 오류를 낸다 |
| `SHA-256` | 파일 바이트의 지문 | 원본 파일이 바뀌었는지 확인한다 |
| `onCleanup` | 함수가 끝날 때 정리하기 | 오류가 나더라도 파일 등을 닫는다 |

## 4. 헷갈리기 쉬운 세 가지

**같은 raw를 쓰더라도 분석 경로가 다르다.** 정수 NPU에는 DC가 포함된 원본 64개를 넣는다.
그래프용 PSD는 각 윈도우 평균을 빼고 Hann 창을 적용한다. 창을 씌운 값을 NPU에 넣으면 기존
하드웨어와 다른 입력이 되어 재현 검사가 깨질 수 있다.

**시간의 뜻을 먼저 확인한다.** `dt_us`는 한 윈도우 내부의 기록된 샘플 간격이다.
`host_time_s`는 윈도우를 받은 호스트의 시각이며, 실측 재생 모델의 `tick`은 기록 순번이다.
모터 CSV의 `time_s`도 원래 수집 프로그램이 counter/100으로 만든 명목 시간이다.

**3D 축의 이름을 확인한다.** 실측 데이터의 3D 그림은 주파수·윈도우·스펙트럼 크기를 그린다.
가정 기반 연구의 3D 장면은 계산한 XYZ/회전 상태를 확대해 표시한다. 현재 실측 X축 하나로
실제 공간 변위나 Y/Z 궤적을 측정했다고 해석할 수 없다.

저장소 최상위 `matlab/`은 초기 통합 프로젝트의 함수들이며, 이 스터디의 기본 경로는
`Project07_VibrationNPU/matlab/`이다. 이름이 같은 함수가 있으므로 각 `RUN_*_STUDY` 진입점을
사용하는 편이 경로 혼동을 줄인다. `pid_sl.m`과 `plant_sl.m`의 주석도 각각 제어 연산과
모델 응답의 의미를 설명하지만, 이 실측 재생에서 새 모터 응답을 생성하는 데 쓰이지 않는다.
