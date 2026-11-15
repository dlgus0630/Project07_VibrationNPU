function records = load_measured_motor(projectRoot)
% 읽는 순서: 원본 5개 CSV → 형식/기록 순서 확인 → Q12 단위 확인 → records에 저장.
% 입력 projectRoot: artifacts/experiments 폴더를 가진 상위 프로젝트 경로입니다.
% 출력 records(k).values: [기록 수 x 7]의 속도 지령/속도/PWM/적분값/상태 기록입니다.
% 출력 exported_values: [기록 수 x 3]의 목표 rpm, 측정 rpm, PWM 듀티(%)입니다.
% 속도 지령과 PWM은 제어기가 기록한 값이고, measured_rpm은 엔코더 속도 기록입니다.
%LOAD_MEASURED_MOTOR Load the five original hardware telemetry captures.
% No synthetic input, resampling, gap filling, or model output is permitted.
% t is the CSV's sample-counter time, not an independently measured timestamp.
names = {'open_loop_identification', 'step_original_gains', ...
    'step_candidate_gains', 'disturbance_2026-09-16_v4_final', ...
    'disturbance_2026-09-16_v5_repeat'};
columns = {'reference_q12', 'measured_q12', 'duty_q12', ...
    'integral_q12', 'armed', 'fault', 'enabled'};
exportColumns = {'target_rpm', 'measured_rpm', 'duty_percent'};
required = [{'sample', 'time_s'}, columns, exportColumns];
template = struct('name', '', 't', [], 'values', [], 'table', table(), ...
    'source_file', '', 'sha256', '', 'column_names', {columns}, ...
    'exported_values', [], 'exported_column_names', {exportColumns}, ...
    'sample_period_nominal_s', 0.01, 'time_basis', ...
    'CSV sample counter / nominal 100 Hz; not a measured wall clock', ...
    'missing_counter_samples', 0);
records = repmat(template, 1, numel(names));
% The original exporter uses CPR=988.427, counts/s full scale=1800.
% These are the archived unit conversion, not new plant parameters.
rpmPerCode = (1800 * 60 / 988.427) / 4096;
% [주1] Q12에서는 정수 코드 4096이 정규화 값 1입니다. 속도는 code/4096에
% 1800 counts/s와 60 s/min을 곱하고 988.427 counts/rev로 나누어 rpm으로 바꿉니다.
% 이 계수는 원래 CSV 내보내기의 단위 환산값이며, 새로 추정한 모터 모델이 아닙니다.
for k = 1:numel(names)
    relative = ['artifacts/experiments/' names{k} '.csv'];
    path = fullfile(projectRoot, relative);
    assert(isfile(path), 'Measured:MissingMotorCapture', ...
        'Required original capture is missing: %s', relative);
    T = readtable(path, 'VariableNamingRule', 'preserve');
    assert(isequal(T.Properties.VariableNames, required), ...
        'Measured:MotorSchema', 'Unexpected telemetry schema in %s.', relative);
    data = T{:, required};
    assert(isnumeric(data) && size(data, 1) >= 2 && all(isfinite(data(:))), ...
        'Measured:MotorNumeric', 'Nonfinite or insufficient telemetry in %s.', relative);
    integerColumns = [{'sample'}, columns];
    codes = T{:, integerColumns};
    assert(all(codes(:) == fix(codes(:))), 'Measured:MotorInteger', ...
        'Integer telemetry was modified or is malformed: %s.', relative);
    assert(all(T.sample >= 0) && all(diff(T.sample) > 0) && ...
        all(diff(T.time_s) > 0), 'Measured:MotorOrder', ...
        'Sample counters and time must increase strictly: %s.', relative);
    assert(all(abs(T.time_s - T.sample / 100) < 1e-9), ...
        'Measured:MotorClock', 'CSV time is inconsistent with sample/100: %s.', relative);
    % [주2] time_s는 sample/100으로 만든 명목 시간입니다. 실제 시계로 잰 시각이
    % 아니므로 통신 지연이나 정확한 제어 주기 변동을 이 열만으로 알 수는 없습니다.
    unsigned = T{:, columns(1:3)};
    assert(all(unsigned(:) >= 0 & unsigned(:) <= 8191) && ...
        all(T.duty_q12 <= 4096) && ...
        all(T.integral_q12 >= -2147483648 & T.integral_q12 <= 2147483647), ...
        'Measured:MotorRange', 'Telemetry field out of hardware range: %s.', relative);
    flags = T{:, columns(5:7)};
    assert(all(flags(:) == 0 | flags(:) == 1), ...
        'Measured:MotorFlags', 'Telemetry status must contain binary flags: %s.', relative);
    expected = [T.reference_q12 * rpmPerCode, T.measured_q12 * rpmPerCode, ...
        T.duty_q12 * 100 / 4096];
    % [주3] PWM의 4096은 듀티 100%입니다. integral_q12는 내부 적분 레지스터이므로
    % 속도 환산 계수를 적용하지 않고 원래 코드 단위로 유지합니다.
    % 아래 비교는 CSV의 rpm/% 값이 원래 Q12 코드에서 올바르게 환산됐는지 확인합니다.
    exported = T{:, exportColumns};
    delta = abs(expected - exported);
    assert(all(delta(:) <= 1e-9 + 1e-10 * abs(expected(:))), ...
        'Measured:MotorUnits', 'Exported RPM/duty contradict original Q12: %s.', relative);
    records(k).name = names{k};
    records(k).t = T.time_s;
    records(k).values = T{:, columns};
    records(k).table = T;
    records(k).source_file = relative;
    records(k).sha256 = file_sha256(path);
    % [주4] 모터 파일의 해시는 결과와 원본을 연결하기 위해 기록합니다.
    % 이 함수는 미리 알려진 해시와 대조하지 않으므로 해시 기록 자체가 원본 인증은 아닙니다.
    records(k).exported_values = exported;
    records(k).missing_counter_samples = sum(diff(T.sample) - 1);
    % 카운터가 10→13이면 두 기록이 누락된 것입니다. 누락 개수만 세고 값을 채우지 않습니다.
end
end

function digest = file_sha256(path)
% 보조 함수: 입력 파일의 바이트를 SHA-256으로 요약하여 64자리 16진수 문자열을 돌려줍니다.
% onCleanup은 읽는 도중 오류가 나더라도 열린 파일을 닫아 줍니다.
fid = fopen(path, 'rb');
assert(fid >= 0, 'Measured:ReadMotor', 'Cannot read original capture: %s.', path);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes = fread(fid, Inf, '*uint8');
md = java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(bytes, 'int8'));
digest = lower(reshape(dec2hex(typecast(md.digest(), 'uint8'), 2).', 1, []));
end
