function models=build_measured_models(outdir,dataset,motor_records)
% 읽는 순서: 실측 실험 선택 → 원본을 모델 안에 저장 → 처리/표시 블록 연결 → .slx 저장.
% 입력 outdir: 모델 저장 폴더, dataset: 검증된 진동 기록, motor_records: 선택적 모터 기록.
% 출력 models.vibration/models.motor는 생성한 .slx 경로입니다. 이 함수는 모델을 만듭니다.
% [주1] 재생 시간 1초는 기록 1개를 뜻합니다. 진동은 64샘플 프레임 하나,
% 모터는 텔레메트리 한 행이며, 실제 측정 시간 1초가 지났다는 의미가 아닙니다.
%BUILD_MEASURED_MODELS Create separate, recorded-data-only replay models.
% One Simulink second represents one replay record, NOT measured elapsed time.
% No synthetic plant, interpolation, missing-axis reconstruction or noise source.
if nargin<3, motor_records=[]; end
if ~exist(outdir,'dir'), mkdir(outdir); end
load_system('simulink');
idx=find(strcmp({dataset.runs.split},'validation'),1);
% 그래픽 모델은 기존 검증 실험 하나를 보여 주며, 전체 실험 평가는 MATLAB 분석에서 합니다.
assert(~isempty(idx),'Measured:NoValidation','An original validation run is required.');
models.vibration=build_vibration(outdir,dataset.runs(idx),dataset.model);
models.motor='';
if ~isempty(motor_records)
    idx=find(strcmp({motor_records.name},'step_candidate_gains'),1);
    if isempty(idx), idx=1; end
    models.motor=build_motor(outdir,motor_records(idx));
end
end

function path=build_vibration(outdir,run,M)
% 보조 함수: 실험 run과 기존 가중치 M으로 진동 재생 모델을 만들고 .slx 경로를 반환합니다.
% run.raw는 [프레임 수 x 64] counts이며, M은 4→4→2 정수 분류기 파라미터입니다.
mdl='measured_vibration_replay'; n=size(run.raw,1);
create_model(mdl,n);
ws=get_param(mdl,'ModelWorkspace');
assignin(ws,'measured_raw',replay_input(run.raw));
% [주2] From Workspace용 첫 열 tick은 재생 순서, 나머지 64열은 한 프레임의 원본입니다.
% dt_us와 PC 수신 시각은 별도 신호로 보관하므로 재생 시계와 측정 시간 정보를 혼동하지 않습니다.
assignin(ws,'measured_dt_us',replay_input(run.dt_us));
assignin(ws,'measured_metadata',replay_input(...
    [run.window_id repmat(run.label,n,1) run.host_time_s]));
assignin(ws,'source_csv_sha256',run.source_sha256);
assignin(ws,'source_run_id',run.run_id);
set_param(mdl,'Description',sprintf('Actual measured X-axis replay: %s. CSV SHA256 %s. No physical-time interpolation.',...
    run.run_id,run.source_sha256));

src=subsystem(mdl,'01_Verified_recorded_windows',[35 145 225 310]);
names={'Raw_X_INT16_counts','Measured_dt_us','Window_label_host_timestamp'};
variables={'measured_raw','measured_dt_us','measured_metadata'};
for k=1:3
    source(src,names{k},variables{k},[35 40+75*k 225 75+75*k]);
    port(src,'Out',names{k},k,[305 50+75*k 335 70+75*k]);
    line(src,[names{k} '/1'],['Out_' names{k} '/1']);
end
note(src,['Each record is an original 64-sample frame. Interpolation OFF. ' ...
    'Measured dt and host arrival timestamp remain separate; inter-frame samples were not acquired.'],[30 355 700 415]);

fft=subsystem(mdl,'02_FPGA_integer_FFT_features',[300 140 490 255]);
% [주3] 정수 FFT와 대역 특징은 배포한 처리 순서를 따릅니다. 원본 DC를 유지하며,
% 진단 PSD에서 쓰는 평균 제거/Hann 창을 추론 경로에 끼워 넣지 않습니다.
port(fft,'In','Raw_frame',1,[20 100 50 120]);
chart(fft,'FFT64_scaled_by_64',sprintf('function v=fcn(u)\nv=fourier_fft_sl(u);\nend'),[105 80 300 140]);
chart(fft,'Four_L1_band_features',sprintf('function f=fcn(u)\nf=fourier_features_sl(u);\nend'),[365 80 565 140]);
line(fft,'In_Raw_frame/1','FFT64_scaled_by_64/1');
line(fft,'FFT64_scaled_by_64/1','Four_L1_band_features/1');
port(fft,'Out','Features',1,[645 90 675 110]);
port(fft,'Out','FFT_real_imag',2,[645 175 675 195]);
line(fft,'Four_L1_band_features/1','Out_Features/1');
line(fft,'FFT64_scaled_by_64/1','Out_FFT_real_imag/1');
note(fft,['Original raw DC is retained. No mean removal or Hann window before deployed inference. ' ...
    'Bins 1..6 / 7..12 / 13..20 / 21..31, >>5 and saturation to127.'],[25 255 775 320]);

npu=subsystem(mdl,'03_Existing_trained_INT8_NPU',[560 130 775 280]);
% [주4] floor(.../2^shift)는 정수 축소를, min/max는 표현 범위 포화를 재현합니다.
% 은닉층은 ReLU로 음수를 0으로 만들고, 출력 점수 두 개가 같으면 클래스 0을 고릅니다.
% 아래 sprintf 문자열은 MATLAB Function 블록 안에 들어갈 코드를 생성합니다.
port(npu,'In','Features',1,[20 105 50 125]);
chart(npu,'Hidden_ReLU_4x4',sprintf(['function h=fcn(f)\n' ...
    'h=max(0,min(127,floor((%s*double(f(:))+%s)/2^%d)));\nend'],...
    mat2str(double(M.w1)),mat2str(double(M.b1(:))),M.shift1),[105 85 290 145]);
chart(npu,'Logits_4x2',sprintf(['function o=fcn(h)\n' ...
    'o=max(-128,min(127,floor((%s*double(h(:))+%s)/2^%d)));\nend'],...
    mat2str(double(M.w2)),mat2str(double(M.b2(:))),M.shift2),[350 85 530 145]);
chart(npu,'Argmax_tie_to_class0',sprintf('function c=fcn(o)\nc=double(o(2)>o(1));\nend'),[590 85 795 145]);
chain={'In_Features','Hidden_ReLU_4x4','Logits_4x2','Argmax_tie_to_class0'};
for k=1:3, line(npu,[chain{k} '/1'],[chain{k+1} '/1']); end
outs={'Hidden','Logits','Class'};
for k=1:3
    port(npu,'Out',outs{k},k,[290+210*k 235 320+210*k 255]);
    line(npu,[chain{k+1} '/1'],['Out_' outs{k} '/1']);
end
note(npu,'Existing data/model.json weights. Training runs and original validation runs are reported separately; no retraining.',[25 325 950 370]);

qc=subsystem(mdl,'04_Measured_frame_quality',[295 375 515 490]);
% [주5] 품질 출력 7개는 DC, AC RMS, ADC 양끝값 개수, dt 평균/최소/최대/흔들림입니다.
% dt는 첫 0을 제외한 63개이며, 여기 흔들림은 63으로 나눈 모집단 표준편차(us)입니다.
% 별도 MATLAB 분석의 std(dt,0,2)는 62로 나누는 표본 표준편차이므로 정의가 다릅니다.
port(qc,'In','Raw',1,[20 75 50 95]); port(qc,'In','Intervals',2,[20 155 50 175]);
script=sprintf(['function q=fcn(raw,dt)\nx=double(raw(:)); d=double(dt(2:64));\n' ...
    'mu=sum(x)/64; rms_ac=sqrt(sum((x-mu).^2)/64);\n' ...
    'mean_dt=sum(d)/63; jitter=sqrt(sum((d-mean_dt).^2)/63);\n' ...
    'q=[mu;rms_ac;sum(x==-32768 | x==32767);mean_dt;min(d);max(d);jitter];\nend']);
chart(qc,'DC_AC_RMS_clipping_timing',script,[120 85 385 155]);
line(qc,'In_Raw/1','DC_AC_RMS_clipping_timing/1'); line(qc,'In_Intervals/1','DC_AC_RMS_clipping_timing/2');
port(qc,'Out','Quality',1,[455 105 485 125]); line(qc,'DC_AC_RMS_clipping_timing/1','Out_Quality/1');
note(qc,'Quality vector: DC, centered RMS [counts], rail count, mean/min/max dt [us], population dt jitter [us].',[25 240 700 285]);

compare=subsystem(mdl,'05_Recorded_label_comparison',[590 380 795 490]);
port(compare,'In','Class',1,[20 65 50 85]); port(compare,'In','Metadata',2,[20 140 50 160]);
chart(compare,'Truth_prediction_correct',sprintf(['function y=fcn(c,m)\n' ...
    'y=[m(2);c;double(c==m(2))];\nend']),[125 75 355 140]);
line(compare,'In_Class/1','Truth_prediction_correct/1'); line(compare,'In_Metadata/1','Truth_prediction_correct/2');
port(compare,'Out','Comparison',1,[425 95 455 115]); line(compare,'Truth_prediction_correct/1','Out_Comparison/1');

line(mdl,'01_Verified_recorded_windows/1','02_FPGA_integer_FFT_features/1');
line(mdl,'02_FPGA_integer_FFT_features/1','03_Existing_trained_INT8_NPU/1');
line(mdl,'01_Verified_recorded_windows/1','04_Measured_frame_quality/1');
line(mdl,'01_Verified_recorded_windows/2','04_Measured_frame_quality/2');
line(mdl,'03_Existing_trained_INT8_NPU/3','05_Recorded_label_comparison/1');
line(mdl,'01_Verified_recorded_windows/3','05_Recorded_label_comparison/2');
signals={'raw','dt_us','metadata','features','fft','hidden','logits','class','quality','comparison'};
origins={'01_Verified_recorded_windows/1','01_Verified_recorded_windows/2','01_Verified_recorded_windows/3',...
    '02_FPGA_integer_FFT_features/1','02_FPGA_integer_FFT_features/2','03_Existing_trained_INT8_NPU/1',...
    '03_Existing_trained_INT8_NPU/2','03_Existing_trained_INT8_NPU/3','04_Measured_frame_quality/1','05_Recorded_label_comparison/1'};
logging(mdl,'06_Exact_replay_logs',signals,origins,[880 130 1080 500],'mv_');
note(mdl,'MEASURED X-AXIS | ORIGINAL RAW -> FIXED FFT64 -> EXISTING INT8 MODEL -> RECORDED LABEL',[35 20 1100 65]);
note(mdl,['Replay clock: one simulated second = one original window record, NOT one elapsed measurement second. ' ...
    'No synthetic waveform, plant, XYZ motion, interpolated gaps or invented safety/heartbeat signals.'],[35 550 1130 625]);
path=finish_model(mdl,outdir);
end

function path=build_motor(outdir,record)
% 보조 함수: 기록 record 하나의 Q12 코드/상태/RPM/%를 재생하는 모델의 경로를 반환합니다.
% [주6] PID나 모터 동역학을 새로 계산하지 않고 당시 기록된 속도/PWM/적분값을 표시합니다.
% 다른 시점에 수집한 진동 실험과 시간 동기화된 데이터라고 가정하지 않습니다.
mdl='measured_motor_telemetry_replay'; n=numel(record.t);
create_model(mdl,n); ws=get_param(mdl,'ModelWorkspace');
assignin(ws,'motor_codes',replay_input(record.values));
assignin(ws,'motor_exported',replay_input(record.exported_values));
assignin(ws,'motor_record_time',replay_input([record.t double(record.table.sample)]));
% 원래 time_s와 sample 카운터를 함께 보관합니다. 누락 기록은 보간하지 않습니다.
assignin(ws,'source_csv_sha256',record.sha256);
set_param(mdl,'Description',sprintf('Recorded telemetry: %s. CSV SHA256 %s. Record-index playback; original sample counter and time are retained.',...
    record.source_file,record.sha256));
src=subsystem(mdl,'01_Original_motor_telemetry',[35 155 250 330]);
variables={'motor_codes','motor_exported','motor_record_time'};
names={'Q12_and_recorded_flags','Exported_RPM_and_duty_percent','Original_time_and_counter'};
for k=1:3
    source(src,names{k},variables{k},[25 35+70*k 245 70+70*k]);
    port(src,'Out',names{k},k,[325 45+70*k 355 65+70*k]);
    line(src,[names{k} '/1'],['Out_' names{k} '/1']);
end
note(src,'Each row is an original captured telemetry record. A missing counter is not filled; original time_s is sample/100.',[25 340 740 390]);
signals=subsystem(mdl,'02_Recorded_control_channels',[330 130 580 345]);
port(signals,'In','Codes_and_flags',1,[20 150 50 170]);
add_block('simulink/Signal Routing/Demux',[signals '/Seven_recorded_channels'],...
    'Outputs','7','Position',[130 70 135 295]);
line(signals,'In_Codes_and_flags/1','Seven_recorded_channels/1');
names={'Reference_Q12','Measured_speed_Q12','PWM_Q12','Integral_Q12','Armed','Fault','Enabled'};
for k=1:7
    port(signals,'Out',names{k},k,[300 15+50*k 330 35+50*k]);
    line(signals,sprintf('Seven_recorded_channels/%d',k),['Out_' names{k} '/1']);
end
line(mdl,'01_Original_motor_telemetry/1','02_Recorded_control_channels/1');
scope=subsystem(mdl,'03_Recorded_speed_PWM_integral',[670 140 885 345]);
port(scope,'In','RPM_duty',1,[20 85 50 105]);
port(scope,'In','Integral_Q12',2,[20 205 50 225]);
add_block('simulink/Sinks/Scope',[scope '/Recorded_target_measured_RPM_duty'],...
    'Position',[165 70 340 120]);
add_block('simulink/Sinks/Scope',[scope '/Recorded_integral_Q12'],...
    'Position',[165 190 340 240]);
line(scope,'In_RPM_duty/1','Recorded_target_measured_RPM_duty/1');
line(scope,'In_Integral_Q12/1','Recorded_integral_Q12/1');
line(mdl,'01_Original_motor_telemetry/2','03_Recorded_speed_PWM_integral/1');
line(mdl,'02_Recorded_control_channels/4','03_Recorded_speed_PWM_integral/2');
logging(mdl,'04_Exact_telemetry_logs',{'codes','exported','record_time'},...
    {'01_Original_motor_telemetry/1','01_Original_motor_telemetry/2','01_Original_motor_telemetry/3'},...
    [670 410 900 520],'mm_');
% Show all code outputs on a second logger; no invented control response.
for k=[1 2 3 5 6 7]
    add_block('simulink/Sinks/Terminator',[mdl '/Recorded_' names{k}],...
        'Position',[615 110+35*k 635 130+35*k]);
    line(mdl,sprintf('02_Recorded_control_channels/%d',k),['Recorded_' names{k} '/1']);
end
note(mdl,'ACTUAL MOTOR TELEMETRY | RECORDED SPEED, PWM, INTEGRAL AND FLAGS',[35 20 1030 65]);
note(mdl,['This is historical record playback, not a new closed-loop simulation. ' ...
    'Scopes use replay-record ticks; MATLAB plots use original time_s. ' ...
    'No synchronous vibration-to-speed relationship is assumed across separate experiments.'],[35 580 1070 655]);
path=finish_model(mdl,outdir);
end

function create_model(mdl,n)
% 보조 함수: 이름 mdl로 이산 모델을 만듭니다. n개 기록을 tick 0부터 n-1까지 재생합니다.
if bdIsLoaded(mdl), close_system(mdl,0); end
new_system(mdl);
set_param(mdl,'Solver','FixedStepDiscrete','FixedStep','1','StopTime',num2str(n-1),...
    'ReturnWorkspaceOutputs','on');
set_param(mdl,'InitFcn',sprintf(['measured_root=fileparts(fileparts(fileparts(get_param(bdroot,''FileName''))));\n' ...
    'addpath(fullfile(measured_root,''matlab''),fullfile(measured_root,''matlab'',''measured''));']));
end
function source=replay_input(values)
% 원본 n개 행을 tick 0..n-1에 배치하며 추가 행을 만들지 않는다.
n=size(values,1);
source=[(0:n-1)' values];
end
function path=finish_model(mdl,outdir)
% 보조 함수: 모델 mdl의 화면 배치를 정리하고 outdir에 저장한 .slx 경로를 반환합니다.
set_param(mdl,'Location',[35 45 1260 790],'ZoomFactor','FitSystem');
path=fullfile(outdir,[mdl '.slx']); save_system(mdl,path);
end
function path=subsystem(parent,name,position)
% 보조 함수: 부모 아래에 기능 묶음(Subsystem)을 만들고 블록 경로를 반환합니다.
path=[parent '/' name]; add_block('built-in/Subsystem',path,'Position',position,'BackgroundColor','lightBlue');
end
function source(parent,name,variable,position)
% 보조 함수: [tick, 값들] 배열 variable을 읽는 입력 블록입니다. 보간은 끕니다.
% Interpolate=off에서는 기본 Extrapolation 설정을 함께 사용할 수 없으므로
% 종료 뒤 동작을 Holding final value로 지정합니다. 모델은 마지막 원본 tick에 끝납니다.
add_block('simulink/Sources/From Workspace',[parent '/' name],'VariableName',variable,...
    'Interpolate','off','OutputAfterFinalValue','Holding final value',...
    'SampleTime','1','Position',position);
end
function port(parent,direction,name,index,position)
% 보조 함수: 서브시스템의 입출력 단자를 만듭니다. index는 연결할 단자 번호입니다.
add_block(['built-in/' direction 'port'],[parent '/' direction '_' name],'Port',num2str(index),'Position',position);
end
function chart(parent,name,script,position)
% 보조 함수: script 문자열을 실행 코드로 갖는 MATLAB Function 블록을 만듭니다.
path=[parent '/' name]; add_block('simulink/User-Defined Functions/MATLAB Function',path,'Position',position);
c=find(sfroot,'-isa','Stateflow.EMChart','Path',path); assert(isscalar(c)); c.Script=script;
end
function line(parent,from,to)
% 보조 함수: 같은 부모 안의 '블록/단자번호' from과 to를 신호선으로 연결합니다.
add_line(parent,from,to,'autorouting','on');
end
function note(parent,content,position)
% 보조 함수: 모델 화면에 설명 content를 붙입니다. position은 화면 좌표이며 물리 좌표가 아닙니다.
a=Simulink.Annotation(parent,content); a.Position=position; a.FontSize=12;
end
function logging(mdl,name,signals,origins,position,prefix)
% 보조 함수: origins의 신호를 prefix가 붙은 작업공간 변수로 모두 기록합니다.
% Timeseries의 시간축은 재생 tick입니다. 실제 수집 시각은 별도 기록 신호를 확인합니다.
p=subsystem(mdl,name,position);
for k=1:numel(signals)
    port(p,'In',signals{k},k,[25 25+55*k 55 45+55*k]);
    add_block('simulink/Sinks/To Workspace',[p '/Log_' signals{k}],...
        'VariableName',[prefix signals{k}],'SaveFormat','Timeseries','SampleTime','1',...
        'MaxDataPoints','inf','Decimation','1','Position',[160 20+55*k 355 50+55*k]);
    line(p,['In_' signals{k} '/1'],['Log_' signals{k} '/1']);
    line(mdl,origins{k},sprintf('%s/%d',name,k));
end
end
