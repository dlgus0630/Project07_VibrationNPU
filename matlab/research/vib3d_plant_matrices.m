function plant = vib3d_plant_matrices(p)
% [읽기 안내] 설정 p를 6자유도 운동방정식과 센서 출력 행렬 plant로 바꿉니다.
% q=[x y z roll pitch yaw]' : 이동은 m, 회전은 rad인 6×1 벡터입니다.
% 입력 w=[Fx Fy Fz Tx Ty Tz]'는 힘(N)과 토크(N m)입니다.
% M*qdd+C*qd+K*q=w에서 M은 관성, C는 감쇠, K는 복원력의 역할을 합니다.
% 중력으로 이미 내려앉은 평형점을 원점으로 잡고 그 주변의 작은 움직임만 풉니다.
%VIB3D_PLANT_MATRICES M*qdd+C*qd+K*q=w, q=[x y z roll pitch yaw]'.
% At mount r, delta=[I,-skew(r)]*q. Thus K=sum(H'*Kmount*H),
% which retains translation/rotation coupling and preserves elastic energy.
assert(isscalar(p.dt) && p.dt>0 && abs(p.fs*p.dt-1)<1e-12, ...
    'vib3d:SampleTime','p.dt must equal 1/p.fs.');
assert(p.mass>0 && isequal(size(p.inertia),[3 3]));
plant.M = blkdiag(p.mass*eye(3),p.inertia);
% [주1] 앞쪽 이동에는 질량, 뒤쪽 회전에는 관성모멘트를 대응시킵니다.
plant.K = zeros(6); plant.C = zeros(6);
nmount = size(p.geometry.mount_points,1);
plant.mount_map = zeros(3,6,nmount);
assert(isequal(size(p.mount.stiffness),[nmount 3]));
assert(isequal(size(p.mount.damping),[nmount 3]));
assert(all(p.mount.stiffness(:)>0) && all(p.mount.damping(:)>0));
for k=1:nmount
    % [주2] H*q는 각 지지점의 3축 변위입니다. 회전×팔길이도 포함하므로
    % 지지대가 중심을 벗어나면 이동과 회전이 자연스럽게 결합됩니다.
    % R은 지지대의 로컬 강성 방향을 몸체 좌표로 돌려 주는 회전행렬입니다.
    a=p.mount.yaw(k); R=[cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
    H=[eye(3),-skew3(p.geometry.mount_points(k,:))];
    plant.mount_map(:,:,k)=H;
    plant.K=plant.K+H'*(R*diag(p.mount.stiffness(k,:))*R')*H;
    plant.C=plant.C+H'*(R*diag(p.mount.damping(k,:))*R')*H;
end
plant.K=(plant.K+plant.K')/2; plant.C=(plant.C+plant.C')/2;
% 대칭화는 부동소수점 오차를 정리하고, 양의 정부호 검사는 에너지의
% 부호가 잘못되거나 저항 대신 에너지를 만드는 비정상 설정을 잡습니다.
[~,mflag]=chol(plant.M); [~,kflag]=chol(plant.K); [~,cflag]=chol(plant.C);
assert(mflag==0 && kflag==0 && cflag==0, ...
    'vib3d:Passivity','Mass, stiffness and damping must be positive definite.');
plant.A=[zeros(6),eye(6); -(plant.M\plant.K),-(plant.M\plant.C)];
% [주3] 상태 x=[q;qdot]는 12×1입니다. 2차 미분식을 xdot=A*x+B*w로
% 바꾸면 MATLAB과 Simulink가 같은 순서의 상태를 적분할 수 있습니다.
plant.B=[zeros(6);plant.M\eye(6)];
plant.sensor_map=[eye(3),-skew3(p.geometry.sensor_position)];
% 센서 가속도는 무게중심 가속도에 각가속도×센서 위치를 더한 값입니다.
% 작은 각도 모델이므로 각속도 제곱의 원심항 등 2차 항은 생략합니다.
plant.Cacc=plant.sensor_map*plant.A(7:12,:);
plant.Dacc=plant.sensor_map*plant.B(7:12,:);
% Accelerometer reports specific force R'*(a_world-g_world).
% First order: f=a_sensor+[ -g*pitch; +g*roll; g ]. Rotating a_sensor,
% centripetal terms and products of perturbations are second order, omitted.
plant.Cgravity=zeros(3,12);
% [주4] 동적 가속도 acc와 가속도계의 비력(specific force)은 다릅니다.
% 가속도계는 정지 상태에서도 Z에 +1 g를 읽으며, 기울어지면 중력이
% X/Y축으로 투영됩니다. 여기서는 1차 근사 [-g*pitch; g*roll; g]입니다.
plant.Cgravity(1,5)=-p.gravity; plant.Cgravity(2,4)=p.gravity;
plant.Cspecific=plant.Cacc+plant.Cgravity;
plant.Dspecific=plant.Dacc;
plant.gravity_offset=[0;0;p.gravity];
E=expm([plant.A plant.B;zeros(6,18)]*p.dt);
% [주5] 행렬지수로 정확한 ZOH 이산화를 구합니다. ZOH는 한 샘플 동안
% 외력이 일정하다는 뜻입니다. 그 조건의 해는 정확하지만 실제 연속 외력이
% 샘플 사이에서도 바뀌는 효과까지 정확해지는 것은 아닙니다.
plant.Ad=E(1:12,1:12); plant.Bd=E(1:12,13:18);
[V,D]=eig(plant.K,plant.M);
% [주6] K*phi=omega^2*M*phi의 고유값은 고유진동수, 벡터는 진동 모양입니다.
% 모드를 질량 기준으로 정규화해 비교합니다. 투영 감쇠비는 모드 간
% 감쇠 결합이 존재할 때 완전히 독립된 각 모드의 정확한 감쇠비와 다를 수 있습니다.
[lambda,idx]=sort(real(diag(D)));
V=real(V(:,idx));
for k=1:6
    V(:,k)=V(:,k)/sqrt(V(:,k)'*plant.M*V(:,k));
    [~,j]=max(abs(V(:,k))); if V(j,k)<0, V(:,k)=-V(:,k); end
end
plant.modes=V;
plant.modal_hz=sqrt(lambda)/(2*pi);
plant.modal_damping=diag(V'*plant.C*V)./(2*sqrt(lambda));
plant.modal_damping_matrix=V'*plant.C*V;
plant.poles=eig(plant.A);
plant.state_order={'x','y','z','roll','pitch','yaw', ...
                   'vx','vy','vz','roll_rate','pitch_rate','yaw_rate'};
end

function S=skew3(r)
r=r(:); S=[0 -r(3) r(2);r(3) 0 -r(1);-r(2) r(1) 0];
end
