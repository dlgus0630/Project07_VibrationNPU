function RUN_MATLAB_CHECKS()
root=fileparts(mfilename('fullpath'));
old=pwd;
cleanup=onCleanup(@()cd(old));
cd(root);
addpath(fullfile(root,'matlab'));
outdir=fullfile(root,'reports');
if ~exist(outdir,'dir'),mkdir(outdir);end
Simulink.fileGenControl('set','CacheFolder',fullfile(outdir,'sim_cache'),...
    'CodeGenFolder',fullfile(outdir,'sim_codegen'),'createDir',true);
source_hash=source_digest(root);
marker=fullfile(outdir,'matlab.pass');
if exist(marker,'file'),delete(marker);end

M=jsondecode(fileread(fullfile(root,'data','model.json')));
cases=readmatrix(fullfile(root,'data','cases.csv'));
expected_f=reshape(read_hex('features.mem',8,false),4,[])';
expected_h=reshape(read_hex('hidden.mem',8,true),4,[])';
expected_o=reshape(read_hex('logits.mem',8,true),2,[])';
expected_r=reshape(read_hex('fft_re.mem',16,true),64,[])';
expected_i=reshape(read_hex('fft_im.mem',16,true),64,[])';
for k=1:size(cases,1)
    [r,i,f]=fft64_fixed(cases(k,:));
    [h,o]=npu_int8(f,M);
    assert(isequal(r',expected_r(k,:)) && isequal(i',expected_i(k,:)),...
        'FFT Golden mismatch at case %d',k);
    assert(isequal(f',expected_f(k,:)) && isequal(h',expected_h(k,:)) && isequal(o',expected_o(k,:)),...
        'NPU Golden mismatch at case %d',k);
end

assignin('base','VIB_MODEL',M);
assignin('base','VIB_INPUT',cases(1,:)');
build_model(outdir);
for k=1:size(cases,1)
    assignin('base','VIB_INPUT',cases(k,:)');
    result=sim('fourier_npu_algorithm','ReturnWorkspaceOutputs','on');
    actual=double(reshape(result.get('sl_logits'),1,[]));
    assert(numel(actual)==2 && isequal(actual,expected_o(k,:)),...
        'Simulink NPU mismatch at case %d',k);
    fprintf('Fourier Simulink %d/%d PASS\n',k,size(cases,1));
end

save(fullfile(outdir,'matlab_reference.mat'),'M','expected_f','expected_h','expected_o','expected_r','expected_i');
close_system('fourier_npu_algorithm',0);
assert(strcmp(source_hash,source_digest(root)),'Source changed during validation; rerun.');
write_marker(marker,source_hash);
zip(fullfile(outdir,'matlab_results.zip'),...
    {'reports/matlab.pass','reports/matlab_reference.mat','reports/fourier_npu_algorithm.slx'},root);
fprintf('MATLAB/SIMULINK PASS. Download reports/matlab_results.zip.\n');
end

function write_marker(path,value)
file=fopen(path,'w');
assert(file>=0,'Cannot write marker');
cleanup=onCleanup(@()fclose(file));
fprintf(file,'%s\n',value);
end

function values=read_hex(name,bits,signed_value)
values=sscanf(fileread(fullfile('data',name)),'%x');
if signed_value
    values(values>=2^(bits-1))=values(values>=2^(bits-1))-2^bits;
end
end

