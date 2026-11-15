# 6자유도 진동 모델과 FPGA 분류기를 연결하는 MATLAB·Simulink 연구 가이드

## 1. 구현 구성과 범위

이 프로젝트는 **6자유도 기계 모델, 3축 가속도 센서, 기존 정수 FFT/NPU, 3차원 재생**을 연결한다. 3차원이라는 말은 화면의 입체 표현에 더해, 하우징이 X/Y/Z 방향으로 이동하고
roll/pitch/yaw로 회전하며 센서의 위치와 고정 상태가 관측 신호를 바꾼다는 뜻이다. 따라서
“고정 상태 변화 → 전달함수 변화 → 주파수 대역 특징 이동 → 분류 결과 변화”를 수식과 영상으로
같이 설명할 수 있다. 기존 실험에서 센서 재고정이 결과를 바꿨던 사례와도 연결된다.

이 문서는 모델의 가정, 수식 유도, 수치 검증 코드와 결과 해석을 연결한다. 질량·관성·마운트
강성은 명시한 가정값이며, 계산한 가진과 센서 신호를 사용하는 합성 모델이다.

현재 구분해야 할 세 가지 층은 다음과 같다.

| 층 | 내용 | 근거와 사용 목적 |
|---|---|---|
| 기존 검증 기준선 | `RUN_MATLAB_CHECKS`, 정수 FFT/NPU, 실측 데이터와 RTL | 기존 FPGA 연산 계약과 재현성 확인 |
| 새 연구 모델 | 6자유도 하우징, 마운트, 외력, 센서, 주파수 해석 | 합성 신호에서 물리적 인과관계와 민감도 분석 |
| 3차원 재생 | 하우징·축·센서·궤적·시간 신호 표시 | 계산된 상태를 이해하고 발표 자료로 활용 |

**새 MATLAB/Simulink 연구 경로는 이 작업 환경에 MATLAB이 없어 실행 검증되지 않았다.** 아래
명령으로 사용자의 MATLAB에서 실행한 뒤 생성되는 결과를 확인해야 한다. 이 문서에는 아직 얻지
않은 연구 성능 수치나 MATLAB PASS를 기재하지 않는다. 기존 `matlab.pass`는 연구 모델의 통과
표시가 아니며, 새 연구 실행이 기존 검증 마커를 대신하지 않는다.

새 `.m` 및 도구 소스가 source digest에 포함되므로 기존 마커가 현재 소스와 일치한다고 가정하면
안 된다. 이 스터디는 과거 PASS 마커를 갱신하지 않는다. 현재 소스에 대한 기존 gate가 필요하면
MATLAB에서 `RUN_MATLAB_CHECKS`를 다시 실행한다. MATLAB 없이 수행한 문법 lint와 독립 Python
수식 비교는 별도 보조 검증이며 MATLAB/Simulink 실행 통과의 대체 근거가 아니다.

현재 배포된 `4 → 4 → 2` INT8 NPU는 실제 **X축** 정상/주입 토크 리플 데이터로 학습되어 있다.
3축을 생성해도 분류기 입력은 기존 X축 4개 특징이다. `unbalance`와 `misalignment`는 물리 자극
시나리오 이름이며 기존 NPU가 학습한 고장 클래스가 아니다. 자연 발생 베어링 고장이나 3축 일반화
성능을 주장하지 않는다.

## 2. 실행과 결과 확인

프로젝트 루트에서 다음과 같이 실행한다.

```matlab
cd Project07_VibrationNPU

% 기존 정수 연산/Simulink 기준선. 기존 진입점은 유지한다.
RUN_MATLAB_CHECKS

% 새 연구: 네 가지 시나리오, 계층형 Simulink 생성, 3D 재생.
RUN_RESEARCH_STUDY('all')

% 처음 구조를 살펴볼 때에는 한 가지 시나리오로 실행한다.
RUN_RESEARCH_STUDY('ripple')

% 그래픽 창과 Simulink 생성 없이 MATLAB 수치 해석을 실행한다.
opts = struct('BuildSimulink', false, 'Animate', false, ...
              'ExportVideo', false, 'Visible', 'off');
RUN_RESEARCH_STUDY('all', opts)

% 녹화는 표시 기능이 가능한 MATLAB 환경에서 별도로 사용한다.
opts = struct('BuildSimulink', true, 'Animate', true, ...
              'ExportVideo', true, 'Visible', 'on');
RUN_RESEARCH_STUDY('unbalance', opts)
```

주요 경로는 다음과 같다. 세부 그림/보고서 파일명과 실행 상태는 실행 후 출력 디렉터리에서
확인한다.

| 경로 | 용도 |
|---|---|
| `RUN_RESEARCH_STUDY.m` | 시나리오 실행과 결과 저장의 진입점 |
| `matlab/research/vib3d_parameters.m` | 단위가 있는 물리·센서·실험 파라미터 |
| `matlab/research/vib3d_plant_matrices.m` | 마운트 기하로부터 연속/이산 상태공간 생성 |
| `matlab/research/vib3d_excitation.m` | 시나리오별 힘·토크 생성 |
| `matlab/research/vib3d_simulate.m` | 6자유도 운동과 3축 센서 시계열 |
| `matlab/research/vib3d_analyze.m` | 모드·주파수 응답·스펙트럼·시간 통계 |
| `matlab/research/vib3d_spectral.m` | Toolbox 없이 계산하는 Welch PSD와 STFT |
| `matlab/research/vib3d_self_test.m` | 물리 행렬과 수치 적분의 자체 검증 |
| `matlab/research/build_research_model.m` | 계층형 Simulink 모델 생성 |
| `matlab/research/animate_vibration_3d.m` | 계산 결과를 이용한 3차원 재생 |
| `reports/research/<scenario>/` | 시나리오별 요약, PNG와 MAT 데이터 |
| `reports/research/vibration_npu_3d.slx` | 생성된 연구용 Simulink 모델 |

기본 연구 해석은 MATLAB 행렬 연산을 사용한다. Simulink 모델 생성/실행에는 Simulink가 필요하다.
3차원 표현은 MATLAB 그래픽이 담당한다. Simscape Multibody의 강체 조립 모델이나
Simulink 3D Animation의 외부 장면은 사용하지 않는다.

생성 후 모델을 직접 열려면 다음 명령을 사용한다. `.slx`에는 첫 시나리오의 행렬과 입력이
들어 있다. Simulink를 사용할 수 없으면 연구 보고서에 `UNAVAILABLE`로 남고 MATLAB 수치 경로를
실행할 수 있다.

```matlab
open_system(fullfile('reports','research','vibration_npu_3d.slx'))
```

물리 파라미터를 바꾸려면 `Parameters` 옵션을 사용한다. 기본 형상을 변경할 때는 질량과
관성, 마운트와 센서 위치도 물리적으로 일관되게 갱신해야 한다.

```matlab
addpath(fullfile('matlab','research'))
p = vib3d_parameters();
p.mount.stiffness(1,:) = 0.8*p.mount.stiffness(1,:);
opts = struct('Parameters',p,'BuildSimulink',true, ...
              'Animate',true,'MotionScale',30,'MaxFrames',240);
RUN_RESEARCH_STUDY('ripple',opts)
```

기본 출력 디렉터리가 같은 시나리오 이름을 사용하므로 파라미터 비교 시 각 실행의 결과를
별도 디렉터리에 보관한다. 아래 하위 함수 호출은 기계 해석만 별도 저장하는 예다.

```matlab
addpath('matlab', fullfile('matlab','research'))
p = vib3d_parameters();
p.mount.stiffness(1,:) = 0.8*p.mount.stiffness(1,:);
plant = vib3d_plant_matrices(p);
selfTest = vib3d_self_test(p);
input = vib3d_excitation(p, 'ripple');
result = vib3d_simulate(p, input);
outdir = fullfile('reports','research','mount1_80percent');
analysis = vib3d_analyze(p, plant, result, outdir);
save(fullfile(outdir,'custom_run.mat'), 'p','input','result','selfTest')
animation = animate_vibration_3d(result, p, outdir, ...
    struct('visible','on','exportVideo',false,'motionScale',30));
```

상위 진입점 옵션은 `Visible`, `ExportVideo`처럼 대문자로 시작하고, 3D 함수의 직접 호출
옵션은 `visible`, `exportVideo`처럼 소문자로 시작한다. NPU 프레임 분석까지 포함하는 표준
경로는 `RUN_RESEARCH_STUDY`를 사용한다. MATLAB Online으로 옮길 때는 연구 코드와 데이터를
포함하는 `artifacts/matlab_research_input.zip`을 이용할 수 있다.

실행 후 먼저 `reports/research/research_run_status.json`에서 어떤 경로를 실행했는지 확인하고,
시나리오의 `run_summary.json`과 아래 자료를 읽는다. MATLAB 수치 경로의 성공과 Simulink
사용 불가 상태를 구분한다.

| 결과 | 읽을 내용 |
|---|---|
| `results.mat`, `physical_analysis.mat` | 파라미터·물리 상태·센서·분석 객체를 재검토 |
| `time_history.csv`, `axis_metrics.csv` | 단위가 있는 원시 시계열과 축별 통계 |
| `modal_properties.csv`, `state_poles.csv` | 비감쇠 모드/투영 감쇠와 실제 감쇠 극 비교 |
| `welch_psd.csv`, `spectral_metadata.csv` | PSD와 창 길이·hop·ENBW |
| `force_to_sensor_accel_frf.csv` | 기본 CG의 X방향 단위 힘에 대한 센서 XYZ 복소 FRF |
| `parameter_sensitivity.csv` | 질량·강성·감쇠의 기본 0.8/1.0/1.2배 변화 |
| `pipeline_frames.csv`, `safety_observer.csv` | 프레임별 정수 추론과 안전 상태 관찰 |
| `response_and_orbit.png`, `spectra_frf_energy.png` | 시간응답·궤적·PSD·FRF·에너지 |
| `stft_rotor_orders.png`, `six_rigid_body_modes.png` | 1×/2× rotor order와 6개 모드 형상 |
| `modal_parameter_sensitivity.png`, `inference_and_policy.png` | 파라미터 민감도 및 분류/정책 시간 흐름 |
| `vibration_3d_<scenario>.png` | 질량중심 병진 크기가 최대인 시각의 3D 장면 |
| 상위 `self_tests.mat`, `comparison.csv`, `scenario_comparison.png` | 자체 검증과 시나리오 간 비교 |

## 3. 좌표계, 상태, 단위

하우징 질량중심에 기준 좌표계의 원점을 둔다. 평형 자세에서 X축은 축방향, Y/Z는 횡방향으로
정의한다. 양의 회전은 오른손 법칙이다. 상태의 정의는

\[
q=\begin{bmatrix}x&y&z&\phi&\theta&\psi\end{bmatrix}^{T},\qquad
z_s=\begin{bmatrix}q^T&\dot q^T\end{bmatrix}^{T}\in\mathbb R^{12}.
\]

여기서 \(\phi,\theta,\psi\)는 각각 X/Y/Z축에 대한 작은 회전이다. 상태 벡터 \(z_s\)의 이름은
병진 좌표 \(z\)와 구별하기 위한 수학 기호이며 소스코드 변수명과 반드시 같지는 않다.

| 양 | 단위 | 해석 시 주의 |
|---|---|---|
| \(x,y,z\), 센서/마운트 위치 | m | 그림의 mm/µm 표시와 구분 |
| \(\phi,\theta,\psi\) | rad | 도 단위는 표시할 때만 변환 |
| 질량 \(m\), 관성 \(J\) | kg, kg·m² | 관성은 질량중심 기준 |
| 힘 \(F\), 모멘트 \(\tau\) | N, N·m | 모멘트의 기준점 명시 |
| 마운트 강성 \(K_i\), 감쇠 \(C_i\) | N/m, N·s/m | 조립된 6×6 행렬은 병진·회전 혼합 단위 |
| 가속도 \(a\) | m/s² 또는 g | \(1\,g=9.80665\,\mathrm{m/s^2}\) |
| 센서 raw | count | ±2 g 설정에서 16384 count/g |
| PSD | (m/s²)²/Hz 또는 g²/Hz | 입력 신호의 단위에 종속 |

전체 6×6 강성 행렬의 모든 원소를 N/m로 표기하면 안 된다. 병진-병진 부분은 N/m,
회전-회전 부분은 N·m/rad, 병진-회전 결합 부분은 그에 대응하는 혼합 단위를 갖는다. 수치
condition number를 비교할 때도 길이와 각도의 좌표 스케일을 지정해야 한다.

기본 파라미터는 다음과 같다. 모두 하우징 모델의 **예시값**이며 기존 모터 실측값으로
동정했다는 뜻은 아니다.

| 항목 | 기본 설정 |
|---|---|
| 관측 길이 / 난수 seed | 8 s / 7307 |
| 하우징 질량 / 외형 | 0.62 kg / 0.120 × 0.065 × 0.060 m |
| 마운트 위치 | X=±0.045 m, Y=±0.025 m, Z=−0.040 m의 네 조합 |
| 각 마운트 기준 강성 | local XYZ = [1800, 2100, 2700] N/m |
| 각 마운트 기준 감쇠 | local XYZ = [2.1, 2.3, 2.8] N·s/m |
| 마운트별 강성/감쇠 배율 | [1.00, 0.94, 1.08, 1.02] |
| 마운트 local yaw | [15, −15, −12, 12]° |
| 센서 위치 / 힘 작용 위치 | [0.036, 0.015, 0.030] m / [0.040, 0, 0.008] m |
| prescribed rotor 속도 | 1400→1800 rpm, 1 s smooth ramp, 0.7 Hz에서 ±8 rpm 변조 |
| 편심량 \(m_e e\) | 정상 0.5×10⁻⁶ kg·m, 불평형 7×10⁻⁶ kg·m |
| 센서 잡음 / 바이어스 | 축당 σ=0.006 m/s² / [0.002, −0.001, 0.003] m/s² |
| 정적 통계에서 제외하는 초기 구간 | 0…2 s |

prescribed rotor rpm은 시뮬레이션 외부 입력이다. 기존 기어모터 출력축의 실측 rpm과 연결되는
기어비나 축 동역학을 이 기본값에서 추론하지 않는다.

## 4. 마운트 기하에서 운동방정식까지

### 4.1 한 마운트의 변위와 에너지

질량중심에서 i번째 마운트까지의 평형 위치를 \(r_i\in\mathbb R^3\)라 한다. 외적 행렬을

\[
[r_i]_\times=\begin{bmatrix}
0&-r_{iz}&r_{iy}\\r_{iz}&0&-r_{ix}\\-r_{iy}&r_{ix}&0
\end{bmatrix},\qquad [r_i]_\times v=r_i\times v
\]

로 두면 작은 회전에 대한 마운트 변위는

\[
d_i=u+\vartheta\times r_i=S_iq,\qquad
S_i=\begin{bmatrix}I_3&-[r_i]_\times\end{bmatrix},
\quad u=[x,y,z]^T,\ \vartheta=[\phi,\theta,\psi]^T.
\]

이 부호는 중요하다. \(\vartheta\times r_i=-r_i\times\vartheta\)이므로 \(S_i\) 오른쪽에
마이너스 부호가 붙는다. 마운트가 자체 좌표계에서 대각 강성 \(K_i^{loc}\)을 갖고 설치 회전이
\(R_i\)라면 전역 강성은 \(K_i=R_iK_i^{loc}R_i^T\)이다. 감쇠도 같은 방법으로 변환한다.
마운트가 전역 축에 정렬된 기본 모델에서는 \(R_i=I\)로 볼 수 있다.

탄성 에너지와 Rayleigh 소산함수는

\[
V_i=\tfrac12q^TS_i^TK_iS_iq,\qquad
\mathcal D_i=\tfrac12\dot q^TS_i^TC_iS_i\dot q.
\]

따라서 조립된 행렬은

\[
M=\begin{bmatrix}mI_3&0\\0&J\end{bmatrix},\qquad
K=\sum_i S_i^TK_iS_i,\qquad C=\sum_i S_i^TC_iS_i.
\]

질량중심이 원점이고 주관성축을 택했을 때 \(J\)는 대각이다. 균질 직육면체 근사에서는 길이
\(l_x,l_y,l_z\)에 대해 \(J_{xx}=m(l_y^2+l_z^2)/12\) 등을 사용한다. 실제 모터와 브래킷은
균질 직육면체가 아니므로 이 관성값은 모델의 근사 가정값이다.

### 4.2 결합 항의 물리적 의미

\(K\)와 \(C\)의 대각 밖 원소는 마운트 위치와 비대칭성 때문에 생긴다. 예를 들어 질량중심 아래의
마운트에 X방향 힘이 작용하면 X병진과 pitch가 함께 생길 수 있다. 6개의 독립 스프링을 나열한
모델보다 이러한 결합이 센서 위치에 따른 가속도 차이를 설명하는 데 유용하다.

마운트 간 대칭성을 정확하게 지정한 경우 일부 결합 항은 상쇄된다. 이것은 모델 누락이 아니라
기하의 결과이다. 마운트 강성의 비대칭은 결합 항을 바꾸고 모드 방향과 주파수 응답에 영향을 준다.

### 4.3 일반화된 힘과 운동방정식

질량중심에서 \(r_f\)만큼 떨어진 지점의 힘 \(F\)는

\[
w=\begin{bmatrix}F\\r_f\times F+\tau_{direct}\end{bmatrix}\in\mathbb R^6
\]

로 변환한다. 위 마운트 에너지에서 Lagrange 방정식을 적용하면

\[
\boxed{M\ddot q+C\dot q+Kq=w(t)}.
\]

모델은 중력 하중을 받은 정적 평형점 주변의 진동이다. 기본 방정식에 중력 정하중을 다시 넣으면
평형 변위를 이중 반영할 수 있다. 현재 구현은 고정된 마운트 기준의 힘·모멘트 가진을 사용한다.

## 5. 연속 상태공간과 1 ms 이산화

상태방정식은

\[
\dot z_s=A_cz_s+B_cw,\qquad
A_c=\begin{bmatrix}0&I\\-M^{-1}K&-M^{-1}C\end{bmatrix},\qquad
B_c=\begin{bmatrix}0\\M^{-1}\end{bmatrix}.
\]

코드에서는 역행렬을 직접 계산하기보다 `M\K`, `M\C`, `M\eye(6)`과 같은 선형방정식 풀이를
사용한다. 가속도 출력은

\[
\ddot q=C_a z_s+D_aw,\quad
C_a=\begin{bmatrix}-M^{-1}K&-M^{-1}C\end{bmatrix},\quad D_a=M^{-1}.
\]

힘은 각 샘플 구간에서 일정하다고 가정한다. \(T_s=1/f_s=0.001\,s\)의 ZOH 이산화는

\[
\exp\left(\begin{bmatrix}A_c&B_c\\0&0\end{bmatrix}T_s\right)
=\begin{bmatrix}A_d&B_d\\0&I\end{bmatrix},\qquad
z_{s,k+1}=A_dz_{s,k}+B_dw_k.
\]

이 방식은 ZOH 가정 아래 선형 상태방정식을 정확히 전파한다. “수치 적분 오차가 없다”는 말은
연속 외력의 샘플링 근사, 파라미터 오차, 선형화 오차까지 없다는 뜻이 아니다. 행렬 지수 이산화와
전진 Euler의 안정성을 혼동하지 않는다.

Simulink의 Discrete State-Space 블록은 \(x_{k+1}=Ax_k+Bu_k\),
\(y_k=Cx_k+Du_k\)를 구현한다. 따라서 MATLAB 루프와 동일한 초기 상태, 입력 인덱스, 출력식을
사용하여 비교할 수 있다. 블록의 출력이 현재 상태와 현재 입력에서 계산된다는 점을 기준으로
샘플 정렬을 확인한다. [MathWorks: Discrete State-Space](https://www.mathworks.com/help/simulink/slref/discretestatespace.html)

## 6. 센서 위치, 회전과 INT16 양자화

### 6.1 3축 센서의 측정식

센서 위치를 \(r_s\)라 두면 정확한 강체 가속도에는

\[
a_s=\ddot u+\alpha\times r_s+
\omega\times(\omega\times r_s)
\]

가 포함된다. 작은 하우징 진동의 선형 모델에서는 마지막 항이 회전 속도의 이차항이므로 생략해

\[
a_s\simeq S_s\ddot q,\qquad S_s=[I_3\ -[r_s]_\times]
\]

로 계산한다. 센서가 질량중심에서 멀어질수록 회전 가속도 항이 커진다. 따라서 센서 위치만 바꿔도
같은 물체 운동에서 얻는 X/Y/Z 스펙트럼이 달라질 수 있다.

가속도계는 원칙적으로 specific force를 측정한다. 센서 좌표계로의 회전을 \(R_{sb}\)라 하면

\[
f_s=R_{sb}(a_s-g_b).
\]

정지 상태의 ±1 g 부호는 센서 축 방향과 중력 벡터의 정의에 따라 결정한다. 구현은 Z위쪽인
평형 자세를 기준으로 다음 1차 근사를 사용한다.

\[
f_s\simeq a_s+[-g\theta,\ +g\phi,\ g]^T.
\]

따라서 영자세·영동적가속도·무잡음·무바이어스에서 raw 값은 `[0, 0, 16384]`이다.
`result.accel`은 \(a_s\), `result.specific_force`는 위 중력 투영을 포함한 신호,
`result.measured_specific_force`는 여기에 잡음·바이어스를 더한 신호다. PSD의 기본 대상은
`accel`이며, NPU 입력은 `raw(:,1)`이므로 두 신호의 차이를 구분한다. 동적 가속도의 센서
회전에 의한 곱항과 구심 가속도는 이차항으로 생략한다. 3D 표시용 확대 회전각을 이 식에 넣으면
가짜 센서 신호가 발생하므로 사용하지 않는다.

### 6.2 센서 전자계와 포화

센서 잡음과 바이어스를 포함한 가속도를 \(a_{g,j}\) [g]라 할 때 raw 변환은

\[
r_j=\operatorname{sat}_{[-32768,32767]}
\left(\operatorname{round}(16384\,a_{g,j})\right),\qquad j\in\{X,Y,Z\}.
\]

1 LSB는 \(1/16384\,g\)이다. 상단 코드는 비대칭이므로 +2 g는 signed INT16에 정확히 표현되지
않는다. 포화율을 함께 보고하여 큰 가진에서 스펙트럼 변화가 물리 응답인지 클리핑의 고조파인지
구별한다. `double`로 저장된 정수값도 값의 범위와 반올림 규칙이 같으면 기존 정수 golden의
입력으로 사용할 수 있다.

백색 잡음의 표준편차를 샘플마다 지정하는 모델과 datasheet의 noise density [g/√Hz]는 동일하지
않다. 후자를 사용할 때는 아날로그/디지털 필터의 equivalent noise bandwidth를 통해 샘플 분산으로
환산해야 한다. 기본 합성 잡음은 실물 MPU의 DLPF, 축간 감도, 온도 드리프트, SPI 지터 전체를
재현하지 않는다.

## 7. 가진 시나리오를 해석하는 방법

| 시나리오 | 물리적으로 관찰할 내용 | 분류 결과의 의미 |
|---|---|---|
| `normal` | 작은 회전 동기 가진과 잡음 아래 기본 응답 | 합성 정상의 X특징이 기존 학습 분포에 들어가는지 |
| `unbalance` | 회전 동기 횡방향 힘, 궤적의 방향과 위상 | 기존 NPU의 미학습 자극에 대한 반응 |
| `misalignment` | 축방향/횡방향 조화 가진 및 모멘트의 변화 | 불정렬 진단 정확도로 해석하지 않음 |
| `ripple` | 32 Hz 계열 토크 리플 가진의 응답과 대역 특징 | 합성 리플 입력에 대한 기존 분류기의 반응 |

기본 가진의 세부 진폭, 회전 주파수와 램프는 `vib3d_parameters.m` 및
`vib3d_excitation.m`을 기준으로 한다. 그 값은 실측 동정치라는 근거가 없는 한 연구용 설정이다.
기본 시나리오는 같은 seed, 배경 잡음과 초기조건을 사용하므로 가진 차이에 따른 응답을 비교한다.

현재 네 시나리오의 가진은 각 기록의 시작부터 존재한다. 초기 2초를 제외하는 기본 분석은
영초기조건과 속도 램프의 과도를 줄이기 위한 것이다. 기본 `ripple` 가진은
\(s(t)=\sin(2\pi32t)+\sin(2\pi96t)/3+\sin(2\pi160t)/5\)에 X힘 0.30 N과 X토크
0.0035 N·m의 계수를 곱해 더한다. 제한된 홀수 조화 성분으로 만든 파형이며 실물 PWM 전환의
고주파 성분 전체를 합성하지 않는다.

불평형 가진은 다음 관계로 계산한다. 편심 질량 \(m_e\), 편심 거리 \(e\), 회전속도
\(\Omega\)에 의한 불평형력 크기는 \(m_e e\Omega^2\)이다. 축이 X일 때 횡방향 회전력의 한
표현은

\[
F_y=m_e e\Omega^2\cos(\gamma),\qquad
F_z=m_e e\Omega^2\sin(\gamma).
\]

회전속도가 시간에 따라 변하면 위상은 \(\gamma(t)=\int_0^t\Omega(\tau)d\tau+\gamma_0\)로
적분해야 한다. \(\Omega(t)t\)를 그대로 위상으로 쓰면 순간주파수가 달라진다. 구현의 속도 램프
구간에서는 위 원심력 외에 각가속도 반력 \(m_e e\dot\Omega[\sin\gamma,-\cos\gamma]^T\)도
YZ힘에 포함한다. 불정렬의 1×/2×
조화 자극은 현상을 비교하기 위한 간략화이지 축·커플링 접촉 비선형 전체의 해석은 아니다.

실물의 25%↔75% PWM 명령은 그 자체로 N·m 단위의 토크가 아니다. 전기자, 역기전력, 부하, 속도
제어기를 거쳐 실제 토크가 된다. 이 연구 모델에서 prescribed force/torque를 넣는 경우,
실물 duty 파형과의 진폭 동등성을 주장하지 않는다. 32 Hz 주파수가 같다는 것만으로 전달 경로가
보정된 것은 아니다.

## 8. 모드 해석과 주파수 응답

### 8.1 모드와 감쇠

비감쇠 고유치 문제는

\[
K\phi_i=\omega_i^2M\phi_i,\qquad f_i=\omega_i/(2\pi).
\]

질량 정규화 \(\phi_i^TM\phi_i=1\)을 사용하면 각 모드의 상대적인 병진/회전 성분을 비교할 수
있다. 모드 벡터 부호 자체는 임의이므로 MATLAB 버전 또는 알고리즘이 바뀌어 그림의 방향이
뒤집혀도 물리 오류가 아니다. 서로 가까운 모드는 개별 벡터보다 부분공간으로 비교해야 한다.

일반 감쇠에서는 \(A_c\)의 복소극 \(\lambda_i\)로부터
\(\omega_{n,i}=|\lambda_i|\), \(\zeta_i=-\Re(\lambda_i)/|\lambda_i|\)를 계산할 수 있다.
\(\phi_i^TC\phi_i/(2\omega_i\phi_i^TM\phi_i)\)는 모드별 감쇠의 편리한 근사이지만,
비비례 감쇠에서 모드 간 결합을 제거하는 정확한 대각화라고 해석하면 안 된다.

### 8.2 FRF와 센서 가시성

입력 방향 \(b\)에 대한 변위 전달함수와 센서 가속도 전달함수는

\[
H_q(j\omega)=(-\omega^2M+j\omega C+K)^{-1}b,\qquad
H_a(j\omega)=-\omega^2S_sH_q(j\omega).
\]

힘 입력의 \(H_a\) 단위는 (m/s²)/N이며 모멘트 입력일 때는 (m/s²)/(N·m)이다. 입력 종류를
생략한 FRF 축 표시는 피한다. 센서가 어떤 모드의 절점에 가까우면 구조물에는 모드가 존재해도
특정 축에서는 거의 보이지 않을 수 있다. “PSD에서 peak가 없음 → 해당 모드가 없음”으로
단정할 수 없는 이유다.

연속 FRF는 물리 모델을 해석하는 데 쓰고, 이산 시뮬레이션과 엄밀하게 비교할 때에는
\(C_d(e^{j\omega T_s}I-A_d)^{-1}B_d+D_d\)를 사용한다. 샘플링과 입력 ZOH의 영향 때문에
Nyquist 부근에서 연속 FRF와 이산 응답을 동일시하면 안 된다.

## 9. 신호 처리: 연구용 스펙트럼과 배포용 특징

### 9.1 기존 FFT/NPU 계약

\(f_s=1000\,Hz\), \(N=64\)이므로 프레임 길이는 64 ms, FFT bin 간격은 15.625 Hz이다.
첫 프레임이 \(t=0\) 샘플에서 시작하면 64번째 샘플 시각은 63 ms이고, 다음 프레임 완료와의
간격은 64 ms이다. “프레임 길이”와 배열의 마지막 time stamp를 구분한다.

| 특징 | 0-based FFT bin | 1 kHz에서 bin 중심 주파수 |
|---|---|---|
| band 0 | 1…6 | 15.625…93.750 Hz |
| band 1 | 7…12 | 109.375…187.500 Hz |
| band 2 | 13…20 | 203.125…312.500 Hz |
| band 3 | 21…31 | 328.125…484.375 Hz |

정수 FFT는 radix-2 각 단계에서 1/2 스케일링하므로 최종 값은 대략 \(FFT(x)/64\)에 해당한다.
정확한 비교에서는 단계마다 수행되는 floor와 INT16 포화를 포함해야 한다. 특징은

\[
f_b=\min\left(127,\left\lfloor
\frac{\sum_{k\in\mathcal B_b}(|\Re X_k|+|\Im X_k|)}{32}
\right\rfloor\right).
\]

이는 \(|X_k|^2\)를 더하는 물리적 power/energy와 다르다. 보고서에서 “대역 특징”과 “대역
파워”를 혼용하지 않는다. DC와 Nyquist bin은 이 네 특징에 포함되지 않는다. 배포 입력에 Hann
배포 추론은 창, 프레임별 평균 제거, 벡터 크기 \(\sqrt{x^2+y^2+z^2}\) 변환 없이
기존 X축 정수 입력 계약을 유지한다.

NPU는

\[
h=\operatorname{clip}_{[0,127]}\!\left(\left\lfloor
(W_1f+b_1)/2^{s_1}\right\rfloor\right),\quad
\ell=\operatorname{clip}_{[-128,127]}\!\left(\left\lfloor
(W_2h+b_2)/2^{s_2}\right\rfloor\right).
\]

\(\ell_1>\ell_0\)일 때 class 1, 동점은 class 0이다. logit 차이는 판정 여유를 관찰하는 값이며
보정된 고장 확률이 아니다. 정수 포화가 발생한 logit의 차이를 softmax 확률처럼 제시하지 않는다.

### 9.2 Welch PSD와 STFT

연구용 긴 기록에는 평균 제거 후 창을 적용하여 PSD와 STFT를 계산한다. 길이 \(L\)의 구간
\(x_m[n]\), 창 \(w[n]\), \(U=\sum_n w[n]^2\)에 대해 양측 periodogram의 밀도는

\[
P_m[k]=\frac{|\sum_{n=0}^{L-1}w[n]x_m[n]e^{-j2\pi kn/N_{FFT}}|^2}{f_sU},
\qquad \widehat P[k]=\frac1{M_s}\sum_mP_m[k].
\]

실수 신호의 단측 PSD는 DC와 존재하는 Nyquist bin을 제외한 양의 주파수 값을 두 배로 한다.
주파수 적분값이 평균 제거 신호의 분산과 일관되는지 확인한다. 겹치는 구간을 평균해 분산을 줄이는
Welch 방법은 정상성 가정을 고려해야 하므로, 고장 주입 전후를 하나의 PSD에 섞기보다 각 구간을
구분해서 분석하는 편이 해석하기 좋다. [MathWorks: pwelch](https://www.mathworks.com/help/signal/ref/pwelch.html)

STFT는 위 분자에 해당하는 복소 변환을 구간 시작점 또는 중심 시각별로 유지한다. spectrogram은
시간에 따라 어떤 주파수 성분이 나타나는지 확인하는 데 쓰며 PSD와 amplitude spectrum의 색상
단위를 구분한다. 로그축은 `10*log10(power/referencePower)`로 변환하고 0에서의 로그를 피한다.

구현은 기본적으로 초기 2초를 제외한 동적 가속도에 1024 sample periodic Hann, 50% overlap을
사용한다. 1 kHz에서 bin 간격은 0.9765625 Hz, Hann ENBW는 약 1.464844 Hz이다. 각 구간의
평균을 제거하며 `vib3d_spectral.m`에서 계산하므로 Signal Processing Toolbox 없이 실행한다.
STFT는 전체 시계열에 256 sample, 87.5% overlap을 사용하여 창 중심 시각과 함께 저장한다.
기본 PSD 결과에는 통계적 신뢰구간이 포함되어 있지 않다.

긴 창은 주파수 분해를, 짧은 창은 발생 시각의 분해를 개선한다. FFT zero padding은 곡선을
촘촘하게 보간하지만 실제 관측 길이에 따른 분해능을 높이지 않는다. 64점 배포 FFT의 bin 간격을
긴 연구용 PSD의 분해능과 같은 것으로 설명하면 안 된다.

시간 통계는 RMS, peak, crest factor \(\max|x|/RMS(x)\), 중심 4차 모멘트 기반 kurtosis 등을
함께 본다. RMS를 평균 제거 전/후 중 어느 신호에서 계산했는지, kurtosis가 raw 값인지 excess
값인지 명시한다. 수치 하나를 결함 진단 기준으로 바로 사용하는 대신 신호와 스펙트럼을 같이
검토한다.

`axis_metrics.csv`의 기본 통계는 초기 2초를 제외한 `result.accel`에서 축별 평균을 제거한
신호에 대해 계산한다. kurtosis는 excess가 아닌 Pearson 값이므로 이상적 정규분포의 기준은
3이다. 포화율은 같은 시간 구간의 raw 변환을 기준으로 한다. 기본 민감도 분석은 질량 변경 시
관성도 같은 비율로 변경하고, 강성/감쇠 변경은 전체 마운트에 적용한다. 감쇠만 변경했을 때
비감쇠 고유주파수 곡선이 평평한 것은 정의상 예상되는 결과다.

## 10. Simulink 계층과 시간 계약

모델을 열 때 다음 인과 흐름을 따라 하위 시스템을 살펴본다. 실제 블록 이름은 생성 코드에서
확인한다.

```mermaid
flowchart LR
    W["시나리오 가진: 힘·토크 6성분"] --> P["6DOF Plant: M,C,K → 이산 상태공간"]
    P --> S["센서 위치 변환 → XYZ 가속도 → INT16"]
    S --> F["X축 64 sample 수집 → 정수 FFT → 4개 특징"]
    F --> N["기존 INT8 NPU"]
    N --> Q["연속 이상 판정·안전 상태 관찰"]
    P --> L["상태/센서/추론 로그"]
    S --> L
    Q --> L
    L --> A["MATLAB 분석과 3차원 재생"]
```

1 kHz 물리/센서 상태와 64 sample마다 갱신되는 추론은 서로 다른 논리적 속도다. Buffer가
64개를 채웠을 때만 `valid`가 1이어야 하고, safety의 연속 이상 카운터도 이때만 갱신되어야 한다.
held class 값을 1 ms마다 다시 세면 세 번째 연속 프레임 대신 3 ms에 trip하는 오류가 생긴다.
초기 63개 샘플의 미완성 프레임도 판정으로 취급하지 않는다.

FFT/NPU 출력은 프레임 사이에서 유지할 수 있지만 `class_valid`와 분리한다. 이 연구 경로의
1 ms tick과 프레임 경계는 100 MHz RTL의 cycle-accurate 파이프라인 모델이 아니다. 기존 FPGA
8.33 µs 가속 시간 등 실측 수치를 Simulink solver의 실행 시간과 비교하지 않는다.

안전 관찰은 class 1에 대해 warning → 25% 제한 상태 → latch를 표시하고, trip 전 정상 판정은
연속 이상 수를 지우는 방식으로 이해한다. class 0은 이미 설정된 latch를 자동 해제하지 않는다.
**이 연구 모델에서 safety 출력이 표시된다는 사실은 하우징 가진이 줄거나 모터가 정지하는
폐루프 기계 응답을 구현했다는 뜻이 아니다.** prescribed excitation으로 구동되는 모델에서는
판정 경로를 관찰할 뿐이다. 실물의 PWM 차단, watchdog, PI 속도 제어 검증은 기존 RTL과
하드웨어 실험 기록을 따른다.

## 11. 3차원 화면을 읽는 방법

3D 재생에서 하우징은 계산된 병진과 회전 상태를 사용하고 센서 위치와 마운트가 함께 움직인다.
회전축/로터의 시각적 회전과 하우징의 작은 각진동은 서로 다른 운동이다. 로터 위상은 시각화
정보이며, 6DOF 상태에는 전기자나 로터 비틀림 자유도가 포함되지 않는다.

실제 변위는 매우 작아 형상 크기 그대로 표시하면 보이지 않을 수 있다. 표시 배율을 적용할 때
화면에 배율을 나타내고, 수치 플롯은 원래 SI 단위로 유지한다. 병진과 회전의 표시 배율이 다르면
애니메이션은 시각적 설명을 위한 것이며 확대 형상의 점간 거리에서 실제 strain을 추정할 수 없다.
궤적 역시 센서의 실제 변위를 확대했는지 화면상의 점을 그렸는지 범례와 축을 확인한다.

그래픽에서는 하우징에 속한 객체를 같은 변환에 묶어 일관되게 이동/회전시킬 수 있다. MATLAB의
`hgtransform`은 동차 변환 행렬을 그래픽 객체 그룹에 적용할 때 쓰는 도구다. 이 변환은 그래픽
기능이며 물리 solver 자체는 아니다. [MathWorks: hgtransform](https://www.mathworks.com/help/matlab/ref/hgtransform.html)

3D 영상, XYZ 시계열, XY/YZ/XZ 궤적, NPU 특징과 안전 상태는 같은 물리 시간축에 대응한다.
회전 모드가 센서 X축에 미치는 영향과 특징·판정의 관계를 함께 표시한다. 프레임 속도는
시각화 설정이며 센서 샘플레이트와 별개이다. 영상에서 건너뛴 샘플은 해석 데이터에서 제거되지 않는다.

기본 `motionScale=30`은 하우징 병진과 각도에 적용되는 표시 배율이다. 기본
`rotorSpeedScale=0.02`는 prescribed rotor 위상을 시각적으로 늦추는 별도 계수이며 화면에는
원래 rpm과 위상을 함께 표시한다. 최대 240 frame, 30 frame/s 설정의 영상 시간과 물리 시간의
비율도 표시한다. 표시 프레임 수를 줄이면 빠른 운동의 시간 aliasing이 생길 수 있으므로 영상에서
회전 주파수를 추정하지 않는다. `exportVideo=true`이면 MP4를 시도하고 환경에 따라 Motion JPEG
AVI를 사용한다. 기본 PNG는 영상 내 임의 프레임이 아니라 병진 크기가 최대인 시각을 캡처한다.

## 12. 검증 코드와 실행 상태

검증 코드는 두 층으로 구성된다. MATLAB·Simulink 실행 상태는 앞 절의 기록과 구분한다.

| 검증 층 | 코드의 비교 항목 | 해석 범위 |
|---|---|---|
| 구현 일치 | MATLAB/Simulink 상태·센서·정수 특징·판정 정렬 | 동일 수식과 입력의 수치 결과 |
| 물리/수치 일관성 | 행렬 성질, 에너지, 고유치, 이산화, 해상도 | 합성 모델의 내부 일관성 |

### 12.1 자체 검증을 해석하는 기준

현재 `vib3d_self_test`는 행렬의 대칭/정부호와 극 안정성, 질량 정규화·일반화 고유치,
ZOH 반 스텝 합성, 영입력 및 정적 평형, 센서 lever arm와 중력 투영, 자유 감쇠 에너지,
알려진 정현파의 PSD/주파수/ENBW, 난수 재현성과 전역 RNG 불변을 검사한다. 실행 시 검사 잔차와
허용오차를 표로 남긴다. 다음 목록은 구현된 검사 항목과 해석 방법이다.

1. `M`, `C`, `K`의 유한값·대칭성과 양의 정부호를 확인한다. 기본 모델의 모든 자유도는
   마운트로 구속되어 있다.
2. 무외력, 영초기조건에서 응답이 0인지 검사한다. 센서 잡음이 켜져 있으면 raw 센서 신호는
   0이 아니므로 물리 상태와 센서 경로를 구분한다.
3. 에너지 \(E=\tfrac12\dot q^TM\dot q+\tfrac12q^TKq\)를 계산한다. 무외력에서
   \(\dot E=-\dot q^TC\dot q\le0\)이어야 한다. 입력이 있을 때는
   \(\dot E=\dot q^Tw-\dot q^TC\dot q\)로 에너지 수지를 확인한다.
4. 안정된 감쇠 모델은 \(\Re\lambda(A_c)<0\), \(|\lambda(A_d)|<1\)인지 확인한다.
5. 일정 입력에서 한 번의 \(T_s\) 전파와 두 번의 \(T_s/2\) 전파를 비교한다. 이는 행렬 지수와
   상태 인덱스 구현을 확인하는 시험이다. 시간에 따라 변하는 외력의 샘플링 수렴을 증명하지는 않는다.
6. 20 Hz 연속 정현파 입력의 독립 상태공간 해와 ZOH 계산을 비교한다. 샘플 간격을 절반으로
   줄였을 때 에너지 가중 오차의 비율이 0.75 이하인지 검사한다. 이는 물리 경로의 수치 검사다.
7. MATLAB과 Simulink의 같은 시각 출력 차이를 저장한다. float 상태는 사전 정의한 절대/상대
   허용오차를 쓰고, INT16·특징·INT8 logits·class는 정확한 정수 일치를 요구한다.

정수 양자화 경계에서는 아주 작은 float 오차가 1 count 차이를 만들 수 있다. 임의로 허용오차를
늘려 감추지 말고 센서값이 경계의 어디에 있는지, 반올림과 포화 순서가 같은지 조사한다.
수치 차이의 최대값만 남기지 말고 최초 불일치 시각과 값도 남긴다.

### 12.2 결과에 남길 증거

실행 날짜, MATLAB release, 사용한 옵션, seed, 소스 버전, 파라미터 전체, 초기조건, 시나리오,
샘플레이트, 분석 구간을 함께 보관한다. 자동 저장 자료에 없는 환경 정보는 연구노트에 추가한다.
기존 `data/model.json`이 바뀌면 같은 물리 신호에서도 분류 결과가 달라질 수 있으므로 모델 파일의
해시도 함께 기록한다. `RUN_MATLAB_CHECKS`의 source digest와 별도로 새 연구 파일 변경을 추적한다.

현재 digest 계산은 `docs`, `reports`, `artifacts` 등과 Markdown을 제외하고 연구 `.m` 및 도구
소스를 포함한다. 따라서 연구 코드를 수정한 뒤에는 기존 gate도 새 digest로 재검증해야 한다.
문법 검사에는 MISS_HIT를 사용할 수 있고, 독립 수식 확인은
`python3 tools/check_research_reference.py`로 수행한다. Python 결과는
`reports/research_offline/`에 별도 저장되며, 그 디렉터리의 3D preview는 MATLAB 화면이 아니다.
이 두 검사는 그래픽, toolbox 라이선스, Simulink block API, 모델 실행의 호환성을 검증하지 않는다.

결과 파일이 존재하는 것과 검증 통과는 다르다. 실행 중 실패한 경우 마지막으로 성공한 산출물이
남아 있을 수 있으므로 보고서의 실행 시각과 상태를 확인한다. 이 문서의 수식만으로 MATLAB API
호환성을 증명할 수 없으며, 사용한 release에서 생성·실행한 `.slx`와 로그가 최종 근거다.

## 13. 기존 데이터와 합성 결과의 구분

기존 분류기의 실측 데이터는 독립 run 단위로 학습·검증을 나눈다. 같은 acquisition의 인접한
64-sample window가 양쪽에 섞이지 않게 한 구분이며, 스터디에서도 기존 분할을 유지한다.

합성 시나리오의 class 1 비율은 해당 입력에 대한 기존 분류기의 반응률이다. 현재 분류기는
X축의 4-band 특징만 사용하며, 합성 Y/Z축 신호는 물리 응답과 센서 방향을 보여 주는
분석·시각화 자료다.

PSD와 정수 특징은 전처리·스케일이 다르다. PSD가 비슷해도 정수 특징의 포화와 bin 경계에 따라
판정이 달라질 수 있고, 같은 class가 나와도 기계 파라미터가 같다는 뜻은 아니다.

## 14. 보고서와 발표 구성

발표에서는 다음 순서가 자연스럽다.

1. 기존 보드 실험의 질문을 제시한다: 센서 고정 상태가 바뀌었을 때 연산은 일치했지만 특징
   대역과 분류가 달라졌다.
2. 6DOF 좌표계와 마운트 그림을 보여주고 \(S_i\)로부터 \(M,C,K\)가 만들어지는 과정을 유도한다.
3. 모드/FRF에서 센서 위치와 결합 모드가 관측에 미치는 영향을 설명한다.
4. 같은 시간의 3D 동작, XYZ 가속도, STFT를 연결하고 연구용 스펙트럼과 배포용 64점 특징을
   구분한다.
5. 고정 조건과 변화 조건의 특징·logit·safety 관찰을 비교한다. 실측 검증 범위와 합성 실험
   범위를 표에 분리한다.
6. 수치 검증의 실행 상태와 합성 모델의 가정·단위를 설명한다.

각 그림의 캡션에는 시나리오, 단위, 샘플레이트, 시간 구간, seed, 변경 파라미터를 포함한다.
3D 영상에는 실제 변위가 아니라 표시 배율이 적용되었음을 명시한다. 결과표의 빈칸은 실행 후
계산 결과로 채우며 예상값이나 목표값을 실행 결과처럼 기재하지 않는다.

## 15. 모델의 적용 범위

현재 연구의 하우징은 소각도 선형 강체 모델이다. 마운트 비선형, 유격, 마찰, 접촉, 하우징 굽힘,
축의 탄성 모드, 회전 자이로스코픽 결합, 베어링 결함 충격, 실제 전기자/PWM 리플은 이 모델의
방정식에 포함되지 않는다. 응답과 판정은 설정한 힘·모멘트와 소각도 선형 강체 가정 안에서 해석한다.

이 스터디는 **물리 상태 → 센서 → 고정소수점 특징 → 판정**을 연결하고 각 단계의 결과와 실행
상태를 기록한다. 기존 실물 성능 기록은
[기존 설계 계약](../DESIGN.md), [실측 데이터 절차](REAL_DATASET.md),
[하드웨어 검증 기록](../artifacts/hardware_validation_2026-09-14.md)과 함께 검토한다.
