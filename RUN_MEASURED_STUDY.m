function study=RUN_MEASURED_STUDY(options)
% 실측 스터디의 시작점: 저장된 원본 확인 -> 분석 -> Simulink 재생 비교 -> 저장.
% 입력 options: 실행 선택 사항을 담은 구조체. 생략하면 진동과 모터를 모두 분석한다.
% 출력 study: 분석 표, 검증 결과, 사용한 파일 해시, 결과 폴더를 묶은 구조체.
% 처음에는 이 함수의 본문을 읽고 load_ -> analyze_ -> validate_ 순서로 따라간다.
% [주1] 여기는 실제 기록의 재현 경로다. 원본에 없는 XYZ 운동을 추정하지 않는다.
% [주2] 아래 PASSED는 해당 비교를 실제로 실행한 뒤에만 기록된다.
%RUN_MEASURED_STUDY Second study: original measured records only.
% RUN_MEASURED_STUDY
% RUN_MEASURED_STUDY(struct('BuildSimulink',false,'Visible','off'))
% No synthetic inputs, parameterized plant, interpolation or missing XYZ axes.
% See docs/MATLAB_SIMULINK_MEASURED.md. No hardware PASS marker is written.
if nargin<1, options=struct; end
% nargin은 전달된 인수 개수다. options를 안 주었으면 기본 선택 사항을 채운다.
options=defaults(options);
root=fileparts(mfilename('fullpath'));
% 현재 작업 폴더가 달라도 이 파일이 놓인 프로젝트를 기준으로 함수를 찾는다.
addpath(fullfile(root,'matlab'),fullfile(root,'matlab','measured'));
outdir=fullfile(root,'reports','measured');
if ~isfolder(outdir), mkdir(outdir); end
status=struct('status','RUNNING','started',datestr(now,30),'matlab_version',version,...
    'input_origin','RECORDED_HARDWARE_ONLY','simulink','NOT_RUN',...
    'synthetic_input_used',false,'hardware_gate_modified',false);
statuspath=fullfile(outdir,'measured_run_status.json'); write_json(statuspath,status);
try
    % 1. 원본 검증: CSV 내용과 수집 당시의 JSON/해시가 일치해야 다음 단계로 간다.
    dataset=load_measured_vibration(root);
    motor_records=[];
    if options.IncludeMotor, motor_records=load_measured_motor(root); end
    provenance=input_fingerprints(root,dataset,motor_records);
    % provenance는 '어떤 파일로 이 결과를 만들었는가'를 추적하는 출처 기록이다.
    write_json(fullfile(outdir,'input_provenance.json'),provenance);
    study=struct('options',options,'output_directory',outdir,'provenance',provenance);
    fprintf('Measured vibration: %d original runs, %d recorded windows.\n',...
        numel(dataset.runs),sum(arrayfun(@(r)size(r.raw,1),dataset.runs)));
    study.vibration=analyze_measured_vibration(dataset,fullfile(outdir,'vibration'),options.Visible);
    % 2. 같은 실측값을 Python과 MATLAB에서 각각 계산한 결과가 정수 단위로 같은지 확인한다.
    study.python_reference=compare_python_reference(root,dataset,study.vibration);
    study.motor=struct;
    if options.IncludeMotor
        study.motor=analyze_measured_motor(motor_records,fullfile(outdir,'motor'),'Visible',options.Visible);
    end
    can_simulate=options.BuildSimulink && ~isempty(which('new_system')) && license('test','Simulink');
    % 3. Simulink 사용 가능 여부를 별도로 확인한다. MATLAB 분석 완료와 sim 통과는 다른 상태다.
    study.models=struct('vibration','','motor','');
    study.diagram_files={};
    study.vibration_simulink=struct([]); study.motor_simulink=struct([]);
    if can_simulate
        % 이전 ZIP 폴더가 이동·삭제되면 getConfig 자체가 실패할 수 있다.
        % 읽을 수 있는 설정만 보관하고, 현재 실행의 유효한 폴더를 지정한다.
        oldConfig=[];
        try
            oldConfig=Simulink.fileGenControl('getConfig');
        catch previousConfigError
            warning('Measured:PreviousFileGenConfig',...
                'Previous Simulink file-generation configuration could not be read; using this study folder. %s',...
                previousConfigError.message);
        end
        Simulink.fileGenControl('set','CacheFolder',fullfile(outdir,'sim_cache'),...
            'CodeGenFolder',fullfile(outdir,'sim_codegen'),'keepPreviousPath',false,'createDir',true);
        if ~isempty(oldConfig)
            configCleanup=onCleanup(@()Simulink.fileGenControl('setConfig','config',oldConfig)); %#ok<NASGU>
        end
        study.models=build_measured_models(outdir,dataset,motor_records);
        % run은 한 번의 독립 수집 실험이다. 실험별로 재생하여 서로 다른 기록을 섞지 않는다.
        for k=1:numel(dataset.runs)
            r=dataset.runs(k); folder=fullfile(outdir,'vibration',r.run_id);
            if ~isfolder(folder), mkdir(folder); end
            fprintf('Simulink measured frame replay: %s\n',r.run_id);
            replay=validate_vibration(r,study.vibration.runs(k),folder);
            if k==1, study.vibration_simulink=replay;
            else, study.vibration_simulink(k)=replay; end
        end
        for k=1:numel(motor_records)
            r=motor_records(k); folder=fullfile(outdir,'motor',r.name);
            if ~isfolder(folder), mkdir(folder); end
            fprintf('Simulink original telemetry replay: %s\n',r.name);
            replay=validate_motor(r,folder);
            if k==1, study.motor_simulink=replay;
            else, study.motor_simulink(k)=replay; end
        end
        status.simulink='PASSED_EXACT_RECORDED_DATA_REPLAY';
        modelNames={'measured_vibration_replay'};
        if options.IncludeMotor, modelNames{end+1}='measured_motor_telemetry_replay'; end
        for k=1:numel(modelNames)
            mdl=modelNames{k};
            try
                print(['-s' mdl],'-dpng','-r150',fullfile(outdir,[mdl '_diagram.png']));
                study.diagram_files{end+1}=fullfile(outdir,[mdl '_diagram.png']);
            catch printError
                warning('Measured:DiagramExport','Replay passed; diagram PNG unavailable: %s',printError.message);
            end
            if strcmp(options.Visible,'on'), open_system(mdl); else, close_system(mdl,0); end
        end
    elseif options.BuildSimulink
        status.simulink='UNAVAILABLE';
        warning('Measured:NoSimulink',...
            'Simulink unavailable: measured MATLAB analysis ran; SLX generation/execution is NOT RUN.');
    else
        status.simulink='DISABLED';
    end
    verify_unchanged(root,provenance);
    % 4. 계산 중 파일이 바뀌지 않았는지 다시 확인하고 표/상태/MAT 파일을 저장한다.
    status.status='COMPLETED'; status.finished=datestr(now,30);
    status.training_confusion=study.vibration.training_confusion;
    status.original_validation_confusion=study.vibration.validation_confusion;
    status.original_validation_accuracy=study.vibration.validation_accuracy;
    status.validation_scope='Existing validation runs reused; not a new independent test.';
    status.python_reference=study.python_reference;
    study.status=status;
    save(fullfile(outdir,'measured_study.mat'),'study','-v7');
    % [주5] 저장을 마친 결과의 지문을 별도 상태 파일에 기록한다. MAT 자신을 다시 저장하면
    % 지문이 바뀌므로 receipt는 MAT 저장 뒤 생성하며, 반환 구조체와 JSON에 붙인다.
    status.output_receipt=output_fingerprints(root,study);
    verify_unchanged(root,provenance);
    study.status=status;
    write_json(statuspath,status);
    fprintf('Original validation reproduction: %d/%d (%.4f%%).\n',...
        trace(status.original_validation_confusion),sum(status.original_validation_confusion(:)),...
        100*status.original_validation_accuracy);
    fprintf('Simulink: %s\nRecorded-data outputs: %s\n',status.simulink,outdir);
catch failure
    % 중간에 실패했을 때 COMPLETED가 남지 않도록 원인과 FAILED 상태를 기록한다.
    status.status='FAILED'; status.error_identifier=failure.identifier;
    status.error_message=failure.message; write_json(statuspath,status);
    rethrow(failure);
end
end

function options=defaults(options)
% 선택 가능한 옵션만 허용한다. 철자가 틀린 옵션을 조용히 무시하지 않기 위해서다.
% BuildSimulink: 모델 생성/실행, IncludeMotor: 모터 기록 포함, Visible: 그림 창 표시.
assert(isstruct(options) && isscalar(options),'Options must be a scalar struct.');
d=struct('BuildSimulink',true,'IncludeMotor',true,'Visible','on');
unknown=setdiff(fieldnames(options),fieldnames(d));
assert(isempty(unknown),'Measured:Options','Unknown options: %s',strjoin(unknown,', '));
names=fieldnames(d);
for k=1:numel(names)
    if ~isfield(options,names{k}), options.(names{k})=d.(names{k}); end
end
validateattributes(options.BuildSimulink,{'logical','numeric'},{'scalar','binary'});
validateattributes(options.IncludeMotor,{'logical','numeric'},{'scalar','binary'});
options.Visible=validatestring(options.Visible,{'on','off'});
end

function report=validate_vibration(r,expected,folder)
% 한 실측 run을 Simulink에 넣고 MATLAB의 FFT/NPU 결과와 비교한다.
% r.raw: [윈도우 수 x 64], expected: 같은 원본으로 계산한 MATLAB 기준 결과.
% [주3] tick=0,1,2,...는 재생 순번이다. 실제 경과 초로 해석하면 안 된다.
mdl='measured_vibration_replay'; n=size(r.raw,1);
metadata=[r.window_id repmat(r.label,n,1) r.host_time_s];
si=Simulink.SimulationInput(mdl);
% 모델 파일을 매번 고치지 않고 이번 실행에 사용할 원본만 덮어 지정한다.
% 원본 n개 기록을 tick 0..n-1에 배치한다. From Workspace는 보간을 끄고
% 마지막 값 유지로 설정하며, StopTime은 마지막 원본 기록 시각이다.
si=si.setVariable('measured_raw',replay_input(r.raw),'Workspace',mdl);
si=si.setVariable('measured_dt_us',replay_input(r.dt_us),'Workspace',mdl);
si=si.setVariable('measured_metadata',replay_input(metadata),'Workspace',mdl);
si=si.setModelParameter('StopTime',num2str(n-1));
out=sim(si);
% 원본 64개, 측정 간격 64개, FFT 실수/허수 128개를 모두 꺼내 중간 단계까지 검사한다.
logs.raw=read_log(out,'mv_raw',n,64);
logs.dt_us=read_log(out,'mv_dt_us',n,64);
logs.metadata=read_log(out,'mv_metadata',n,3);
logs.fft=read_log(out,'mv_fft',n,128);
logs.features=read_log(out,'mv_features',n,4);
logs.hidden=read_log(out,'mv_hidden',n,4);
logs.logits=read_log(out,'mv_logits',n,2);
logs.classes=read_log(out,'mv_class',n,1);
logs.quality=read_log(out,'mv_quality',n,7);
logs.comparison=read_log(out,'mv_comparison',n,3);
assert(isequal(logs.raw,r.raw) && isequal(logs.dt_us,r.dt_us) && isequal(logs.metadata,metadata),...
    'Measured:ReplayMismatch','Original data/timing/labels changed during replay: %s.',r.run_id);
assert(isequal(logs.fft,[expected.fft_real expected.fft_imag]) && ...
    isequal(logs.features,expected.features) && isequal(logs.hidden,expected.hidden) && ...
    isequal(logs.logits,expected.logits) && isequal(logs.classes,expected.classes),...
    'Measured:InferenceMismatch','Measured-frame integer FFT/NPU mismatch: %s.',r.run_id);
truth=repmat(r.label,n,1);
assert(isequal(logs.comparison,[truth expected.classes double(truth==expected.classes)]),...
    'Measured:LabelMismatch','Recorded label comparison mismatch.');
dt=r.dt_us(:,2:64); mu=mean(r.raw,2);
% 첫 dt는 0이라는 시작 표시이므로 제외한다. std(...,1,2)는 63개 간격의 모집단 표준편차다.
% 품질 통계의 실수 연산에는 작은 허용오차를 주지만, 위 raw/FFT/NPU 정수값은 정확히 같아야 한다.
quality=[mu sqrt(mean((r.raw-mu).^2,2)) sum(r.raw==-32768 | r.raw==32767,2),...
    mean(dt,2) min(dt,[],2) max(dt,[],2) std(dt,1,2)];
assert(max(abs(logs.quality(:)-quality(:)))<1e-8,'Measured:QualityMismatch','Derived quality mismatch.');
save(fullfile(folder,'simulink_measured_replay.mat'),'logs');
report=struct('run_id',r.run_id,'status','PASSED','windows',n,...
    'raw_and_metadata_exact',true,'fft_and_npu_exact',true,...
    'physical_elapsed_time_simulated',false,'source_sha256',r.source_sha256);
write_json(fullfile(folder,'simulink_validation.json'),report);
end

function report=validate_motor(r,folder)
% 기록된 속도·PWM·적분값·상태 비트를 그대로 재생한다. 새 제어 응답을 계산하는 함수는 아니다.
% 원본 counter/time 열도 함께 비교하여 누락 구간을 임의로 채우지 않았는지 확인한다.
mdl='measured_motor_telemetry_replay'; n=numel(r.t);
recordTime=[r.t double(r.table.sample)];
si=Simulink.SimulationInput(mdl);
si=si.setVariable('motor_codes',replay_input(r.values),'Workspace',mdl);
si=si.setVariable('motor_exported',replay_input(r.exported_values),'Workspace',mdl);
si=si.setVariable('motor_record_time',replay_input(recordTime),'Workspace',mdl);
si=si.setModelParameter('StopTime',num2str(n-1));
out=sim(si);
logs.codes=read_log(out,'mm_codes',n,7);
logs.exported=read_log(out,'mm_exported',n,3);
logs.record_time=read_log(out,'mm_record_time',n,2);
assert(isequal(logs.codes,r.values) && isequal(logs.exported,r.exported_values) && ...
    isequal(logs.record_time,recordTime),'Measured:MotorReplayMismatch',...
    'Original motor telemetry changed during replay: %s.',r.name);
save(fullfile(folder,'simulink_telemetry_replay.mat'),'logs');
report=struct('name',r.name,'status','PASSED','records',n,'all_recorded_channels_exact',true,...
    'closed_loop_simulation',false,'source_sha256',r.sha256);
write_json(fullfile(folder,'simulink_validation.json'),report);
end

function source=replay_input(values)
% 원본 기록 수를 유지하면서 첫 열에 재생 순번만 붙인다.
n=size(values,1);
source=[(0:n-1)' values];
end

function values=read_log(out,name,n,width)
% Simulink의 timeseries 저장 모양을 [기록 수 x 신호 수] 행렬로 통일한다.
% squeeze는 크기가 1인 차원을 없앨 뿐, 샘플 값을 평균하거나 보간하지 않는다.
ts=out.get(name);
assert(isa(ts,'timeseries') && isequal(double(ts.Time(:)),(0:n-1)'),...
    'Measured:ReplayClock','Unexpected record-index clock: %s.',name);
values=double(squeeze(ts.Data));
if isequal(size(values),[width n]) && width~=n, values=values'; end
assert(isequal(size(values),[n width]),'Measured:ReplayShape','Unexpected logged shape: %s.',name);
end

function checked=compare_python_reference(root,dataset,report)
% 다른 구현 언어로 계산한 참조 결과와 교차 확인한다. 먼저 같은 데이터/가중치인지 검사한다.
% [주4] CSV의 F1..F4=입력 특징, H1..H4=은닉층, L0/L1=두 클래스의 점수다.
folder=fullfile(root,'reports','measured_offline');
jsonPath=fullfile(folder,'measured_reference.json');
csvPath=fullfile(folder,'measured_reference_frames.csv');
if ~isfile(jsonPath) || ~isfile(csvPath)
    checked=struct('status','NOT_AVAILABLE','frames',0);
    warning('Measured:NoPythonReference','Independent Python reference is absent; no cross-language comparison is claimed.');
    return;
end
reference=jsondecode(fileread(jsonPath));
assert(strcmp(reference.model_sha256,dataset.model_sha256) && ...
    strcmp(reference.manifest_sha256,dataset.manifest_sha256),...
    'Measured:StaleReference','Python reference uses different weights or measurement manifest.');
assert(isfield(reference,'source_files'),'Measured:ReferenceSchema','Reference source list is missing.');
for k=1:numel(reference.source_files)
    source=reference.source_files(k);
    assert(strcmp(measured_sha256(fullfile(root,source.file)),source.sha256),...
        'Measured:ReferenceInput','Python reference input changed: %s.',source.file);
end
T=readtable(csvPath,'TextType','string'); count=0;
for k=1:numel(dataset.runs)
    r=dataset.runs(k); actual=report.runs(k);
    rows=T(string(T.RunID)==string(r.run_id),:);
    assert(isequal(rows.WindowID,r.window_id) && all(rows.TrueLabel==r.label) && ...
        all(string(rows.Split)==string(r.split)),...
        'Measured:ReferenceIdentity','Reference frame identity mismatch: %s.',r.run_id);
    assert(isequal(rows{:,{'F1','F2','F3','F4'}},actual.features) && ...
        isequal(rows{:,{'H1','H2','H3','H4'}},actual.hidden) && ...
        isequal(rows{:,{'L0','L1'}},actual.logits) && isequal(rows.PredictedClass,actual.classes),...
        'Measured:PythonMismatch','Python/MATLAB measured inference mismatch: %s.',r.run_id);
    count=count+height(rows);
end
assert(height(T)==count,'Measured:ExtraReferenceFrames','Unexpected frames in independent reference.');
checked=struct('status','PASSED','frames',count,'features_hidden_logits_classes_exact',true);
end

function p=input_fingerprints(root,dataset,motor)
% SHA-256은 파일 바이트의 지문이다. 동일 파일임을 추적하며 측정 정확도를 보증하지는 않는다.
paths={'data/dataset_source.json','data/model.json','data/train_samples.csv',...
    'data/train_labels.csv','data/val_samples.csv','data/val_labels.csv'};
% 입력뿐 아니라 계산에 사용하는 MATLAB 구현도 묶어 과거 결과와 새 코드를 구분한다.
sources={'RUN_MEASURED_STUDY.m','matlab/fft64_fixed.m','matlab/npu_int8.m',...
    'matlab/fourier_fft_sl.m','matlab/fourier_features_sl.m'};
listed=dir(fullfile(root,'matlab','measured','*.m'));
for k=1:numel(listed), sources{end+1}=['matlab/measured/' listed(k).name]; end %#ok<AGROW>
paths=[paths,sources];
references={'reports/measured_offline/measured_reference.json',...
    'reports/measured_offline/measured_reference_frames.csv'};
for k=1:numel(references)
    if isfile(fullfile(root,references{k})), paths{end+1}=references{k}; end %#ok<AGROW>
end
for k=1:numel(dataset.runs)
    r=dataset.runs(k);
    paths=[paths,{['measurements/final_50pct/' r.run_id '.csv'],...
        ['measurements/final_50pct/' r.run_id '.json']}]; %#ok<AGROW>
end
for k=1:numel(motor), paths{end+1}=motor(k).source_file; end %#ok<AGROW>
p=struct('origin','RECORDED_HARDWARE_ONLY','matlab_sources',{sources},'files',struct([]));
for k=1:numel(paths)
    item=struct('file',paths{k},'sha256',measured_sha256(fullfile(root,paths{k})));
    if k==1, p.files=item; else, p.files(k)=item; end
end
end
function verify_unchanged(root,p)
% 입력이나 계산 소스가 실행 도중 수정되면 어느 버전으로 계산했는지 모호해지므로 중단한다.
for k=1:numel(p.files)
    assert(strcmp(measured_sha256(fullfile(root,p.files(k).file)),p.files(k).sha256),...
        'Measured:InputChanged','Input/source changed during the run: %s.',p.files(k).file);
end
end
function receipt=output_fingerprints(root,study)
% 이번 실행에서 생성한 파일만 명시한다. 폴더 전체를 검색하면 과거 잔여 그림도 섞일 수 있다.
folder=study.output_directory;
paths={fullfile(folder,'input_provenance.json'),fullfile(folder,'measured_study.mat')};
vibration={'measured_runs.csv','measured_windows.csv','training_confusion.csv',...
    'existing_validation_confusion.csv','measured_spectra.csv','measured_analysis.mat'};
figures={'measured_raw_frames','measured_spectrum_3d','measured_quality','measured_confusion'};
for k=1:numel(vibration), paths{end+1}=fullfile(folder,'vibration',vibration{k}); end %#ok<AGROW>
for k=1:numel(figures)
    paths=[paths,{fullfile(folder,'vibration',[figures{k} '.png']),...
        fullfile(folder,'vibration',[figures{k} '.fig'])}]; %#ok<AGROW>
end
if study.options.IncludeMotor
    paths=[paths,reshape(study.motor.figure_files,1,[]),...
        {fullfile(folder,'motor','motor_measured_summary.csv'),...
        fullfile(folder,'motor','motor_measured_analysis.mat')}];
end
names=fieldnames(study.models);
for k=1:numel(names)
    if ~isempty(study.models.(names{k})), paths{end+1}=study.models.(names{k}); end %#ok<AGROW>
end
paths=[paths,study.diagram_files];
for k=1:numel(study.vibration_simulink)
    run=study.vibration_simulink(k).run_id;
    paths=[paths,{fullfile(folder,'vibration',run,'simulink_measured_replay.mat'),...
        fullfile(folder,'vibration',run,'simulink_validation.json')}]; %#ok<AGROW>
end
for k=1:numel(study.motor_simulink)
    run=study.motor_simulink(k).name;
    paths=[paths,{fullfile(folder,'motor',run,'simulink_telemetry_replay.mat'),...
        fullfile(folder,'motor',run,'simulink_validation.json')}]; %#ok<AGROW>
end
receipt=struct('format_version',1,'files',struct([]));
for k=1:numel(paths)
    relative=strrep(paths{k}(numel(root)+2:end),'\','/');
    item=struct('file',relative,'sha256',measured_sha256(paths{k}));
    if k==1, receipt.files=item; else, receipt.files(k)=item; end
end
end
function write_json(path,value)
% 사람이 읽을 수 있는 상태 파일을 남긴다. onCleanup은 오류가 나도 파일을 닫아 준다.
fid=fopen(path,'w'); assert(fid>=0,'Cannot write %s.',path);
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
