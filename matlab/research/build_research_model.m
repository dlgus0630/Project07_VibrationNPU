function model_path = build_research_model(outdir,p,plant,result,M)
% [읽기 안내] 연구용 Simulink 블록과 연결을 코드로 만들고 .slx로 저장합니다.
% 입력은 저장 폴더, 설정 p, 상태공간 행렬 plant, 합성 결과 result, NPU 모델 M이며
% 출력 model_path는 생성된 파일 경로입니다. 이 함수 자체는 시뮬레이션을 실행하지 않습니다.
% [주1] 흐름: 가상 외력→6자유도 몸체→가속도계→X축 프레임→FFT/NPU→정책 관찰.
% 3D 재생은 기록한 q(t)를 별도 MATLAB 함수가 그리며 Simscape 모델은 아닙니다.
% Detailed, executable multirate research model. No Simscape dependency.
% MATLAB reference and Simulink independently advance the same ZOH plant.
mdl='vibration_npu_3d';
if ~exist(outdir,'dir'), mkdir(outdir); end
if bdIsLoaded(mdl), close_system(mdl,0); end
load_system('simulink'); new_system(mdl);
set_param(mdl,'Solver','FixedStepDiscrete','FixedStep',num2str(p.dt,17),...
    'StopTime',num2str(result.t(end),17),'ReturnWorkspaceOutputs','on');
ws=get_param(mdl,'ModelWorkspace');
% [주2] 행렬과 시간별 외력을 모델 작업공간에 담아 .slx가 입력을 보유하게 합니다.
% 참고 MATLAB 결과에서 궤적을 그대로 재생하는 대신, 같은 외력으로 Simulink가
% 상태를 별도로 갱신하여 두 구현의 수치 결과를 비교할 수 있게 합니다.
assignin(ws,'Ad',plant.Ad); assignin(ws,'Bd',plant.Bd);
assignin(ws,'Cy',[eye(12);plant.Cacc;plant.Cspecific]);
assignin(ws,'Dy',[zeros(12,6);plant.Dacc;plant.Dspecific]);
assignin(ws,'x0',p.initial_state(:));
assignin(ws,'wrench_data',[result.t result.wrench]);
assignin(ws,'noise_data',[result.t result.sensor_noise]);
assignin(ws,'heartbeat_data',[result.t double(result.heartbeat)]);
% The saved model carries its input data/matrices. Helpers are in the input ZIP.
set_param(mdl,'InitFcn',sprintf(['research_root=fileparts(fileparts(fileparts(get_param(bdroot,''FileName''))));\n' ...
    'addpath(fullfile(research_root,''matlab''),fullfile(research_root,''matlab'',''research''));']));

source=subsystem(mdl,'01_Excitation',[35 140 180 285]);
% From Workspace의 Interpolate='off'는 샘플 사이를 직선으로 잇지 않고
% 이전 값을 유지합니다. 정확한 ZOH 상태행렬의 입력 가정과 일치해야 합니다.
variables={'wrench_data','noise_data','heartbeat_data'};
names={'Wrench_N_Nm','Sensor_noise_mps2','Heartbeat_100ms'};
for k=1:3
    add_block('simulink/Sources/From Workspace',[source '/' names{k}],...
        'VariableName',variables{k},'Interpolate','off',...
        'OutputAfterFinalValue','Holding final value','SampleTime',num2str(p.dt,17),...
        'Position',[35 35+65*k 195 65+65*k]);
    port(source,'Out',names{k},k,[250 40+65*k 280 60+65*k]);
    wire(source,[names{k} '/1'],['Out_' names{k} '/1']);
end
note(source,'Deterministic SI forcing + seeded noise; heartbeat is a sampled PS stimulus.',[25 25 540 55]);

body=subsystem(mdl,'02_Housing_6DOF',[240 130 415 230]);
% [주3] 상태는 [q;qdot]의 12개, 외력은 [F;T]의 6개입니다.
% 출력 18개를 상태 12개·동적 가속도 3개·중력 상수 제외 비력 3개로 나눕니다.
port(body,'In','Wrench',1,[20 95 50 115]);
add_block('simulink/Discrete/Discrete State-Space',[body '/Exact_ZOH_coupled_mechanics'],...
    'A','Ad','B','Bd','C','Cy','D','Dy','InitialCondition','x0',...
    'SampleTime',num2str(p.dt,17),'Position',[100 70 310 145]);
add_block('simulink/Signal Routing/Demux',[body '/State_acceleration_specific_force'],...
    'Outputs','[12 3 3]','Position',[355 65 360 160]);
wire(body,'In_Wrench/1','Exact_ZOH_coupled_mechanics/1');
wire(body,'Exact_ZOH_coupled_mechanics/1','State_acceleration_specific_force/1');
outs={'State_q_qdot','Sensor_dynamic_accel','Specific_force_without_g0'};
for k=1:3
    port(body,'Out',outs{k},k,[460 30+55*k 490 50+55*k]);
    wire(body,sprintf('State_acceleration_specific_force/%d',k),['Out_' outs{k} '/1']);
end
note(body,['M*qdd + C*qd + K*q = [F;T]; q = x,y,z,roll,pitch,yaw. ' ...
    'Full mount coupling; sensor offset and linearized gravity are explicit output maps.'],[20 220 670 275]);

sensor=subsystem(mdl,'03_XYZ_Accelerometer',[480 145 645 255]);
% [주4] 비력에 정지 시 +1 g, 가정한 바이어스와 합성 잡음을 더합니다.
% 마지막에 센서 카운트로 반올림·포화합니다. 실제 측정 데이터가 아닙니다.
port(sensor,'In','Specific_without_g0',1,[20 80 50 100]);
port(sensor,'In','Noise',2,[20 155 50 175]);
add_block('simulink/Sources/Constant',[sensor '/Gravity_at_equilibrium'],...
    'Value',mat2str([0;0;p.gravity],17),'Position',[75 220 175 250]);
add_block('simulink/Sources/Constant',[sensor '/Bias_mps2'],...
    'Value',mat2str(p.sensor.bias(:),17),'Position',[75 285 175 315]);
add_block('simulink/Math Operations/Sum',[sensor '/Specific_force'],...
    'Inputs','++++','Position',[225 85 255 230]);
wire(sensor,'In_Specific_without_g0/1','Specific_force/1');
wire(sensor,'In_Noise/1','Specific_force/2');
wire(sensor,'Gravity_at_equilibrium/1','Specific_force/3');
wire(sensor,'Bias_mps2/1','Specific_force/4');
script=sprintf(['function raw=fcn(a)\n' ...
    'raw=max(-32768,min(32767,round(a(:)*%.17g/%.17g)));\nend'],...
    p.sensor.counts_per_g,p.gravity);
chart(sensor,'INT16_counts_at_2g',script,[320 125 485 185]);
wire(sensor,'Specific_force/1','INT16_counts_at_2g/1');
port(sensor,'Out','Raw_XYZ',1,[550 145 580 165]);
wire(sensor,'INT16_counts_at_2g/1','Out_Raw_XYZ/1');
note(sensor,'Counts retained as exact integer-valued doubles, matching the existing MATLAB Golden.',[25 365 640 405]);

acq=subsystem(mdl,'04_X_axis_64_sample_frames',[710 150 900 255]);
% [주5] 3축 중 X만 64개 모읍니다. fs=1 kHz, 첫 시각=0이면 첫 valid는
% 63 ms에 발생하고 이후 64 ms마다 갱신됩니다. valid가 프레임 경계를 알려 줍니다.
port(acq,'In','Raw_XYZ',1,[20 80 50 100]);
script=sprintf(['function [frame,valid]=fcn(raw)\n' ...
    'persistent buffer count\n' ...
    'if isempty(count), buffer=zeros(64,1); count=0; end\n' ...
    'count=count+1; buffer(count)=double(raw(1));\n' ...
    'valid=(count==64); frame=buffer;\n' ...
    'if valid, count=0; end\nend']);
chart(acq,'Nonoverlapping_frame_buffer',script,[100 65 305 125]);
wire(acq,'In_Raw_XYZ/1','Nonoverlapping_frame_buffer/1');
port(acq,'Out','Frame',1,[390 60 420 80]);
port(acq,'Out','Valid',2,[390 115 420 135]);
wire(acq,'Nonoverlapping_frame_buffer/1','Out_Frame/1');
wire(acq,'Nonoverlapping_frame_buffer/2','Out_Valid/1');
note(acq,'1 kHz sample rate; first completed frame at 63 ms; update period 64 ms. X-only deployed contract.',[20 185 580 235]);

pipe=subsystem(mdl,'05_FFT64_INT8_NPU',[965 125 1160 275]);
% [주6] Enable 포트로 완성된 프레임에서만 NPU를 실행합니다.
% 정수 FFT/64→4개 대역 특징→4개 ReLU 은닉값→2개 logit 순서입니다.
% logit은 확률이 아닌 정수 점수이며 동점이면 정상 클래스를 선택합니다.
% sprintf 문자열은 블록 안에 들어갈 별도 MATLAB 코드를 생성합니다.
add_block('simulink/Ports & Subsystems/Enable',[pipe '/Frame_valid'],...
    'Position',[35 20 55 40]);
port(pipe,'In','Frame',1,[20 105 50 125]);
chart(pipe,'Fixed_point_FFT64',sprintf('function v=fcn(u)\nv=fourier_fft_sl(u);\nend'),[95 90 245 140]);
chart(pipe,'Four_band_L1_features',sprintf('function f=fcn(u)\nf=fourier_features_sl(u);\nend'),[295 90 465 140]);
chart(pipe,'INT8_4x4_ReLU',sprintf(['function h=fcn(f)\n' ...
    'h=max(0,min(127,floor((%s*double(f(:))+%s)/2^%d)));\nend'],...
    mat2str(double(M.w1)),mat2str(double(M.b1(:))),M.shift1),[515 90 670 140]);
chart(pipe,'INT8_4x2_logits',sprintf(['function o=fcn(h)\n' ...
    'o=max(-128,min(127,floor((%s*double(h(:))+%s)/2^%d)));\nend'],...
    mat2str(double(M.w2)),mat2str(double(M.b2(:))),M.shift2),[720 90 875 140]);
chart(pipe,'Argmax_tie_to_normal',sprintf('function c=fcn(o)\nc=double(o(2)>o(1));\nend'),[925 90 1090 140]);
chain={'In_Frame','Fixed_point_FFT64','Four_band_L1_features','INT8_4x4_ReLU','INT8_4x2_logits','Argmax_tie_to_normal'};
for k=1:numel(chain)-1, wire(pipe,[chain{k} '/1'],[chain{k+1} '/1']); end
outputs={'Features','Hidden','Logits','Class'};
for k=1:4
    port(pipe,'Out',outputs{k},k,[410+175*k 235 440+175*k 255]);
    wire(pipe,[chain{k+2} '/1'],['Out_' outputs{k} '/1']);
end
note(pipe,'Enabled only at complete frames. Rectangular window, FFT/64, bins 1..6 / 7..12 / 13..20 / 21..31; integer floor + saturation.',[45 320 1130 365]);

safe=subsystem(mdl,'06_Safety_policy_observer',[970 380 1160 515]);
% [주7] 경고·25% 제한·정지 래치·watchdog를 관찰하되 그 출력은 외력에
% 연결하지 않습니다. 따라서 안전 정책에 따른 모터 감속을 계산하는 폐루프는 아닙니다.
inputs={'Class','Valid','Heartbeat'};
for k=1:3, port(safe,'In',inputs{k},k,[20 35+60*k 50 55+60*k]); end
script=sprintf(['function y=fcn(cls,valid,hb)\n' ...
    'persistent state\nif isempty(state), state=zeros(5,1); end\n' ...
    '[state,y]=vib3d_supervisor_step(state,cls,valid,hb,true,false,0.5,%d);\nend'],round(0.5*p.fs));
chart(safe,'Warning_derate_latch_watchdog',script,[130 105 365 185]);
for k=1:3, wire(safe,['In_' inputs{k} '/1'],sprintf('Warning_derate_latch_watchdog/%d',k)); end
port(safe,'Out','Policy',1,[440 135 470 155]);
wire(safe,'Warning_derate_latch_watchdog/1','Out_Policy/1');
note(safe,'Sampled observer: 1/2/3 abnormal frames -> warning / 25% cap / latch. 500 ms watchdog. Output does not drive the prescribed mechanical excitation.',[25 270 650 330]);

wire(mdl,'01_Excitation/1','02_Housing_6DOF/1');
wire(mdl,'02_Housing_6DOF/3','03_XYZ_Accelerometer/1');
wire(mdl,'01_Excitation/2','03_XYZ_Accelerometer/2');
wire(mdl,'03_XYZ_Accelerometer/1','04_X_axis_64_sample_frames/1');
wire(mdl,'04_X_axis_64_sample_frames/1','05_FFT64_INT8_NPU/1');
wire(mdl,'04_X_axis_64_sample_frames/2','05_FFT64_INT8_NPU/Enable');
wire(mdl,'05_FFT64_INT8_NPU/4','06_Safety_policy_observer/1');
wire(mdl,'04_X_axis_64_sample_frames/2','06_Safety_policy_observer/2');
wire(mdl,'01_Excitation/3','06_Safety_policy_observer/3');

logging=subsystem(mdl,'07_Research_logging',[1230 135 1415 505]);
% [주8] Timeseries로 모든 샘플을 보관해 MATLAB 기준 계산과 같은 시각을 비교합니다.
% 클래스가 유지되는 구간과 새 판정 valid를 함께 보아야 프레임 수를 정확히 셉니다.
signals={'state','accel','raw','valid','features','hidden','logits','class','safety'};
origins={'02_Housing_6DOF/1','02_Housing_6DOF/2','03_XYZ_Accelerometer/1',...
    '04_X_axis_64_sample_frames/2','05_FFT64_INT8_NPU/1','05_FFT64_INT8_NPU/2',...
    '05_FFT64_INT8_NPU/3','05_FFT64_INT8_NPU/4','06_Safety_policy_observer/1'};
for k=1:numel(signals)
    port(logging,'In',signals{k},k,[25 25+55*k 55 45+55*k]);
    add_block('simulink/Sinks/To Workspace',[logging '/Log_' signals{k}],...
        'VariableName',['sl_' signals{k}],'SaveFormat','Timeseries',...
        'MaxDataPoints','inf','Decimation','1','SampleTime',num2str(p.dt,17),...
        'Position',[145 20+55*k 315 50+55*k]);
    wire(logging,['In_' signals{k} '/1'],['Log_' signals{k} '/1']);
    wire(mdl,origins{k},sprintf('07_Research_logging/%d',k));
end
note(mdl,'VIBRATION NPU | 6-DOF mechanics -> XYZ sensing -> FPGA-compatible X-only FFT/INT8 inference',[35 20 1380 65]);
note(mdl,['Illustrative mechanical parameters; see research guide. 3D playback uses logged q(t). ' ...
    'Synthetic predictions do not establish real fault accuracy.'],[35 570 1390 620]);
set_param(mdl,'Location',[30 50 1510 780],'ZoomFactor','FitSystem');
model_path=fullfile(outdir,[mdl '.slx']); save_system(mdl,model_path);
end

function path=subsystem(parent,name,position)
path=[parent '/' name];
add_block('built-in/Subsystem',path,'Position',position,'BackgroundColor','lightBlue');
end
function port(parent,direction,name,index,position)
add_block(['built-in/' direction 'port'],[parent '/' direction '_' name],...
    'Port',num2str(index),'Position',position);
end
function chart(parent,name,script,position)
% 아래 보조 함수들은 블록·포트·배선·주석을 만드는 반복 작업을 묶은 것입니다.
% chart는 MATLAB Function 블록의 내부 코드를 설정합니다.
path=[parent '/' name];
add_block('simulink/User-Defined Functions/MATLAB Function',path,'Position',position);
c=find(sfroot,'-isa','Stateflow.EMChart','Path',path);
assert(isscalar(c),'Could not configure MATLAB Function: %s',path); c.Script=script;
end
function wire(parent,source,destination)
add_line(parent,source,destination,'autorouting','on');
end
function note(parent,content,position)
a=Simulink.Annotation(parent,content); a.Position=position; a.FontSize=12;
end
