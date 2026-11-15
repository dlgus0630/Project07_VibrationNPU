function analysis = vib3d_analyze(p,plant,result,outdir)
% [읽기 안내] 6자유도 합성 응답을 통계·주파수·모드 관점으로 정리합니다.
% 입력 p/plant는 모델 설정·행렬, result는 시간 이력, outdir는 저장 폴더입니다.
% 출력 analysis와 CSV/그림에는 가속도(m/s^2), 주파수(Hz), 변위(m) 등을 남깁니다.
% [주1] 실제 계측 데이터에 맞춘 결과가 아니라 가정한 모델의 특성을 분석합니다.
%VIB3D_ANALYZE Reproducible physical diagnostics, independent of NPU labels.
% All figures and CSVs describe synthetic dynamics, not measured accuracy.
if ~exist(outdir,'dir'), mkdir(outdir); end
keep=result.t>=p.analysis.discard_seconds;
assert(nnz(keep)>=8,'vib3d:AnalysisWindow', ...
    'Need >=8 samples after p.analysis.discard_seconds.');
t=result.t(keep); a=result.accel(keep,:);
centered=bsxfun(@minus,a,mean(a,1));
% [주2] 초기 과도 구간을 제외하고 각 축 평균을 뺀 뒤 진동 크기를 계산합니다.
% RMS는 평균적인 세기, crest=peak/RMS는 순간 피크의 두드러짐을 나타냅니다.
% kurt는 Pearson 첨도이며 가우시안 분포의 기준값은 3입니다(초과 첨도와 구분).
rmsacc=sqrt(mean(centered.^2,1));
peak=max(abs(centered),[],1);
crest=peak./max(rmsacc,eps);
kurt=mean(centered.^4,1)./max(mean(centered.^2,1).^2,eps);
spec=vib3d_spectral(a,p.fs,p.analysis.segment_length,p.analysis.overlap_fraction);
% 긴 창의 Welch PSD는 주파수 구조를, 짧은 창의 STFT는 시간 변화를 봅니다.
% 여기의 입력은 중력·합성 잡음을 제외한 동적 가속도 result.accel입니다.
stft=vib3d_spectral(result.accel,p.fs,256,0.875);
[~,imax]=max(spec.psd(2:end,:),[],1);
peakfreq=spec.frequency(imax+1);
satpercent=100*mean(result.saturated(keep,:),1);
metrics=table({'X';'Y';'Z'},rmsacc',peak',crest',kurt',peakfreq(:), ...
    satpercent','VariableNames',{'Axis','DynamicRMS_m_s2','DynamicPeak_m_s2', ...
    'CrestFactor','PearsonKurtosis','PeakPSD_Hz','SaturatedPercent'});
writetable(metrics,fullfile(outdir,'axis_metrics.csv'));
modeTable=table((1:6)',plant.modal_hz,plant.modal_damping, ...
    'VariableNames',{'Mode','UndampedFrequency_Hz','ProjectedDampingRatio'});
modeTable=[modeTable,array2table(plant.modes', ...
    'VariableNames',{'Shape_x','Shape_y','Shape_z','Shape_roll','Shape_pitch','Shape_yaw'})];
writetable(modeTable,fullfile(outdir,'modal_properties.csv'));
poleTable=table(real(plant.poles),imag(plant.poles),abs(plant.poles)/(2*pi), ...
    -real(plant.poles)./abs(plant.poles), ...
    'VariableNames',{'Real_rad_s','Imag_rad_s','NaturalFrequency_Hz','DampingRatio'});
writetable(poleTable,fullfile(outdir,'state_poles.csv'));
writetable(array2table([spec.frequency,spec.psd], ...
    'VariableNames',{'Frequency_Hz','PSD_X','PSD_Y','PSD_Z'}),fullfile(outdir,'welch_psd.csv'));

% Physical FRF from a unit CG force along one selected axis to sensor accel.
% [주3] FRF는 무게중심의 한 축에 1 N 정현파 힘을 가했을 때의 센서 응답입니다.
% H=C*(j*omega*I-A)^(-1)*B+D이며 단위는 (m/s^2)/N입니다.
% 현재 시나리오의 FFT를 나눈 실험 전달함수가 아니라 모델 행렬에서 구한 값입니다.
frequency=linspace(0,min(450,p.fs*0.45),2001)';
H=zeros(numel(frequency),3); axisIndex=p.analysis.frf_force_axis;
assert(ismember(axisIndex,1:3),'FRF excitation must be a translational force.');
for k=1:numel(frequency)
    H(k,:)=(plant.Cacc*((1i*2*pi*frequency(k)*eye(12)-plant.A) ...
        \plant.B(:,axisIndex))+plant.Dacc(:,axisIndex)).';
end
frfTable=array2table([frequency,real(H),imag(H),abs(H)], ...
    'VariableNames',{'Frequency_Hz','Real_X','Real_Y','Real_Z', ...
    'Imag_X','Imag_Y','Imag_Z','Magnitude_X','Magnitude_Y','Magnitude_Z'});
writetable(frfTable,fullfile(outdir,'force_to_sensor_accel_frf.csv'));

% CSV of the entire trace supports independent checks in Python/Octave.
trace=[result.t,result.q,result.qd,result.accel,result.specific_force, ...
    double(result.raw),result.wrench,result.rpm];
traceNames={'Time_s','x_m','y_m','z_m','roll_rad','pitch_rad','yaw_rad', ...
    'vx_m_s','vy_m_s','vz_m_s','rollRate_rad_s','pitchRate_rad_s','yawRate_rad_s', ...
    'AccelX_m_s2','AccelY_m_s2','AccelZ_m_s2','SpecificX_m_s2','SpecificY_m_s2', ...
    'SpecificZ_m_s2','RawX_count','RawY_count','RawZ_count','Fx_N','Fy_N','Fz_N', ...
    'Tx_Nm','Ty_Nm','Tz_Nm','RotorRPM'};
writetable(array2table(trace,'VariableNames',traceNames),fullfile(outdir,'time_history.csv'));

analysis.metrics=metrics; analysis.modal=modeTable;
analysis.poles=poleTable; analysis.psd=spec; analysis.stft=stft;
analysis.frf.frequency=frequency; analysis.frf.acceleration=H;
analysis.frf.input_axis=axisIndex;
analysis.sensitivity=sensitivity_study(p);
% [주4] 질량·강성·감쇠를 한 종류씩 바꿔 모델의 민감도를 봅니다.
% 불확실성의 실제 확률분포를 측정한 결과나 통계적 신뢰구간은 아닙니다.
writetable(analysis.sensitivity,fullfile(outdir,'parameter_sensitivity.csv'));
analysis.rms_displacement=sqrt(mean(result.q(keep,1:3).^2,1));
analysis.max_angle_rad=max(max(abs(result.q(:,4:6))));
analysis.small_angle_assumption_ok=analysis.max_angle_rad<0.05;
% 0.05 rad 미만인지는 작은 각도 가정의 간단한 점검 기준입니다.
% 이 기준 통과만으로 모델과 실제 장비가 일치함을 보장하지는 않습니다.
analysis.welch_metadata=table(spec.segment_length,spec.hop,spec.segments, ...
    spec.df,spec.enbw_hz,p.analysis.discard_seconds, ...
    'VariableNames',{'SegmentSamples','HopSamples','Segments', ...
    'BinSpacing_Hz','HannENBW_Hz','DiscardSeconds'});
writetable(analysis.welch_metadata,fullfile(outdir,'spectral_metadata.csv'));

fig=figure('Visible','off','Color','w','Position',[100 100 1400 980]);
cleanup=onCleanup(@() close(fig));
subplot(3,2,1); plot(result.t,1e6*result.q(:,1:3)); grid on;
xlabel('Time (s)'); ylabel('CG translation (um)'); legend('X','Y','Z');
title([result.scenario ': synthetic 6-DOF housing response']);
subplot(3,2,2); plot(result.t,1e3*result.q(:,4:6)); grid on;
xlabel('Time (s)'); ylabel('Rotation (mrad)'); legend('roll','pitch','yaw');
subplot(3,2,3); plot(result.t,result.accel); grid on;
xlabel('Time (s)'); ylabel('Dynamic sensor acceleration (m/s^2)'); legend('X','Y','Z');
subplot(3,2,4); plot(result.t,double(result.raw)); grid on;
xlabel('Time (s)'); ylabel('Specific force (signed ADC count)'); legend('X','Y','Z');
subplot(3,2,5); plot3(1e6*result.q(keep,1),1e6*result.q(keep,2), ...
    1e6*result.q(keep,3)); grid on; axis equal; view(40,25);
xlabel('X (um)'); ylabel('Y (um)'); zlabel('Z (um)'); title('CG orbit after transient');
subplot(3,2,6); plot(result.t,result.rpm); grid on;
xlabel('Time (s)'); ylabel('Prescribed rotor RPM');
title('Illustrative input speed; not measured gearbox RPM');
write_figure(fig,outdir,'response_and_orbit.png'); clear cleanup;

fig=figure('Visible','off','Color','w','Position',[100 100 1400 950]);
cleanup=onCleanup(@() close(fig));
subplot(2,2,1); semilogy(spec.frequency,max(spec.psd,realmin)); grid on;
xlim([0 min(250,p.fs/2)]); xlabel('Frequency (Hz)');
ylabel('PSD ((m/s^2)^2/Hz)'); legend('X','Y','Z');
title(sprintf('Welch: %d samples, %.3f Hz bins, ENBW %.3f Hz', ...
    spec.segment_length,spec.df,spec.enbw_hz));
subplot(2,2,2); semilogy(frequency,max(abs(H),realmin)); grid on;
xlim([0 250]); xlabel('Frequency (Hz)'); ylabel('|a/F| ((m/s^2)/N)');
legend('X sensor','Y sensor','Z sensor'); title(sprintf('CG force axis %d -> sensor FRF',axisIndex));
subplot(2,2,3); plot(frequency,unwrap(angle(H),[],1)*180/pi); grid on;
xlim([0 250]); xlabel('Frequency (Hz)'); ylabel('FRF phase (deg)');
legend('X sensor','Y sensor','Z sensor');
subplot(2,2,4); plot(result.t,result.energy); grid on;
xlabel('Time (s)'); ylabel('Mechanical perturbation energy (J)');
title('E=0.5 qdot^T M qdot + 0.5 q^T K q');
write_figure(fig,outdir,'spectra_frf_energy.png'); clear cleanup;

fig=figure('Visible','off','Color','w','Position',[100 100 1400 950]);
cleanup=onCleanup(@() close(fig)); axisNames={'X','Y','Z'};
% [주5] STFT의 색은 전력밀도의 10*log10 값입니다. 진폭의 20*log10과 구분합니다.
% 겹쳐 그린 rpm/60과 rpm/30은 회전 기본 주파수(1차)와 두 배(2차) 궤적입니다.
for j=1:3
    subplot(3,1,j);
    imagesc(stft.time,stft.frequency,10*log10(max(stft.stft_psd(:,:,j),1e-14)));
    axis xy; ylim([0 180]); caxis([-100 10]); colorbar; hold on;
    plot(result.t,result.rpm/60,'w--','LineWidth',1.1);
    plot(result.t,result.rpm/30,'w:','LineWidth',1.1);
    ylabel('Frequency (Hz)'); xlabel('Time (s)');
    title(sprintf('%s dynamic acceleration STFT; dB re (m/s^2)^2/Hz; dashed 1x, dotted 2x',axisNames{j}));
end
write_figure(fig,outdir,'stft_rotor_orders.png'); clear cleanup;

plot_modes(p,plant,outdir);
fig=figure('Visible','off','Color','w','Position',[100 100 1400 430]);
cleanup=onCleanup(@() close(fig)); variables={'mass','stiffness','damping'};
for j=1:3
    subplot(1,3,j); rows=strcmp(analysis.sensitivity.Parameter,variables{j});
    plot(analysis.sensitivity.Factor(rows),analysis.sensitivity{rows,3:8},'-o'); grid on;
    xlabel([variables{j} ' scale']); ylabel('Undamped frequency (Hz)'); title('One-factor-at-a-time sensitivity');
end
legend('Mode 1','Mode 2','Mode 3','Mode 4','Mode 5','Mode 6','Location','best');
write_figure(fig,outdir,'modal_parameter_sensitivity.png'); clear cleanup;
analysis.output_directory=outdir;
save(fullfile(outdir,'physical_analysis.mat'),'analysis','p','plant');
end

function output=sensitivity_study(p)
% 질량을 바꿀 때 관성도 같은 비율로 바꿔 같은 형상의 밀도 변화를 가정합니다.
% 무감쇠 고유진동수는 M/K로 결정되므로 C만 바꾸어도 해당 주파수는 바뀌지 않습니다.
names={'mass','stiffness','damping'}; factors=p.analysis.sensitivity_factors;
labels=cell(3*numel(factors),1); numbers=zeros(3*numel(factors),14); row=0;
for j=1:3
    for k=1:numel(factors)
        row=row+1; variant=p; factor=factors(k);
        switch names{j}
            case 'mass', variant.mass=p.mass*factor; variant.inertia=p.inertia*factor;
            case 'stiffness', variant.mount.stiffness=p.mount.stiffness*factor;
            case 'damping', variant.mount.damping=p.mount.damping*factor;
        end
        plant=vib3d_plant_matrices(variant);
        f=p.rotor.rpm_final/60;
        H=plant.Cacc*((2i*pi*f*eye(12)-plant.A)\plant.B(:,p.analysis.frf_force_axis)) ...
            +plant.Dacc(:,p.analysis.frf_force_axis);
        labels{row}=names{j};
        numbers(row,:)=[factor,plant.modal_hz',plant.modal_damping',norm(H)];
    end
end
output=[table(labels,'VariableNames',{'Parameter'}),array2table(numbers, ...
    'VariableNames',{'Factor','Mode1_Hz','Mode2_Hz','Mode3_Hz','Mode4_Hz','Mode5_Hz', ...
    'Mode6_Hz','Zeta1','Zeta2','Zeta3','Zeta4','Zeta5','Zeta6','NominalRotorFRFNorm_m_s2_N'})];
end

function plot_modes(p,plant,outdir)
% [주6] 모드 그림은 고유벡터의 방향과 상대 움직임을 보여 줍니다.
% 각 모드를 개별 확대하므로 그림 크기는 실제 진동 진폭이나 모드 간 세기가 아닙니다.
fig=figure('Visible','off','Color','w','Position',[100 100 1400 850]);
cleanup=onCleanup(@() close(fig));
d=p.geometry.body_size/2;
corners=[-1 -1 -1;1 -1 -1;1 1 -1;-1 1 -1;-1 -1 1;1 -1 1;1 1 1;-1 1 1].*d;
edges=[1 2;2 3;3 4;4 1;5 6;6 7;7 8;8 5;1 5;2 6;3 7;4 8];
for k=1:6
    subplot(2,3,k); hold on;
    phi=plant.modes(:,k); displacement=zeros(8,3);
    for j=1:8, displacement(j,:)=phi(1:3)'+cross(phi(4:6)',corners(j,:)); end
    % Each mode receives its own graphical scale; not a physical amplitude.
    displacement=displacement*(0.020/max(sqrt(sum(displacement.^2,2))));
    for j=1:size(edges,1)
        e=edges(j,:); line(corners(e,1),corners(e,2),corners(e,3),'Color',[.7 .7 .7]);
        deformed=corners(e,:)+displacement(e,:);
        line(deformed(:,1),deformed(:,2),deformed(:,3),'Color',[.1 .35 .8],'LineWidth',1.4);
    end
    quiver3(corners(:,1),corners(:,2),corners(:,3),displacement(:,1), ...
        displacement(:,2),displacement(:,3),0,'Color',[.8 .2 .15]);
    scatter3(p.geometry.mount_points(:,1),p.geometry.mount_points(:,2), ...
        p.geometry.mount_points(:,3),30,'k','filled');
    axis equal; grid on; view(35,25); xlabel('X (m)'); ylabel('Y (m)'); zlabel('Z (m)');
    title(sprintf('Mode %d: %.2f Hz, projected zeta=%.3f\nindependent display scale', ...
        k,plant.modal_hz(k),plant.modal_damping(k)));
end
write_figure(fig,outdir,'six_rigid_body_modes.png');
end

function write_figure(fig,outdir,name)
set(fig,'PaperPositionMode','auto');
print(fig,fullfile(outdir,name),'-dpng','-r150');
end
