function build_model(outdir)
M=evalin('base','VIB_MODEL');
mdl='fourier_npu_algorithm';
if bdIsLoaded(mdl),close_system(mdl,0);end
new_system(mdl);
set_param(mdl,'Solver','FixedStepDiscrete','FixedStep','1','StopTime','0');
add_block('simulink/Sources/Constant',[mdl '/Samples'],'Value','VIB_INPUT','Position',[20 50 90 90]);
names={'FFT64','Band_features','Hidden_ReLU','Output_requantize'};
scripts={...
    sprintf('function v=fcn(u)\nv=fourier_fft_sl(u);\nend'),...
    sprintf('function f=fcn(u)\nf=fourier_features_sl(u);\nend'),...
    sprintf(['function h=fcn(u)\nw=%s;\nb=%s;\n' ...
        'h=max(0,min(127,floor((w*double(u(:))+b)/2^%d)));\nend'],...
        mat2str(double(M.w1)),mat2str(double(M.b1(:))),double(M.shift1)),...
    sprintf(['function o=fcn(u)\nw=%s;\nb=%s;\n' ...
        'o=max(-128,min(127,floor((w*double(u(:))+b)/2^%d)));\nend'],...
        mat2str(double(M.w2)),mat2str(double(M.b2(:))),double(M.shift2))};
previous='Samples';
for k=1:4
    add_matlab_function(mdl,names{k},scripts{k},[130*k 45 130*k+100 95]);
    add_line(mdl,[previous '/1'],[names{k} '/1']);
    previous=names{k};
end
add_block('simulink/Sinks/To Workspace',[mdl '/Logits'],...
    'VariableName','sl_logits','SaveFormat','Array','Position',[680 50 770 90]);
add_line(mdl,[previous '/1'],'Logits/1');
save_system(mdl,fullfile(outdir,[mdl '.slx']));
end

function add_matlab_function(model,name,script,position)
path=[model '/' name];
add_block('simulink/User-Defined Functions/MATLAB Function',path,'Position',position);
chart=find(sfroot,'-isa','Stateflow.EMChart','Path',path);
assert(isscalar(chart),'Could not configure MATLAB Function block: %s',path);
chart.Script=script;
end

