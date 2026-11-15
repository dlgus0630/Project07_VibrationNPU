% [공부/시연용] 12->9->12 V 외란시험 telemetry CSV를 그리고,
% IDENTIFY_MOTOR.m이 식별한 FOPDT 모델(plant gain/tau/deadtime)의
% 예측 응답을 같은 duty 입력에 대해 시뮬레이션해서 겹쳐 보여준다.
%
% 게이트 검증 대상이 아닌 발표/README용 스크립트다. 로컬 저장소에서는
% docs/demo/ 아래에 있어(EXCLUDED라 digest에 안 잡힘), MATLAB Online에서
% 쓰려면 Project07_VibrationNPU/docs/demo/ 폴더를 만들어 이 파일만 넣으면
% 된다(그 폴더도 digest에서 제외되므로 기존 official gate에 영향 없음).
%
% 사용법 (MATLAB Online 또는 로컬 MATLAB):
%   csv_path = 'artifacts/experiments/disturbance_2026-09-17_v3.csv';
%   plot_disturbance_overlay(csv_path)

function plot_disturbance_overlay(csv_path)
    if nargin < 1
        csv_path = 'artifacts/experiments/disturbance_2026-09-17_v3.csv';
    end
    T = readtable(csv_path);

    t = T.time_s;
    duty_pct = T.duty_percent;
    measured_rpm = T.measured_rpm;
    target_rpm = T.target_rpm;

    % 2026-09-17 IDENTIFY_MOTOR.m 식별 결과 (HANDOFF.md 참고)
    plant_gain = 71.36;   % RPM per duty-fraction (0..1)
    tau = 0.620;          % s
    dead_time = 0.060;    % s

    duty_fraction = duty_pct / 100.0;
    baseline_duty = mean(duty_fraction(t < 3.5));
    baseline_rpm = mean(measured_rpm(t < 3.5));

    dt = mean(diff(t));
    delay_samples = max(0, round(dead_time / dt));
    duty_delayed = [repmat(duty_fraction(1), delay_samples, 1); duty_fraction(1:end-delay_samples)];

    sys = tf(plant_gain, [tau, 1]);
    predicted_delta_rpm = lsim(sys, duty_delayed - baseline_duty, t);
    predicted_rpm = baseline_rpm + predicted_delta_rpm;

    figure('Color', 'w', 'Position', [100 100 900 600]);
    tiledlayout(2, 1);

    nexttile;
    plot(t, duty_pct, 'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
    grid on;
    ylabel('PWM duty (%)');
    title('12 -> 9 -> 12 V disturbance: measured duty (actual PSU event)');

    nexttile;
    plot(t, measured_rpm, 'LineWidth', 1.3, 'Color', [0.85 0.2 0.2]);
    hold on;
    plot(t, predicted_rpm, '--', 'LineWidth', 1.5, 'Color', [0.1 0.1 0.1]);
    yline(target_rpm(1), ':', 'target', 'Color', [0.4 0.4 0.4]);
    grid on;
    xlabel('Time (s)');
    ylabel('Speed (RPM)');
    legend('Measured (hardware)', 'FOPDT model prediction (from IDENTIFY\_MOTOR.m gains)', ...
        'Location', 'southeast');
    title(sprintf('Measured vs model-predicted response (K=%.2f, tau=%.3fs, delay=%.3fs)', ...
        plant_gain, tau, dead_time));

    fprintf('Loaded %d samples from %s\n', height(T), csv_path);
    fprintf('Baseline duty %.1f%%, baseline RPM %.2f\n', 100*baseline_duty, baseline_rpm);
end
