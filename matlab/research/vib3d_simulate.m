function result = vib3d_simulate(p,input)
% [읽기 안내] 설정 p와 시간별 외력 input으로 합성 진동 응답을 계산합니다.
% 출력 result.q는 N×6(m, rad), qd는 N×6(m/s, rad/s), accel은 N×3(m/s^2),
% raw는 N×3의 int16 센서 카운트입니다. N은 저장된 시간점 수입니다.
% 함수의 measured 이름은 가상 센서 출력을 뜻하며 실제 계측 파일이 아닙니다.
%VIB3D_SIMULATE Exact ZOH state update, left-endpoint outputs at t(k).
% Wrench(k,:) is held on [t(k),t(k+1)). No Control/Signal toolbox needed.
plant=vib3d_plant_matrices(p);
t=input.t(:); u=double(input.wrench); n=numel(t);
assert(n>=2 && isequal(size(u),[n 6]) && all(isfinite(u(:))));
assert(all(abs(diff(t)-p.dt)<max(1e-12,1e-8*p.dt)), ...
    'vib3d:TimeGrid','Input must use uniform p.dt sampling.');
assert(numel(p.initial_state)==12 && all(isfinite(p.initial_state(:))));
x=zeros(n,12); x(1,:)=p.initial_state(:)';
% [주1] x(k)는 t(k)의 상태입니다. u(k)를 다음 시각까지 일정하게 유지해
% x(k+1)을 계산하므로 입력과 출력의 시간 인덱스를 한 칸 밀면 안 됩니다.
for k=1:n-1
    x(k+1,:)=(plant.Ad*x(k,:)'+plant.Bd*u(k,:)')';
end
acc=x*plant.Cacc'+u*plant.Dacc';
% [주2] acc는 진동으로 생기는 동적 가속도입니다. specific에는 기울기에 따른
% 중력 투영과 정지 시 Z축의 +1 g가 포함되어 가속도계 출력을 설명합니다.
specific=x*plant.Cspecific'+u*plant.Dspecific'+repmat(plant.gravity_offset',n,1);
% RandStream is local: this function does not alter the caller's RNG state.
stream=RandStream('mt19937ar','Seed',p.seed);
% [주3] 고정 seed의 잡음은 같은 가상 실험을 다시 비교하기 위한 장치입니다.
% 지역 난수기를 써서 다른 코드의 난수 상태를 바꾸지 않으며, 실측값은 아닙니다.
noise=bsxfun(@times,randn(stream,n,3),p.sensor.noise_std(:)');
measured=specific+noise+repmat(p.sensor.bias(:)',n,1);
unclipped=round(measured*p.sensor.counts_per_g/p.gravity);
% [주4] m/s^2를 g로 나누고 counts/g를 곱해 정수 센서값으로 만듭니다.
% int16 범위 밖은 잘라 저장하고 saturated에 기록해 포화 여부를 확인합니다.
raw=int16(max(-32768,min(32767,unclipped)));
result.t=t; result.q=x(:,1:6); result.qd=x(:,7:12);
result.accel=acc; result.specific_force=specific;
result.measured_specific_force=measured;
result.raw=raw; result.saturated=unclipped>32767 | unclipped< -32768;
result.sensor_noise=noise;
result.rotor_angle=input.rotor_angle; result.rpm=input.rpm;
result.wrench=u; result.scenario=input.scenario;
% [주5] energy는 운동+탄성 에너지(J), dissipation은 감쇠 소모율(W),
% input_power는 외력이 주는 일률(W)입니다. 수치해의 물리적 일관성을 봅니다.
result.energy=0.5*sum((result.qd*plant.M).*result.qd,2) ...
    +0.5*sum((result.q*plant.K).*result.q,2);
result.dissipation=sum((result.qd*plant.C).*result.qd,2);
result.input_power=sum(result.qd.*u,2);
end
