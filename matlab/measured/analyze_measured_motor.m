function report = analyze_measured_motor(records, outDir, varargin)
% 읽는 순서: 실험별 유효 기록 선택 → 추종 오차/상태 집계 → 그래프와 CSV/MAT 저장.
% 입력 records: load_measured_motor의 구조체 배열, outDir: 결과 저장 폴더입니다.
% 선택 입력 'Visible','on'은 그래프 창을 표시합니다. 기본값 'off'도 그림 파일은 저장합니다.
% 출력 report.summary: 실험별 통계 표이며, 속도는 rpm, PWM 듀티는 %입니다.
%ANALYZE_MEASURED_MOTOR Plot archived measurements and descriptive statistics.
% RPM/duty use the original CSV exports; no fitted or simulated plant is used.
p = inputParser;
addParameter(p, 'Visible', 'off', @(x) any(strcmp(x, {'on', 'off'})));
parse(p, varargin{:});
if ~isfolder(outDir), mkdir(outDir); end
n = numel(records);
assert(n > 0, 'Measured:EmptyMotor', 'No motor captures were provided.');
Name = cell(n, 1); SourceFile = cell(n, 1); SHA256 = cell(n, 1);
Samples = zeros(n, 1); CounterSpanNominal_s = zeros(n, 1);
MissingCounterSamples = zeros(n, 1); TrackingSamples = zeros(n, 1);
TrackingRMSE_rpm = nan(n, 1); TrackingMAE_rpm = nan(n, 1);
RPMMinimum = zeros(n, 1); RPMMaximum = zeros(n, 1);
DutyMean_percent = zeros(n, 1); DutyMaximum_percent = zeros(n, 1);
DutySaturatedSamples = zeros(n, 1); FaultSamples = zeros(n, 1);
DisabledSamples = zeros(n, 1); figures = cell(n, 1);
for k = 1:n
    r = records(k); T = r.table;
    Name{k} = r.name; SourceFile{k} = r.source_file; SHA256{k} = r.sha256;
    Samples(k) = height(T);
    CounterSpanNominal_s(k) = T.time_s(end) - T.time_s(1);
    MissingCounterSamples(k) = r.missing_counter_samples;
    active = T.armed == 1 & T.enabled == 1 & T.fault == 0 & T.reference_q12 > 0;
    % [주1] 제어가 준비/활성 상태이고 고장이 없으며 목표 속도가 양수인 기록만 비교합니다.
    % 목표가 없는 개루프 실험은 추종 오차를 정의하기 어려워 NaN(계산 대상 아님)으로 둡니다.
    % Open-loop captures carry a zero target; tracking metrics remain NaN.
    TrackingSamples(k) = sum(active);
    if any(active)
        e = T.target_rpm(active) - T.measured_rpm(active);
        % [주2] RMSE=sqrt(mean(e^2))는 큰 오차에 더 민감하고, MAE=mean(abs(e))는
        % 평균적인 오차 크기입니다. 둘 다 rpm 단위이며, 시작/과도 구간도 포함합니다.
        % 기록 하나당 같은 비중을 주는 통계이므로 정착시간이나 시간 가중 오차와 다릅니다.
        TrackingRMSE_rpm(k) = sqrt(mean(e .^ 2));
        TrackingMAE_rpm(k) = mean(abs(e));
    end
    RPMMinimum(k) = min(T.measured_rpm); RPMMaximum(k) = max(T.measured_rpm);
    DutyMean_percent(k) = mean(T.duty_percent);
    DutyMaximum_percent(k) = max(T.duty_percent);
    DutySaturatedSamples(k) = sum(T.duty_q12 == 4096);
    % [주3] 포화 개수는 PWM이 100%인 기록 수입니다. 적분기 포화 횟수나 고장 횟수는 아닙니다.
    FaultSamples(k) = sum(T.fault == 1); DisabledSamples(k) = sum(T.enabled == 0);
    fig = figure('Color', 'w', 'Visible', p.Results.Visible, ...
        'Name', ['Measured motor: ' r.name], 'Position', [80 60 1200 950]);
    layout = tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    ax = nexttile(layout);
    % Mark samples with gaps as points: connecting across a dropout could imply
    % an unrecorded trajectory. No timestamps or values are inserted.
    if r.missing_counter_samples > 0, style = '.'; else, style = '-'; end
    % [주4] 누락이 있으면 점으로 그려 기록되지 않은 구간을 선으로 추정하지 않습니다.
    % 가로축 time_s는 명목 100 Hz 카운터 시간이며 실제 측정 시계의 경과 시간이 아닙니다.
    plot(ax, T.time_s, T.target_rpm, style, 'LineWidth', 1); hold(ax, 'on');
    plot(ax, T.time_s, T.measured_rpm, style, 'LineWidth', 1);
    ylabel(ax, 'Speed [rpm]'); grid(ax, 'on');
    legend(ax, {'Recorded reference (command)', 'Recorded encoder speed'}, 'Location', 'best');
    title(ax, strrep(r.name, '_', '\_'));
    ax = nexttile(layout);
    plot(ax, T.time_s, T.duty_percent, style);
    ylabel(ax, 'Recorded duty [%]'); ylim(ax, [-2 102]); grid(ax, 'on');
    ax = nexttile(layout);
    plot(ax, T.time_s, T.integral_q12, style);
    ylabel(ax, 'Integral register [Q12 code]'); grid(ax, 'on');
    ax = nexttile(layout);
    plot(ax, T.time_s, T{:, {'armed', 'fault', 'enabled'}}, '.');
    ylabel(ax, 'Recorded status [0/1]'); ylim(ax, [-0.15 1.15]); grid(ax, 'on');
    legend(ax, {'armed', 'fault', 'enabled'}, 'Location', 'best');
    xlabel(ax, 'CSV sample counter / nominal 100 Hz [s]; not wall-clock time');
    figures{k} = fullfile(outDir, [r.name '_measured.png']);
    exportgraphics(fig, figures{k}, 'Resolution', 180);
    if strcmp(p.Results.Visible, 'off'), close(fig); end
end
summary = table(Name, Samples, CounterSpanNominal_s, MissingCounterSamples, ...
    TrackingSamples, TrackingRMSE_rpm, TrackingMAE_rpm, RPMMinimum, RPMMaximum, ...
    DutyMean_percent, DutyMaximum_percent, DutySaturatedSamples, FaultSamples, ...
    DisabledSamples, SourceFile, SHA256);
writetable(summary, fullfile(outDir, 'motor_measured_summary.csv'));
report = struct('summary', summary, 'figure_files', {figures}, ...
    'source_hashes', {SHA256}, 'time_basis', records(1).time_basis, ...
    'tracking_metric_scope', ['Sample-weighted errors over armed, enabled, ' ...
    'fault-free, positive-reference samples; includes transients; not settling metrics']);
save(fullfile(outDir, 'motor_measured_analysis.mat'), 'report');
end
