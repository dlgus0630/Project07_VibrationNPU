function input = vib3d_excitation(p,scenario)
% [읽기 안내] 정상·불평형·정렬 불량·리플의 가상 외력을 만드는 함수입니다.
% 입력 p는 설정, scenario는 시나리오 이름입니다. 출력 input.t는 N×1(s),
% input.wrench는 N×6([힘 3축 N, 토크 3축 N m])이며 시간별 외력을 담습니다.
% [주1] 고장 이름은 물리 현상을 설명하기 위한 가정입니다. 실제 측정 파형이나
% 진단 정답 라벨이 아니며, 회전자 속도도 모델 밖에서 지정합니다.
%VIB3D_EXCITATION Prescribed synthetic rotor load, not a calibrated diagnosis.
% Shaft is +X. Radial unbalance rotates in YZ. Torque includes r_force x F.
if nargin<2, scenario='normal'; end
scenario=char(scenario);
assert(any(strcmp(scenario,{'normal','unbalance','misalignment','ripple'})), ...
    'vib3d:Scenario','Unknown scenario: %s',scenario);
t=(0:round(p.duration/p.dt))'*p.dt;
ramp=min(1,t/p.rotor.ramp_time); ramp=3*ramp.^2-2*ramp.^3;
% [주2] 부드러운 속도 상승으로 시작 순간의 급격한 입력을 줄입니다.
% RPM×2*pi/60으로 rad/s로 바꾸고 적분하면 회전자 각도(rad)가 됩니다.
rpm=p.rotor.rpm_start+(p.rotor.rpm_final-p.rotor.rpm_start)*ramp ...
    +p.rotor.speed_modulation_rpm*sin(2*pi*p.rotor.speed_modulation_hz*t);
omega=rpm*(2*pi/60);
theta=cumtrapz(t,omega);
omega_dot=gradient(omega,p.dt);
U=p.rotor.normal_unbalance;
% [주3] U는 편심 질량×반경입니다. U*omega^2는 회전에 따른 힘 크기이고,
% U*omega_dot 항은 속도가 변할 때 생기는 접선 방향 반력을 반영합니다.
% 축은 X 방향이므로 원심 불평형 힘은 주로 Y-Z 평면에서 회전합니다.
if strcmp(scenario,'unbalance'), U=p.rotor.fault_unbalance; end
% Reaction of prescribed eccentric mass includes angular acceleration.
F=[0.025*sin(theta+0.3), ...
    U*(omega.^2.*cos(theta)+omega_dot.*sin(theta)), ...
    U*(omega.^2.*sin(theta)-omega_dot.*cos(theta))];
T=zeros(numel(t),3);
T(:,1)=0.0003*sin(2*theta);
switch scenario
    % 정렬 불량에는 회전수의 2배 성분을, 리플에는 기본파와 홀수 고조파를
    % 더해 비교합니다. 실제 장비의 고장별 고유 파형을 식별한 결과는 아닙니다.
    case 'misalignment'
        F=F+[0.24*sin(2*theta+0.4),0.10*cos(2*theta), ...
            0.10*sin(2*theta)];
        T(:,2)=0.0015*sin(2*theta+0.2);
    case 'ripple'
        a=2*pi*p.rotor.ripple_hz*t;
        wave=sin(a)+sin(3*a)/3+sin(5*a)/5;
        F(:,1)=F(:,1)+0.30*wave;
        T(:,1)=T(:,1)+0.0035*wave;
end
r=repmat(p.geometry.force_position,numel(t),1);
% [주4] 힘이 무게중심에서 떨어진 위치에 작용하면 r×F 토크도 생깁니다.
% 지정한 직접 토크 T와 이 모멘트를 더해 6자유도 입력을 완성합니다.
input.t=t; input.wrench=[F,T+cross(r,F,2)];
input.rotor_angle=theta; input.rpm=rpm; input.scenario=scenario;
input.description=['Synthetic ' scenario ' load; prescribed rotor RPM, ' ...
    'not gearbox-output speed or a measured fault signature.'];
end
