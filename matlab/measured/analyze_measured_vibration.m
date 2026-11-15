function report = analyze_measured_vibration(dataset, outdir, visible)
% 읽는 순서: 원본으로 정수 추론 → 진단용 진동 통계/PSD → 기존 정답 비교 → 그림/표 저장.
% 입력 dataset: load_measured_vibration의 검증 결과, outdir: 저장 폴더, visible: 'on'/'off'.
% 출력 report.runs(k): 실험별 결과, summary: 실험별 표, window_metrics: 프레임별 표입니다.
% 원본 x는 [프레임 수 x 64] counts, features는 [프레임 수 x 4], logits는 [프레임 수 x 2]입니다.
%ANALYZE_MEASURED_VIBRATION Analyze recorded frames without synthesizing data.
% Inference uses the unmodified int16-range CSV counts, including DC.
% Diagnostic PSD alone subtracts each frame mean and applies a periodic
% Hann window. Its frequency grid uses the recorded NOMINAL 1000 Hz rate;
% dt_us is retained and reported, not silently regularized/interpolated.
% Frames are separated captures; a surface row is a frame, not an STFT hop.
if nargin < 2 || isempty(outdir)
    outdir = fullfile(dataset.root, 'reports', 'measured_matlab');
end
if nargin < 3 || isempty(visible), visible = 'off'; end
assert(isfield(dataset, 'provenance_checked') && dataset.provenance_checked, ...
    'Measured:UncheckedInput', 'Load inputs with load_measured_vibration first.');
assert(any(strcmp(visible, {'on','off'})), 'Measured:Visibility', ...
    'visible must be ''on'' or ''off''.');
if ~isfolder(outdir), mkdir(outdir); end
fs = double(dataset.manifest.sample_rate_hz);
N = double(dataset.manifest.samples_per_window);
frequency = (0:N/2) * fs / N;
% [주1] N=64, 명목 fs=1000 Hz이면 주파수 눈금은 fs/N=15.625 Hz 간격입니다.
% 각 프레임은 별개의 기록입니다. 3D 그림의 행을 연속 STFT 시간축으로 해석하지 않습니다.
hannPeriodic = 0.5 - 0.5*cos(2*pi*(0:N-1)/N);
hannEnergy = sum(hannPeriodic.^2);
results = struct([]);
summary = table();
windows = table();
trainingConfusion = zeros(2,2);
validationConfusion = zeros(2,2);
for k = 1:numel(dataset.runs)
    run = dataset.runs(k);
    x = run.raw;
    n = size(x,1);
    features = zeros(n,4); hidden = zeros(n,4);
    logits = zeros(n,2); classes = zeros(n,1);
    re = zeros(n,N); im = zeros(n,N);
    for j = 1:n
        % [주2] 추론 경로는 DC(프레임 평균)를 포함한 원본을 그대로 넣어 FPGA 처리를 재현합니다.
        % 특징 4개 → 은닉값 4개 → 점수 2개 → 클래스 0/1이며 점수는 확률이 아닙니다.
        [r, i, f] = fft64_fixed(x(j,:));
        [h, l, c] = npu_int8(f, dataset.model);
        re(j,:) = r.'; im(j,:) = i.'; features(j,:) = f.';
        hidden(j,:) = h.'; logits(j,:) = l.'; classes(j) = c;
    end
    dc = mean(x,2);
    % [주3] 여기부터의 평균 제거는 진동 크기를 보는 진단용입니다. 위 추론 입력은 바뀌지 않습니다.
    % AC RMS는 평균 주변의 흔들림, raw RMS는 평균 성분까지 포함한 전체 크기입니다.
    centered = x-dc;
    acRMS = sqrt(mean(centered.^2,2));
    rawRMS = sqrt(mean(x.^2,2));
    peakAC = max(abs(centered),[],2);
    crest = peakAC ./ acRMS;
    % 파고율(crest factor)=AC 최대 절댓값/AC RMS로, 순간 피크가 두드러지는 정도입니다.
    % counts끼리 나누므로 무차원이며, 일정한 프레임은 분모가 0이어서 정의되지 않습니다.
    crest(acRMS == 0) = NaN; % Undefined for a constant frame, not zero.
    adcSaturation = sum(x == -32768 | x == 32767,2);
    diagnosticFFT = fft(centered .* hannPeriodic, N, 2);
    % [주4] Hann 창은 짧게 잘라 본 파형의 양끝 불연속에 따른 주파수 누설을 줄입니다.
    % PSD=|FFT|^2/(fs*창 에너지)의 단위는 counts^2/Hz이며 보정된 가속도 단위가 아닙니다.
    psd = abs(diagnosticFFT(:,1:N/2+1)).^2 / (fs*hannEnergy);
    psd(:,2:end-1) = 2*psd(:,2:end-1);
    % 실수 신호의 음수 주파수 에너지를 양수 쪽에 합칩니다. DC와 Nyquist 끝점은 두 배 하지 않습니다.
    [~, peakIndex] = max(psd(:,2:end),[],2);
    peakFrequency = reshape(frequency(peakIndex+1), [], 1);
    % 최대 PSD의 주파수는 DC를 제외한 '가장 큰 눈금'입니다. 정밀한 공진 주파수 추정은 아닙니다.
    intervals = run.dt_us(:,2:end);
    meanDt = mean(intervals,2);
    stdDt = std(intervals,0,2);
    maxJitter = max(abs(intervals-1e6/fs),[],2);
    % [주5] dt_us로 측정 간격의 흔들림을 따로 보고합니다. PSD의 명목 주파수 눈금이
    % 이 흔들림을 보정한 것은 아니며, host_time_s의 차이는 PC 수신 간격입니다.
    frameDuration = run.relative_sample_time_s(:,end);
    hostElapsed = run.host_time_s-run.host_time_s(1);
    frameGap = [NaN; diff(run.host_time_s)];
    featureSaturation = sum(features == 127,2);
    hiddenSaturation = sum(hidden == 127,2);
    logitSaturation = sum(logits == -128 | logits == 127,2);
    truth = repmat(run.label,n,1);
    correct = classes == truth;
    confusion = accumarray([truth+1 classes+1],1,[2 2]);
    % [주6] 혼동행렬은 행=기록된 정답, 열=예측입니다. 라벨 0/1에 1을 더해 MATLAB 인덱스로 씁니다.
    % 대각선은 맞힌 개수이며, 기존 학습/검증 실험을 나누어 기존 모델의 결과를 재현합니다.
    % 같은 실험의 프레임은 독립 표본이 아닐 수 있어 새 데이터의 성능으로 단정할 수 없습니다.
    if strcmp(run.split,'train')
        trainingConfusion = trainingConfusion+confusion;
    else
        validationConfusion = validationConfusion+confusion;
    end
    metrics = table(repmat(string(run.run_id),n,1), ...
        repmat(string(run.split),n,1), run.window_id, truth, classes, ...
        features(:,1),features(:,2),features(:,3),features(:,4), ...
        hidden(:,1),hidden(:,2),hidden(:,3),hidden(:,4),logits(:,1),logits(:,2), ...
        run.host_time_s,hostElapsed,frameDuration,dc,acRMS,rawRMS, ...
        peakAC,crest,adcSaturation,meanDt,stdDt,maxJitter,1e6./meanDt, ...
        frameGap,peakFrequency,featureSaturation,hiddenSaturation,logitSaturation, ...
        correct, 'VariableNames', {'RunID','Split','WindowID','TrueLabel', ...
        'PredictedClass','F1','F2','F3','F4','H1','H2','H3','H4','L0','L1', ...
        'HostTime_s','HostElapsed_s','FrameDuration_s','RawMean_counts', ...
        'ACRMS_counts','RawRMS_counts','ACPeak_counts','CrestFactor', ...
        'ADCSaturatedSamples','MeanDt_us','StdDt_us','MaxAbsJitter_us', ...
        'MeanIntervalRate_Hz','HostReceiptInterval_s','PeakBinNominal_Hz', ...
        'SaturatedFeatures','SaturatedHidden','SaturatedLogits','Correct'});
    windows = [windows; metrics]; %#ok<AGROW>
    item = struct('run_id',run.run_id,'split',run.split,'label',run.label, ...
        'condition',run.condition,'features',features,'hidden',hidden, ...
        'logits',logits,'classes',classes,'fft_real',re,'fft_imag',im, ...
        'frequency_hz',frequency,'psd_counts2_per_hz',psd, ...
        'window_metrics',metrics,'confusion',confusion, ...
        'accuracy',mean(correct),'source_sha256',run.source_sha256, ...
        'metadata_sha256',run.metadata_sha256);
    % 첫 결과로 구조체 배열의 필드를 확정하여 MATLAB release별
    % struct([]) 대입 동작 차이를 피합니다.
    if k == 1
        results = item;
    else
        results(k) = item; %#ok<AGROW>
    end
    summaryRow = table(string(run.run_id),string(run.condition),string(run.split), ...
        n,sum(correct),mean(correct),mean(dc),mean(acRMS),std(acRMS), ...
        sum(adcSaturation),mean(intervals(:)),std(intervals(:)), ...
        min(intervals(:)),max(intervals(:)),median(diff(run.host_time_s)), ...
        string(run.source_sha256),string(run.metadata_sha256), ...
        'VariableNames',{'RunID','Condition','Split','Windows','Correct', ...
        'Accuracy','MeanDC_counts','MeanACRMS_counts','StdACRMS_counts', ...
        'ADCSaturatedSamples','MeanDt_us','StdDt_us','MinDt_us','MaxDt_us', ...
        'MedianHostReceiptInterval_s','CSV_SHA256','Metadata_SHA256'});
    summary = [summary; summaryRow]; %#ok<AGROW>
end
report = struct('runs',results,'summary',summary,'window_metrics',windows, ...
    'training_confusion',trainingConfusion, ...
    'validation_confusion',validationConfusion, ...
    'training_accuracy',trace(trainingConfusion)/sum(trainingConfusion(:)), ...
    'validation_accuracy',trace(validationConfusion)/sum(validationConfusion(:)), ...
    'model_sha256',dataset.model_sha256,'manifest_sha256',dataset.manifest_sha256, ...
    'confusion_order',{{'normal (0)','abnormal (1)'}}, ...
    'confusion_axes','Rows: recorded truth; columns: predicted class', ...
    'validation_note',['Reproduction on the EXISTING validation runs, not new ' ...
    'held-out data. Within-run frames may be dependent; no independent-window ' ...
    'confidence interval or generalization claim is made.'], ...
    'spectrum_note',['Independent 64-sample, mean-removed periodic-Hann periodograms; ' ...
    'nominal frequency resolution 15.625 Hz. The nominal frequency axis does ' ...
    'not correct recorded sampling jitter. No continuous STFT, longer-record ' ...
    'spectrum, displacement, three-axis orbit, or mechanical plant is inferred.'], ...
    'units','Uncalibrated raw sensor counts; PSD counts^2/Hz', ...
    'output_directory',outdir);
writetable(summary,fullfile(outdir,'measured_runs.csv'));
writetable(windows,fullfile(outdir,'measured_windows.csv'));
write_confusion(trainingConfusion,fullfile(outdir,'training_confusion.csv'));
write_confusion(validationConfusion,fullfile(outdir,'existing_validation_confusion.csv'));
write_spectrum_csv(results,fullfile(outdir,'measured_spectra.csv'));
save(fullfile(outdir,'measured_analysis.mat'),'report','-v7');
plot_measurements(dataset,report,outdir,visible);
end

function write_confusion(C,path)
% 보조 함수: 2x2 혼동행렬 C에 정답/예측 이름을 붙여 path의 CSV로 저장합니다.
T = array2table(C,'VariableNames',{'PredictedNormal','PredictedAbnormal'});
T = addvars(T, ["normal";"abnormal"], 'Before',1,'NewVariableNames','RecordedTruth');
writetable(T,path);
end

function write_spectrum_csv(results,path)
% 보조 함수: PSD [프레임 수 x 33]을 실험/프레임/주파수/PSD 열로 풀어 CSV로 저장합니다.
spectra = table();
for k = 1:numel(results)
    r = results(k); n = size(r.psd_counts2_per_hz,1); bins = numel(r.frequency_hz);
    % Window-major order makes every frequency bin traceable to its frame.
    rows = table(repmat(string(r.run_id),n*bins,1), ...
        repelem(r.window_metrics.WindowID,bins), ...
        repmat(r.frequency_hz(:),n,1), ...
        reshape(r.psd_counts2_per_hz.',[],1), ...
        'VariableNames',{'RunID','WindowID','NominalFrequency_Hz','PSD_counts2_per_Hz'});
    spectra = [spectra; rows]; %#ok<AGROW>
end
writetable(spectra,path);
end

function plot_measurements(dataset,report,outdir,visible)
% 보조 함수: 입력 원본과 report로 파형, 3D 스펙트럼, 품질 지표, 혼동행렬 그림을 저장합니다.
% [주7] 3D 축은 주파수 x 프레임 번호 x PSD입니다. 물체의 X/Y/Z 이동 궤적은 아닙니다.
nr = numel(dataset.runs);
cols = 2; rows = ceil(nr/cols);
fig = figure('Visible',visible,'Color','w','Position',[80 80 1450 1080]);
tiledlayout(fig,rows,cols,'TileSpacing','compact','Padding','compact');
for k = 1:nr
    run = dataset.runs(k); ax = nexttile;
    plot(ax,run.relative_sample_time_s(1,:)*1e3,run.raw(1,:),'.-', ...
        'LineWidth',1,'MarkerSize',9);
    grid(ax,'on'); xlabel(ax,'Recorded within-frame time (ms)');
    ylabel(ax,'Raw X-axis sensor counts');
    title(ax,sprintf('%s / %s / frame 0',run.run_id,run.split),'Interpreter','none');
end
sgtitle(fig,'Measured X-axis frames: original counts and recorded dt\_us');
finish_figure(fig,outdir,'measured_raw_frames',visible);

fig = figure('Visible',visible,'Color','w','Position',[80 80 1550 1150]);
tiledlayout(fig,rows,cols,'TileSpacing','compact','Padding','compact');
for k = 1:nr
    r = report.runs(k); ax = nexttile;
    waterfall(ax,r.frequency_hz,r.window_metrics.WindowID,r.psd_counts2_per_hz);
    view(ax,[-40 45]); grid(ax,'on');
    xlabel(ax,'Nominal frequency (Hz)'); ylabel(ax,'Recorded frame index');
    zlabel(ax,'PSD (counts^2/Hz)');
    title(ax,sprintf('%s / %s',r.run_id,r.split),'Interpreter','none');
end
sgtitle(fig,{'Recorded 3D spectrum: frequency x frame index x measured PSD', ...
    'Separate 64-sample frames; mean removed only for PSD; nominal 1000 Hz grid'});
finish_figure(fig,outdir,'measured_spectrum_3d',visible);

fig = figure('Visible',visible,'Color','w','Position',[80 80 1450 900]);
tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
axRMS = nexttile; hold(axRMS,'on'); grid(axRMS,'on');
axDC = nexttile; hold(axDC,'on'); grid(axDC,'on');
axDt = nexttile; hold(axDt,'on'); grid(axDt,'on');
axReceipt = nexttile; hold(axReceipt,'on'); grid(axReceipt,'on');
for k = 1:nr
    r = report.runs(k); T = r.window_metrics;
    plot(axRMS,T.WindowID,T.ACRMS_counts,'.-','DisplayName',r.run_id);
    plot(axDC,T.WindowID,T.RawMean_counts,'.-','DisplayName',r.run_id);
    plot(axDt,T.WindowID,T.StdDt_us,'.-','DisplayName',r.run_id);
    plot(axReceipt,T.WindowID,T.HostReceiptInterval_s,'.-','DisplayName',r.run_id);
end
title(axRMS,'Within-frame AC RMS'); ylabel(axRMS,'Counts');
title(axDC,'Raw frame mean (DC preserved in inference)'); ylabel(axDC,'Counts');
title(axDt,'Within-frame interval variability'); ylabel(axDt,'std(dt\_us), microseconds');
title(axReceipt,'Host receipt intervals (not sample gaps)'); ylabel(axReceipt,'Seconds');
for ax = [axRMS axDC axDt axReceipt]
    xlabel(ax,'Recorded frame index'); legend(ax,'Location','best','Interpreter','none');
end
sgtitle(fig,'Measurement quality and frame statistics');
finish_figure(fig,outdir,'measured_quality',visible);

fig = figure('Visible',visible,'Color','w','Position',[80 80 1100 480]);
tiledlayout(fig,1,2,'TileSpacing','compact','Padding','compact');
plot_confusion(nexttile,report.training_confusion,'Existing training runs');
plot_confusion(nexttile,report.validation_confusion,'Existing validation runs');
sgtitle(fig,'Fixed integer inference on the original raw counts');
finish_figure(fig,outdir,'measured_confusion',visible);
end

function plot_confusion(ax,C,name)
% 보조 함수: 축 ax에 2x2 행렬 C를 그립니다. trace(C)/sum(C(:))는 전체 정답률입니다.
imagesc(ax,C); axis(ax,'image'); colorbar(ax); colormap(ax,parula);
set(ax,'XTick',[1 2],'XTickLabel',{'normal','abnormal'}, ...
    'YTick',[1 2],'YTickLabel',{'normal','abnormal'});
xlabel(ax,'Predicted class'); ylabel(ax,'Recorded truth');
title(ax,sprintf('%s: %d/%d (%.2f%%)',name,trace(C),sum(C(:)), ...
    100*trace(C)/sum(C(:))));
for row = 1:2
    for col = 1:2
        text(ax,col,row,num2str(C(row,col)),'HorizontalAlignment','center', ...
            'FontWeight','bold','FontSize',16,'Color','k', ...
            'BackgroundColor','w','Margin',2);
    end
end
end

function finish_figure(fig,outdir,name,visible)
% 보조 함수: fig를 PNG와 편집 가능한 FIG로 저장하고, 비표시 모드이면 창을 닫습니다.
exportgraphics(fig,fullfile(outdir,[name '.png']),'Resolution',160);
savefig(fig,fullfile(outdir,[name '.fig']));
if strcmp(visible,'off'), close(fig); end
end
