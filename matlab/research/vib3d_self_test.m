function report = vib3d_self_test(p)
% [읽기 안내] 가상 역학과 스펙트럼 계산이 기본 물리·수학 규칙을 지키는지 확인합니다.
% 입력 p는 설정이며 생략하면 기본값을 사용합니다. 출력 report에는 검사명,
% 잔차(예상값과의 차이), 허용 오차, 통과 여부를 기록합니다.
% [주1] 통과는 구현의 내부 일관성을 뜻합니다. 실제 측정값과 모델을 대조하거나
% 질량·강성·감쇠를 실험으로 보정한 결과가 아니므로 실물 정확도와 구분합니다.
%VIB3D_SELF_TEST Mechanical invariants and spectral scaling, no toolboxes.
% These tests establish implementation consistency, not physical calibration.
if nargin<1, p=vib3d_parameters(); end
plant=vib3d_plant_matrices(p);
names={}; residual=[]; limit=[];
check('M symmetry',norm(plant.M-plant.M','fro'),1e-12);
% [주2] M/C/K의 대칭성과 양의 정부호는 에너지 해석의 기본 조건입니다.
% 연속 극점의 실수부<0, 이산 극점의 크기<1인지 검사해 자유응답의 감쇠도 봅니다.
check('K symmetry',norm(plant.K-plant.K','fro'),1e-10);
check('C symmetry',norm(plant.C-plant.C','fro'),1e-12);
assert(min(eig(plant.M))>0 && min(eig(plant.K))>0 && min(eig(plant.C))>0, ...
    'vib3d:TestPassivity','M, K, C must be positive definite.');
assert(max(real(plant.poles))<0 && max(abs(eig(plant.Ad)))<1, ...
    'vib3d:TestStability','Continuous and discrete plants must be stable.');
check('Modal mass normalization',norm(plant.modes'*plant.M*plant.modes-eye(6),'fro'),1e-10);
check('Generalized eigenproblem',norm(plant.K*plant.modes-plant.M*plant.modes ...
    *diag((2*pi*plant.modal_hz).^2),'fro')/norm(plant.K*plant.modes,'fro'),1e-10);

% Exact ZOH has a semigroup property, including the held-input convolution.
half=p; half.dt=p.dt/2; half.fs=2*p.fs;
% [주3] 입력을 일정하게 유지하면 반 시간 간격을 두 번 진행한 결과와
% 원래 간격을 한 번 진행한 결과가 같아야 합니다. 이것이 ZOH 조합 검사입니다.
ph=vib3d_plant_matrices(half);
check('ZOH half-step state composition',norm(plant.Ad-ph.Ad*ph.Ad,'fro')/norm(plant.Ad,'fro'),1e-10);
check('ZOH half-step input composition',norm(plant.Bd-(ph.Ad*ph.Bd+ph.Bd),'fro')/norm(plant.Bd,'fro'),1e-10);

% A continuously sinusoidal force has an independent exact augmented-state
% solution. Sampling/holding that force introduces O(dt) error even though
% the plant's held-input update is exact; halving dt must reduce that error.
omega=2*pi*20; nsteps=max(20,round(0.2/p.dt)); stop=nsteps*p.dt;
% 연속 정현파의 독립 해와 비교해 샘플 간격을 줄였을 때 오차가 줄어드는지 봅니다.
% ZOH의 정확성은 '샘플 사이 일정한 입력'에 대한 것으로, 연속 파형 전체와는 다릅니다.
augmented=[plant.A,plant.B(:,1),zeros(12,1); ...
    zeros(1,12),0,omega;zeros(1,12),-omega,0];
reference=expm(augmented*stop)*[zeros(13,1);1];
xcoarse=held_sine(plant,p.dt,nsteps,omega);
xfine=held_sine(ph,p.dt/2,2*nsteps,omega);
energyMetric=blkdiag(plant.K,plant.M);
ec=xcoarse-reference(1:12); ef=xfine-reference(1:12);
coarseError=sqrt(ec'*energyMetric*ec); fineError=sqrt(ef'*energyMetric*ef);
check('Held sinusoid time-step convergence ratio',fineError/coarseError,0.75);

short=p; short.duration=0.2; short.sensor.noise_std=zeros(1,3);
% [주4] 잡음·바이어스를 없앤 정지 실험에서는 동적 진동이 0이어야 합니다.
% 하지만 가속도계 비력은 Z축 +1 g이므로 센서 카운트는 [0 0 16384]입니다.
short.sensor.bias=zeros(1,3); short.initial_state=zeros(12,1);
input=vib3d_excitation(short,'normal'); input.wrench(:)=0;
rest=vib3d_simulate(short,input);
check('Zero input zero dynamic motion',max(abs([rest.q(:);rest.qd(:);rest.accel(:)])),1e-12);
assert(all(all(rest.raw==repmat(int16([0 0 16384]),numel(rest.t),1))), ...
    'vib3d:TestGravity','At rest: [0 0 +1g] specific force and 16384 counts/g.');

load=[0.10;-0.08;0.12;0.001;-0.002;0.001];
% 일정한 외력의 평형 q=K\load에서 시작하면 이동이 유지되고 가속도는 0입니다.
equilibrium=plant.K\load;
short.initial_state=[equilibrium;zeros(6,1)];
input.wrench=repmat(load',numel(input.t),1);
steady=vib3d_simulate(short,input);
error=bsxfun(@minus,steady.q,equilibrium');
check('Static equilibrium under constant wrench',max(abs(error(:))),1e-11);
check('Static equilibrium zero acceleration',max(abs(steady.accel(:))),1e-9);

alpha=[1;2;-3]; wrench=plant.M*[zeros(3,1);alpha];
% [주5] 센서 위치에 따른 각가속도×팔길이와 작은 기울기의 중력 투영을
% 각각 간단한 수식으로 비교하여 축 순서와 부호 오류를 찾습니다.
expected=cross(alpha,p.geometry.sensor_position(:));
check('Sensor lever-arm acceleration',norm(plant.Dacc*wrench-expected),1e-12);
tilt=zeros(12,1); tilt(4)=0.01; tilt(5)=-0.02;
expected=p.gravity*[0.02;0.01;0];
check('Small-angle gravity projection',norm(plant.Cgravity*tilt-expected),1e-12);

short.initial_state=[1e-4;-2e-4;1e-4;0.001;-0.002;0.001;zeros(6,1)];
% 외력 없이 시작한 진동은 감쇠로 에너지가 줄어야 합니다. 에너지가 늘면
% 감쇠 부호나 수치 갱신의 문제를 의심할 수 있습니다.
input.wrench(:)=0;
decay=vib3d_simulate(short,input);
check('Passive free-decay energy increase',max([0;diff(decay.energy)]),1e-12);

% A sampled sinusoid has unit mean square. Exact bin coherence removes
% leakage ambiguity and verifies one-sided doubling, Hz units and Hann ENBW.
N=1024; n=(0:N-1)'; f0=p.fs*64/N;
% [주6] RMS=1인 알려진 정현파로 PSD의 면적·주파수 위치·창 대역폭을 검사합니다.
% FFT 칸과 정확히 맞는 주파수를 써서 누설과 정규화 오류를 혼동하지 않게 합니다.
tone=sqrt(2)*sin(2*pi*f0*n/p.fs);
sp=vib3d_spectral(tone,p.fs,N,0.5);
check('One-sided PSD Parseval normalization',abs(sum(sp.psd)*sp.df-1),1e-10);
[~,idx]=max(sp.psd);
check('Known sinusoid spectral frequency',abs(sp.frequency(idx)-f0),1e-10);
check('Periodic Hann equivalent noise bandwidth',abs(sp.enbw_hz-1.5*p.fs/N),1e-10);

% Verify local noise is repeatable and does not disturb application RNG.
short.sensor.noise_std=p.sensor.noise_std; before=rng;
% [주7] 동일 seed는 같은 합성 잡음을 만들고 외부 난수 상태는 건드리지 않아야 합니다.
% 이는 재현성 검사이며 합성 잡음이 실제 센서 잡음과 같다는 검사는 아닙니다.
a=vib3d_simulate(short,input); b=vib3d_simulate(short,input); after=rng;
assert(isequal(before,after),'vib3d:TestRNG','Simulator changed global RNG state.');
assert(isequal(a.sensor_noise,b.sensor_noise) && isequal(a.raw,b.raw), ...
    'vib3d:TestReproducibility','Repeated seeded simulations differ.');
report.passed=true;
report.checks=table(names(:),residual(:),limit(:), ...
    'VariableNames',{'Check','Residual','Tolerance'});
report.additional_assertions={'Positive-definite M/C/K','Stable A/Ad', ...
    'One-g rest quantization','Global RNG unchanged','Seeded repeatability'};
report.modal_hz=plant.modal_hz;
report.max_continuous_pole_real=max(real(plant.poles));
report.discrete_spectral_radius=max(abs(eig(plant.Ad)));
report.note='Implementation invariants passed; no claim of measured-model agreement.';

    function check(name,value,tolerance)
        assert(isfinite(value) && value<=tolerance,'vib3d:SelfTest', ...
            '%s failed: residual %.6g exceeds %.6g.',name,value,tolerance);
        names{end+1}=name; residual(end+1)=value; limit(end+1)=tolerance;
    end
end

function state=held_sine(plant,dt,nsteps,omega)
state=zeros(12,1);
for k=0:nsteps-1
    state=plant.Ad*state+plant.Bd(:,1)*sin(omega*k*dt);
end
end
