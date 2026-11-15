function p = vib3d_parameters()
% [읽기 안내] 연구용 가상 모터의 재료·형상·센서·해석 조건을 한곳에 모읍니다.
% 입력은 없고, 출력 p는 뒤 함수들이 공통으로 읽는 설정 구조체입니다.
% [주1] 이 수치는 실측으로 식별한 값이 아닙니다. 실측 전용 연구와 구분하세요.
% 길이는 m, 질량은 kg, 힘은 N, 시간은 s, 각도는 rad를 사용합니다.
% q=[x y z roll pitch yaw]는 평형점에서의 이동 3개와 작은 회전 3개입니다.
%VIB3D_PARAMETERS Illustrative, uncalibrated six-DOF motor-housing model.
% SI units throughout. Housing axes: shaft +X, transverse Y, vertical +Z.
% Coordinates are perturbations about the gravity-loaded static equilibrium.
% The rotor speed below is a scenario input, NOT a measured gearbox output RPM.
p.fs = 1000;
% [주2] 1 kHz는 1 ms마다 한 샘플입니다. FFT의 64샘플 규격은 FPGA와 맞춥니다.
% initial_state의 앞 6개는 q, 뒤 6개는 속도 qdot이며 모두 0에서 시작합니다.
p.dt = 1/p.fs;
p.duration = 8;
p.nfft = 64;                 % Existing FPGA contract: do not change.
p.gravity = 9.80665;
p.seed = 7307;
p.initial_state = zeros(12,1);
p.mass = 0.62;
% [주3] 위치는 무게중심 기준입니다. 센서·지지점이 중심에서 떨어지면
% 같은 몸체 회전도 위치에 따라 서로 다른 이동과 가속도를 만듭니다.
p.geometry.body_size = [0.120 0.065 0.060];
p.geometry.mount_points = [-0.045 -0.025 -0.040; ...
                           -0.045  0.025 -0.040; ...
                            0.045 -0.025 -0.040; ...
                            0.045  0.025 -0.040];
p.geometry.sensor_position = [0.036 0.015 0.030];
p.geometry.force_position = [0.040 0 0.008];
p.geometry.shaft_length = 0.045;
p.geometry.rotor_radius = 0.023;
d = p.geometry.body_size;
% 직육면체 관성모멘트 근사입니다. 실제 모터 형상을 측정한 관성값은 아닙니다.
p.inertia = diag(p.mass/12*[d(2)^2+d(3)^2, ...
    d(1)^2+d(3)^2, d(1)^2+d(2)^2]);
p.mount.stiffness = [1; 0.94; 1.08; 1.02]*[1800 2100 2700]; % N/m
% 강성은 변위에 비례한 복원력, 감쇠는 속도에 비례한 저항력을 정합니다.
% 네 지지대의 작은 차이와 배치 각도로 이동·회전의 결합을 표현합니다.
p.mount.damping = [1; 0.94; 1.08; 1.02]*[2.1 2.3 2.8];     % N s/m
p.mount.yaw = pi/180*[15 -15 -12 12];
p.rotor.rpm_start = 1400;
% [주4] RPM은 외부에서 지정하는 회전자 속도입니다. PID가 계산한 결과나
% 기어박스 출력축 실측 RPM이 아니며, 불평형 값의 단위는 질량×반경(kg m)입니다.
p.rotor.rpm_final = 1800;
p.rotor.ramp_time = 1.0;
p.rotor.speed_modulation_rpm = 8;
p.rotor.speed_modulation_hz = 0.7;
p.rotor.normal_unbalance = 0.5e-6;  % eccentric mass * radius, kg m
p.rotor.fault_unbalance = 7e-6;
p.rotor.ripple_hz = 32;            % Board SW3 modulation frequency only.
p.sensor.counts_per_g = 16384;
% [주5] 1 g를 16384카운트로 바꾸는 ±2 g 센서 가정입니다.
% noise_std와 bias도 합성 센서의 가정값이며, 실측 데이터에 더하는 보정값은 아닙니다.
p.sensor.range_g = 2;
p.sensor.noise_std = [0.006 0.006 0.006]; % m/s^2 per sampled axis
p.sensor.bias = [0.002 -0.001 0.003];    % m/s^2, illustrative
p.analysis.discard_seconds = 2;
% 초기 과도응답을 제외한 분석 구간과 긴 PSD 창을 정합니다.
% 이 PSD용 창 길이는 NPU 입력의 64샘플 프레임 길이와 별개입니다.
p.analysis.segment_length = 1024;
p.analysis.overlap_fraction = 0.5;
p.analysis.frf_force_axis = 1;
p.analysis.sensitivity_factors = [0.8 1 1.2];
p.assumptions = ['Illustrative parameters, not fitted to measured hardware. ' ...
    'Linear small-angle housing motion about static equilibrium; fixed base, ' ...
    'rigid housing, Kelvin-Voigt point mounts, diagonal CG inertia. ' ...
    'Rotor prescribed as external excitation; no gyroscopic, bearing-contact, ' ...
    'gear-mesh, electrical motor, thermal or structural-flexibility dynamics. ' ...
    'Sensor bandwidth/anti-alias filtering and sample jitter are not modelled.'];
end
