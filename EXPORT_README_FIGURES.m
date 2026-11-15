function EXPORT_README_FIGURES()
% README용 실제 MATLAB 그림과 Simulink 다이어그램을 내보냅니다.
% 먼저 RUN_MATLAB_CHECKS, RUN_MEASURED_STUDY를 실행합니다.
% [주1] 원본 결과가 없거나 실측 Simulink 비교가 실패했으면 그림을 꾸며 대신하지 않습니다.
% 이 함수는 기존 Python 미리보기 파일을 덮어쓰지 않고 matlab_exports에 따로 저장합니다.
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'matlab'),fullfile(root,'matlab','measured'));
reference=fullfile(root,'reports','matlab_reference.mat');
assert(isfile(reference),'먼저 RUN_MATLAB_CHECKS를 실행하세요.');
statuspath=fullfile(root,'reports','measured','measured_run_status.json');
assert(isfile(statuspath),'먼저 RUN_MEASURED_STUDY를 실행하세요.');
status=jsondecode(fileread(statuspath));
assert(isfield(status,'output_receipt') && ...
    isfield(status.output_receipt,'format_version') && status.output_receipt.format_version==1, ...
    'Measured:MissingReceipt','결과 지문이 없는 이전 기록입니다. RUN_MEASURED_STUDY를 다시 실행하세요.');
assert(strcmp(status.status,'COMPLETED') && ...
    strcmp(status.simulink,'PASSED_EXACT_RECORDED_DATA_REPLAY'), ...
    '실측 분석과 Simulink 원본 비교가 모두 통과해야 내보냅니다.');
% [주2] 과거 PASS 문자열만 믿지 않고 그 실행의 입력·소스·모델·분석 결과를 모두 대조한다.
% 지문 일치는 같은 파일이라는 뜻이며 새로운 독립 실험의 성능을 보증하지 않는다.
verified=verify_files(root,status.output_receipt.files,'실측 결과');
required={'reports/measured/input_provenance.json',...
    'reports/measured/measured_vibration_replay.slx',...
    'reports/measured/measured_motor_telemetry_replay.slx'};
assert(all(ismember(required,verified)),'Measured:IncompleteReceipt',...
    '진동·모터 모델의 결과 지문이 필요합니다. 기본 옵션으로 RUN_MEASURED_STUDY를 다시 실행하세요.');
provenance=jsondecode(fileread(fullfile(root,required{1})));
assert(isfield(provenance,'matlab_sources') && ~isempty(provenance.matlab_sources),...
    'Measured:MissingSourceReceipt','소스 지문이 없습니다. RUN_MEASURED_STUDY를 다시 실행하세요.');
verify_files(root,provenance.files,'실측 입력/소스');
goldenHash=verify_golden(root);
outdir=fullfile(root,'docs','images','matlab_exports');
if ~isfolder(outdir),mkdir(outdir);end
R=load(reference);
fig=figure('Color','w','Position',[80 80 1400 650]);
cleanup=onCleanup(@()close(fig));
tiledlayout(fig,1,3,'TileSpacing','compact');
% Golden의 마지막 4개는 합성 극값 시험이므로 대표 실측 그래프에는 첫 16개만 표시합니다.
values={R.expected_f(1:16,:),R.expected_h(1:16,:),R.expected_o(1:16,:)};
titles={'4 band features','4 hidden activations','2 output logits'};
for k=1:3
    nexttile;imagesc(values{k});colorbar;
    xlabel('Channel (MATLAB 1-based index)');ylabel('Recorded Golden case (1..16)');
    title(titles{k});
end
sgtitle('MATLAB reference: 16 recorded frames -> features -> hidden -> logits');
exportgraphics(fig,fullfile(outdir,'npu_tensors_matlab.png'),'Resolution',180);
savefig(fig,fullfile(outdir,'npu_tensors_matlab.fig'));
clear cleanup;

% [주3] 이번 성공 receipt에 든 PNG/FIG만 복사하여 폴더에 남은 과거 그림을 제외한다.
folders={'vibration','motor'};
for k=1:numel(folders)
    target=fullfile(outdir,folders{k});
    if ~isfolder(target),mkdir(target);end
    copied=0;
    for j=1:numel(verified)
        [folder,name,ext]=fileparts(verified{j});
        if strcmp(strrep(folder,'\','/'),['reports/measured/' folders{k}]) && ...
                any(strcmpi(ext,{'.png','.fig'}))
            copyfile(fullfile(root,verified{j}),fullfile(target,[name ext]));
            copied=copied+1;
        end
    end
    assert(copied>0,'실측 그래프 지문이 없습니다: %s. RUN_MEASURED_STUDY를 다시 실행하세요.',folders{k});
end
models={'fourier_npu_algorithm','measured_vibration_replay','measured_motor_telemetry_replay'};
paths={fullfile(root,'reports'),fullfile(root,'reports','measured'),fullfile(root,'reports','measured')};
for k=1:numel(models)
    mdl=models{k};path=fullfile(paths{k},[mdl '.slx']);
    assert(isfile(path),'모델이 없습니다: %s',path);
    alreadyLoaded=bdIsLoaded(mdl);
    if alreadyLoaded
        assert(strcmp(get_param(mdl,'Dirty'),'off') && ...
            strcmp(strrep(get_param(mdl,'FileName'),'\','/'),strrep(path,'\','/')),...
            'Measured:UnsavedModel','검증 파일과 다른 열린 모델입니다. 수정 내용을 보존한 뒤 %s 모델을 닫고 다시 내보내세요.',mdl);
    end
    load_system(path);
    print(['-s' mdl],'-dpng','-r180',fullfile(outdir,[mdl '.png']));
    % 루트뿐 아니라 FFT/NPU/품질/로깅 등 실제 Subsystem 내부도 각각 내보냅니다.
    if k==2
        subs=find_system(mdl,'SearchDepth',1,'BlockType','SubSystem');
        for j=1:numel(subs)
            name=get_param(subs{j},'Name');
            print(['-s' subs{j}],'-dpng','-r180',fullfile(outdir,[name '.png']));
        end
    end
    if ~alreadyLoaded,close_system(mdl,0);end
end
% 내보내는 동안 원본이 바뀐 경우에도 성공 메시지를 남기지 않는다.
verify_files(root,status.output_receipt.files,'실측 결과');
verify_files(root,provenance.files,'실측 입력/소스');
assert(strcmp(goldenHash,verify_golden(root)),'Measured:GoldenChanged',...
    '내보내는 동안 Golden 소스가 바뀌었습니다. RUN_MATLAB_CHECKS부터 다시 실행하세요.');
copyfile(statuspath,fullfile(outdir,'measured_run_status.json'));
fprintf('Actual MATLAB/Simulink exports: %s\n',outdir);
end

function paths=verify_files(root,files,context)
% 파일 하나라도 없거나 달라졌으면 이전 성공 결과를 현재 결과처럼 내보내지 않는다.
assert(isstruct(files) && ~isempty(files) && all(isfield(files,{'file','sha256'})),...
    'Measured:InvalidReceipt','%s 지문 형식이 없습니다. RUN_MEASURED_STUDY를 다시 실행하세요.',context);
paths={files.file};
assert(numel(unique(paths))==numel(paths),'Measured:DuplicateReceipt','중복 결과 지문입니다.');
for k=1:numel(files)
    path=fullfile(root,files(k).file);
    assert(isfile(path) && strcmp(measured_sha256(path),files(k).sha256),...
        'Measured:StaleExport','%s 파일이 없거나 변경됐습니다: %s. RUN_MEASURED_STUDY를 다시 실행하세요.',...
        context,files(k).file);
end
end

function hash=verify_golden(root)
% 기존 gate는 읽기만 한다. 실제 검증이 만든 ZIP의 MAT/SLX와 현재 결과도 대조한다.
marker=fullfile(root,'reports','matlab.pass');
archive=fullfile(root,'reports','matlab_results.zip');
assert(isfile(marker) && isfile(archive),'Measured:MissingGoldenGate',...
    '현재 소스의 Golden 검증 결과가 필요합니다. RUN_MATLAB_CHECKS를 실행하세요.');
hash=source_digest(root);
assert(strcmp(strtrim(fileread(marker)),hash),'Measured:StaleGoldenGate',...
    'Golden 검증 이후 소스가 바뀌었습니다. RUN_MATLAB_CHECKS를 다시 실행하세요.');
temporary=tempname;mkdir(temporary);
cleanup=onCleanup(@()rmdir(temporary,'s')); %#ok<NASGU>
unzip(archive,temporary);
archivedMarker=fullfile(temporary,'reports','matlab.pass');
assert(isfile(archivedMarker) && strcmp(strtrim(fileread(archivedMarker)),hash),...
    'Measured:StaleGoldenArchive','Golden 결과 ZIP이 이전 소스입니다. RUN_MATLAB_CHECKS를 다시 실행하세요.');
outputs={'matlab_reference.mat','fourier_npu_algorithm.slx'};
for k=1:numel(outputs)
    actual=fullfile(root,'reports',outputs{k});
    saved=fullfile(temporary,'reports',outputs{k});
    assert(isfile(actual) && isfile(saved) && strcmp(measured_sha256(actual),measured_sha256(saved)),...
        'Measured:ChangedGoldenOutput','Golden 결과가 검증 당시와 다릅니다: %s. RUN_MATLAB_CHECKS를 다시 실행하세요.',outputs{k});
end
end
