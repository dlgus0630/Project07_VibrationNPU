function study = RUN_RESEARCH_STUDY(scenario,options)
% 가정 기반 연구 스터디의 시작점: 물리식 -> 가상 센서 -> FFT/NPU -> 3D 표시.
% 입력 scenario: normal/unbalance/misalignment/ripple, 'all'이면 네 조건을 비교한다.
% 입력 options: 그림·동영상·Simulink 실행과 물리 파라미터를 선택하는 구조체.
% 출력 study: 조건별 요약, 자체 검사 결과, 파라미터와 저장 위치를 모은 구조체.
% [주1] 질량·강성·감쇠·가진력은 연구용 가정이다. 실측만 보려면 RUN_MEASURED_STUDY를 쓴다.
% [주2] 6자유도는 X/Y/Z 이동과 roll/pitch/yaw 회전이다. 상태에는 각각의 속도도 있어 총 12개다.
%RUN_RESEARCH_STUDY Six-DOF MATLAB/Simulink vibration research and 3D playback.
% RUN_RESEARCH_STUDY('all')
% RUN_RESEARCH_STUDY('unbalance',struct('ExportVideo',true))
% RUN_RESEARCH_STUDY('all',struct('BuildSimulink',false,'Visible','off'))
% See docs/MATLAB_SIMULINK_RESEARCH.md. No hardware PASS gate is modified.
if nargin<1 || isempty(scenario), scenario='all'; end
if nargin<2, options=struct; end
options=defaults(options);
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'matlab'),fullfile(root,'matlab','research'));
outdir=fullfile(root,'reports','research');
if ~exist(outdir,'dir'), mkdir(outdir); end
if isempty(options.Parameters), p=vib3d_parameters(); else, p=options.Parameters; end
% p는 파라미터 묶음이다. 단위를 함께 확인해야 다른 질량/강성 조건을 물리적으로 비교할 수 있다.
assert(p.fs==1000 && p.nfft==64 && abs(p.dt-1/p.fs)<1e-12,...
    'Research:SampleContract','The research inference model requires 1 kHz and 64-sample frames.');
allscenarios={'normal','unbalance','misalignment','ripple'};
if strcmpi(scenario,'all'), scenarios=allscenarios;
else
    scenario=validatestring(scenario,allscenarios); scenarios={scenario};
end
status=struct('status','RUNNING','started',datestr(now,30),...
    'matlab_version',version,'scenarios',{scenarios},'simulation_origin','illustrative synthetic mechanics',...
    'simulink','NOT_RUN','hardware_gate_modified',false);
statusfile=fullfile(outdir,'research_run_status.json'); write_json(statusfile,status);
try
    status.source_sha256=source_digest(root);
    % 1. 물리식의 수치 일관성과 기존 정수 연산 계약부터 검사한다.
    % 자체 검사 통과는 가정한 모델이 실제 모터와 일치한다는 뜻은 아니다.
    physics_tests=vib3d_self_test(p);
    pipeline_tests=vib3d_pipeline_self_test(root);
    save(fullfile(outdir,'self_tests.mat'),'physics_tests','pipeline_tests');
    writetable(physics_tests.checks,fullfile(outdir,'physical_self_tests.csv'));
    plant=vib3d_plant_matrices(p);
    % plant에는 연속 운동방정식과 한 샘플씩 계산할 이산 행렬이 함께 들어 있다.
    M=jsondecode(fileread(fullfile(root,'data','model.json')));
    can_simulate=options.BuildSimulink && ~isempty(which('new_system')) && license('test','Simulink');
    if options.BuildSimulink && ~can_simulate
        status.simulink='UNAVAILABLE';
        warning('Research:NoSimulink','Simulink unavailable: MATLAB mechanics/analysis/3D will run; model validation is NOT RUN.');
    elseif ~options.BuildSimulink
        status.simulink='DISABLED';
    end
    if can_simulate
        % 이동·삭제된 이전 프로젝트 폴더 때문에 getConfig가 실패해도
        % 현재 스터디 폴더를 지정할 수 있도록 유효한 설정만 보관한다.
        oldConfig=[];
        try
            oldConfig=Simulink.fileGenControl('getConfig');
        catch previousConfigError
            warning('Research:PreviousFileGenConfig',...
                'Previous Simulink file-generation configuration could not be read; using this study folder. %s',...
                previousConfigError.message);
        end
        Simulink.fileGenControl('set','CacheFolder',fullfile(outdir,'sim_cache'),...
            'CodeGenFolder',fullfile(outdir,'sim_codegen'),'keepPreviousPath',false,'createDir',true);
        if ~isempty(oldConfig)
            configCleanup=onCleanup(@()Simulink.fileGenControl('setConfig','config',oldConfig)); %#ok<NASGU>
        end
    end
    study=struct('parameters',p,'physics_tests',physics_tests,'pipeline_tests',pipeline_tests,...
        'scenarios',{scenarios},'output_directory',outdir,'results',struct);
    comparison=zeros(numel(scenarios),8);
    for s=1:numel(scenarios)
        name=scenarios{s}; folder=fullfile(outdir,name);
        if ~exist(folder,'dir'), mkdir(folder); end
        fprintf('Research %d/%d: %s\n',s,numel(scenarios),name);
        input=vib3d_excitation(p,name);
        % 2. 조건별 힘/토크를 만들고, 그 힘에 대한 하우징 운동과 센서 출력을 계산한다.
        result=vib3d_classify(vib3d_simulate(p,input),p,M);
        % 3. 물리 해석과 분류를 구분한다. 실제 X축으로 학습한 NPU에 가상 신호를 넣는 실험이다.
        analysis=vib3d_analyze(p,plant,result,folder);
        export_pipeline(result,folder);
        validation=struct('status','NOT_RUN');
        if can_simulate
            if s==1
                study.model_path=build_research_model(outdir,p,plant,result,M);
            end
            validation=validate_simulink(p,result,folder);
            % 4. 같은 입력의 MATLAB 계산과 Simulink 계산을 비교하여 구현 차이를 찾는다.
        end
        summary=struct('scenario',name,'origin','SYNTHETIC_UNCALIBRATED',...
            'sample_rate_hz',p.fs,'frame_size',64,'frame_period_s',64/p.fs,...
            'frames',numel(result.classes),'class1_fraction',mean(result.classes),...
            'accuracy','NOT_APPLICABLE_SYNTHETIC_DOMAIN_SHIFT',...
            'max_fft_error_lsb',max(result.fft_error_lsb),...
            'max_angle_rad',analysis.max_angle_rad,...
            'small_angle_assumption_ok',analysis.small_angle_assumption_ok,...
            'simulink',validation,'safety_is_observer_only',true);
        save(fullfile(folder,'results.mat'),'p','input','result','analysis','validation');
        write_json(fullfile(folder,'run_summary.json'),summary);
        if options.Animate
            % 5. 계산된 상태를 그림으로 재생한다. 확대배율은 화면에만 적용되고 결과 값은 유지된다.
            display_result=result;
            % Playback uses the actual Simulink state/acceleration when available.
            if can_simulate
                traces=load(fullfile(folder,'simulink_traces.mat'),'state','accel');
                display_result.q=traces.state(:,1:6); display_result.qd=traces.state(:,7:12);
                display_result.accel=traces.accel;
            end
            animation_options=struct('visible',options.Visible,'exportVideo',options.ExportVideo,...
                'maxFrames',options.MaxFrames,'motionScale',options.MotionScale);
            animate_vibration_3d(display_result,p,folder,animation_options);
        end
        study.results.(name)=summary;
        comparison(s,:)=[analysis.metrics.DynamicRMS_m_s2',1e6*analysis.rms_displacement,...
            mean(result.classes),max(result.fft_error_lsb)];
    end
    comparison_table=[table(scenarios','VariableNames',{'Scenario'}),...
        array2table(comparison,'VariableNames',{'AccelRMS_X','AccelRMS_Y','AccelRMS_Z',...
        'DisplacementRMS_X_um','DisplacementRMS_Y_um','DisplacementRMS_Z_um',...
        'Synthetic_Class1Fraction','FFT_MaxError_LSB'})];
    writetable(comparison_table,fullfile(outdir,'comparison.csv'));
    plot_comparison(comparison,scenarios,outdir);
    study.comparison=comparison_table;
    assert(strcmp(status.source_sha256,source_digest(root)),...
        'Research:SourceChanged','Source changed during this study; rerun for reproducibility.');
    status.status='COMPLETED'; status.completed=datestr(now,30);
    if can_simulate
        status.simulink='PASSED_MATLAB_REFERENCE_COMPARISON';
        try
            print('-svibration_npu_3d','-dpng','-r150',fullfile(outdir,'simulink_architecture.png'));
        catch exportError
            warning('Research:DiagramExport','Model passed; diagram PNG export failed: %s',exportError.message);
        end
        if strcmpi(options.Visible,'on'), open_system('vibration_npu_3d');
        else, close_system('vibration_npu_3d',0); end
    end
    write_json(statusfile,status); study.status=status;
    save(fullfile(outdir,'study_summary.mat'),'study');
    fprintf('Research outputs: %s\nSimulink: %s\n',outdir,status.simulink);
    fprintf('Synthetic study only. Existing RUN_MATLAB_CHECKS remains the hardware Golden gate.\n');
catch failure
    % 계산/검증에 실패하면 원인을 저장한다. 일부 그림이 생겼어도 전체 통과로 표시하지 않는다.
    status.status='FAILED'; status.error_identifier=failure.identifier;
    status.error_message=failure.message; write_json(statusfile,status);
    rethrow(failure);
end
end

function options=defaults(options)
% 옵션의 기본값을 채우고 잘못 쓴 이름을 검출한다. Parameters로 p 전체를 바꿔 실험할 수 있다.
assert(isstruct(options) && isscalar(options),'Options must be a scalar struct.');
d=struct('BuildSimulink',true,'Animate',true,'ExportVideo',false,...
    'Visible','on','MaxFrames',240,'MotionScale',30,'Parameters',[]);
unknown=setdiff(fieldnames(options),fieldnames(d));
assert(isempty(unknown),'Research:Options','Unknown option: %s',strjoin(unknown,', '));
names=fieldnames(d);
for k=1:numel(names)
    if ~isfield(options,names{k}), options.(names{k})=d.(names{k}); end
end
flags={'BuildSimulink','Animate','ExportVideo'};
for k=1:numel(flags)
    validateattributes(options.(flags{k}),{'logical','numeric'},{'scalar','binary'});
end
options.Visible=validatestring(options.Visible,{'on','off'});
assert(~options.ExportVideo || options.Animate,'ExportVideo requires Animate=true.');
end

function validation=validate_simulink(p,result,folder)
% [주3] 비교 대상: 12개 운동 상태, XYZ 가속도/정수 센서값, 프레임 완료 시점, 특징/NPU/정책.
% 운동 상태는 부동소수점 허용오차로, 정수 추론 결과는 정확한 일치로 검사한다.
mdl='vibration_npu_3d'; si=Simulink.SimulationInput(mdl);
si=si.setVariable('wrench_data',[result.t result.wrench],'Workspace',mdl);
si=si.setVariable('noise_data',[result.t result.sensor_noise],'Workspace',mdl);
si=si.setVariable('heartbeat_data',[result.t double(result.heartbeat)],'Workspace',mdl);
si=si.setModelParameter('StopTime',num2str(result.t(end),17));
out=sim(si); n=numel(result.t);
state=read_log(out,'sl_state',n,12,result.t); accel=read_log(out,'sl_accel',n,3,result.t);
raw=read_log(out,'sl_raw',n,3,result.t); valid=read_log(out,'sl_valid',n,1,result.t);
features=read_log(out,'sl_features',n,4,result.t); hidden=read_log(out,'sl_hidden',n,4,result.t);
logits=read_log(out,'sl_logits',n,2,result.t); classes=read_log(out,'sl_class',n,1,result.t);
safety=read_log(out,'sl_safety',n,7,result.t);
state_error=max(abs(state(:)-reshape([result.q result.qd],[],1)));
accel_error=max(abs(accel(:)-result.accel(:)));
assert(state_error<1e-10 && accel_error<1e-8,...
    'Research:PlantMismatch','Simulink mechanics differ from MATLAB.');
assert(isequal(raw,double(result.raw)),'Research:SensorMismatch','Raw XYZ mismatch.');
idx=find(valid~=0);
assert(isequal(idx,result.frame_index),'Research:FramingMismatch','Frame timing mismatch.');
assert(isequal(features(idx,:),result.features) && isequal(hidden(idx,:),result.hidden)...
    && isequal(logits(idx,:),result.logits) && isequal(classes(idx,:),result.classes),...
    'Research:InferenceMismatch','Completed-frame integer inference mismatch.');
assert(isequal(safety,result.safety),'Research:PolicyMismatch','Sampled safety observer mismatch.');
validation=struct('status','PASSED','samples',n,'frames',numel(idx),...
    'state_max_abs_error',state_error,'accel_max_abs_error',accel_error,...
    'sensor_integer_exact',true,'inference_integer_exact',true,'sampled_policy_exact',true,...
    'sample_period_s',p.dt);
save(fullfile(folder,'simulink_traces.mat'),'state','accel','raw','valid',...
    'features','hidden','logits','classes','safety');
end

function x=read_log(out,name,n,width,time)
% 데이터 값뿐 아니라 저장된 시각과 행렬 크기도 검사한다. 한 샘플 밀림도 다른 결과이기 때문이다.
ts=out.get(name);
assert(isa(ts,'timeseries'),'Expected timeseries log: %s',name);
assert(numel(ts.Time)==n && max(abs(ts.Time(:)-time))<1e-10,...
    'Research:LoggingTime','Unexpected sampling in %s.',name);
x=double(squeeze(ts.Data));
if isequal(size(x),[width,n]) && width~=n, x=x'; end
assert(isequal(size(x),[n,width]),'Research:LoggingShape','Unexpected shape in %s.',name);
end

function export_pipeline(r,folder)
% [주4] 특징 -> logit -> class -> 안전 정책의 순서를 CSV와 그림으로 따라가게 한다.
% 정책은 관찰용이다. latch가 서도 이미 정해 둔 가상 가진력을 멈추는 폐루프가 아니다.
frames=[r.frame_index r.frame_time r.features r.hidden r.logits r.classes r.fft_error_lsb];
writetable(array2table(frames,'VariableNames',{'EndSample','Time_s','Feature1','Feature2','Feature3','Feature4',...
    'Hidden1','Hidden2','Hidden3','Hidden4','Logit0','Logit1','PredictedClass','FFT_Error_LSB'}),...
    fullfile(folder,'pipeline_frames.csv'));
writetable(array2table([r.t r.safety],'VariableNames',{'Time_s','Consecutive','Warning',...
    'Derated','Latched','FaultCause','AllowedDutyObserver','AbnormalLifetime'}),...
    fullfile(folder,'safety_observer.csv'));
fig=figure('Visible','off','Color','w','Position',[80 80 1250 850]);
cleanup=onCleanup(@()close(fig)); %#ok<NASGU>
subplot(3,2,1); stairs(r.frame_time,r.features); grid on;
ylabel('INT8 feature (0..127)'); xlabel('Frame completion (s)'); legend('B1','B2','B3','B4');
title([r.scenario ' | synthetic X-axis -> deployed model']);
subplot(3,2,2); stairs(r.frame_time,r.logits); grid on;
ylabel('INT8 logit'); xlabel('Time (s)'); legend('Normal','Injected fault');
subplot(3,2,3); stairs(r.frame_time,r.classes); ylim([-0.1 1.1]); grid on;
xlabel('Time (s)'); ylabel('Class'); title('Domain-shift probe; not fault accuracy');
subplot(3,2,4); stairs(r.t,r.safety(:,2:4)); grid on;
legend('Warning','Derated','Latched'); xlabel('Time (s)'); ylabel('Policy state');
subplot(3,2,5); plot(r.frame_time,r.fft_error_lsb); grid on;
xlabel('Time (s)'); ylabel('Max complex FFT error (count)'); title('Fixed FFT versus floating FFT/64');
subplot(3,2,6); stairs(r.t,100*r.safety(:,6)); grid on; ylim([-2 55]);
xlabel('Time (s)'); ylabel('Allowed duty (%)'); title('Observer only; prescribed forcing continues');
print(fig,fullfile(folder,'inference_and_policy.png'),'-dpng','-r150');
end

function plot_comparison(values,scenarios,outdir)
% 조건별 가속도/변위 RMS를 나란히 비교한다. RMS는 진동의 평균적인 크기를 나타낸다.
fig=figure('Visible','off','Color','w','Position',[80 80 1200 450]);
cleanup=onCleanup(@()close(fig)); %#ok<NASGU>
subplot(1,2,1); bar(values(:,1:3)); grid on;
set(gca,'XTick',1:numel(scenarios),'XTickLabel',scenarios);
ylabel('Dynamic sensor RMS (m/s^2)'); legend('X','Y','Z'); title('Illustrative scenario comparison');
subplot(1,2,2); bar(values(:,4:6)); grid on;
set(gca,'XTick',1:numel(scenarios),'XTickLabel',scenarios);
ylabel('CG displacement RMS (um)'); legend('X','Y','Z');
print(fig,fullfile(outdir,'scenario_comparison.png'),'-dpng','-r150');
end

function write_json(path,value)
% 결과 상태를 JSON으로 저장한다. 'COMPLETED'와 Simulink 실행 여부는 따로 읽어야 한다.
f=fopen(path,'w'); assert(f>=0,'Cannot write %s.',path);
cleanup=onCleanup(@()fclose(f)); %#ok<NASGU>
fprintf(f,'%s\n',jsonencode(value,'PrettyPrint',true));
end
