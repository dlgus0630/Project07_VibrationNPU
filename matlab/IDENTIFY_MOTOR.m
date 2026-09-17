function result=IDENTIFY_MOTOR(csv_path,make_plot)
% Identify a first-order-plus-dead-time model from open-loop UART telemetry.
if nargin<1,csv_path=fullfile('data','open_loop_identification.csv');end
if nargin<2,make_plot=true;end
T=readtable(csv_path);
valid=T.enabled==1 & T.fault==0;
t=T.time_s(valid);u=T.duty_percent(valid)/100;y=T.measured_rpm(valid);
assert(numel(t)>=1000,'Capture at least 10 seconds of valid open-loop data.');
assert(max(u)-min(u)>=0.20,'Use at least 20 percentage points of duty excitation.');
Ts=median(diff(t));y=movmean(y,[9 0]);
n=numel(y);train_end=floor(0.60*n);validation_end=floor(0.80*n);

best.validation_rmse=Inf;
for delay=0:round(0.5/Ts)
    first=2+delay;
    rows=(first:train_end)';
    X=[y(rows-1),u(rows-1-delay),ones(numel(rows),1)];
    theta=X\y(rows);
    a=theta(1);b=theta(2);
    if a<=0 || a>=1 || b<=0,continue;end
    predicted=simulate_model(y(1),u,a,b,theta(3),delay);
    validation_rows=(train_end+1:validation_end)';
    validation_rmse=sqrt(mean((y(validation_rows)-predicted(validation_rows)).^2));
    if validation_rmse<best.validation_rmse
        best=struct('validation_rmse',validation_rmse,'a',a,'b',b,'offset',theta(3),...
            'delay',delay,'predicted',predicted);
    end
end
assert(isfinite(best.validation_rmse),'Identification failed; inspect excitation and encoder data.');

gain_rpm_per_pu=best.b/(1-best.a);
tau=-Ts/log(best.a);
dead_time=best.delay*Ts;
train_rows=(2+best.delay:train_end)';
validation_rows=(train_end+1:validation_end)';test_rows=(validation_end+1:n)';
train_rmse=sqrt(mean((y(train_rows)-best.predicted(train_rows)).^2));
validation_rmse=sqrt(mean((y(validation_rows)-best.predicted(validation_rows)).^2));
test_rmse=sqrt(mean((y(test_rows)-best.predicted(test_rows)).^2));
test_fit_percent=100*(1-norm(y(test_rows)-best.predicted(test_rows))/...
    norm(y(test_rows)-mean(y(test_rows))));
full_scale_rpm=1800*60/988.427;
gain_pu=gain_rpm_per_pu/full_scale_rpm;
lambda=max(tau,4*Ts);
kp_imc=tau/(gain_pu*(lambda+dead_time));
ki_imc=kp_imc/tau;

result=table(gain_rpm_per_pu,tau,dead_time,train_rmse,validation_rmse,test_rmse,test_fit_percent,...
    kp_imc,ki_imc,round(kp_imc*65536),round(ki_imc*Ts*65536),...
    'VariableNames',{'PlantGain_RPM_per_dutyPU','Tau_s','DeadTime_s','Train_RMSE_RPM',...
    'Validation_RMSE_RPM','Test_RMSE_RPM','TestFit_pct','IMC_Kp','IMC_Ki_per_s',...
    'IMC_Kp_Q16','IMC_KiTs_Q16'});
[folder,name]=fileparts(csv_path);if isempty(folder),folder='.';end
writetable(result,fullfile(folder,[name '_identified_model.csv']));
if make_plot,try
    figure('Color','w');
    tiledlayout(2,1);
    nexttile;plot(t,100*u,'LineWidth',1.2);grid on;ylabel('PWM duty (%)');
    nexttile;plot(t,y,'LineWidth',1.2);hold on;plot(t,best.predicted,'--','LineWidth',1.3);
    grid on;xlabel('Time (s)');ylabel('Speed (RPM)');legend('Measured','FOPDT/ARX fit');
    xline(t(train_end),':','Train end');xline(t(validation_end),':','Validation end');
    title(sprintf('Test fit %.1f%%, K %.2f RPM/pu, tau %.3f s, delay %.3f s',...
        test_fit_percent,gain_rpm_per_pu,tau,dead_time));
    exportgraphics(gcf,fullfile(folder,[name '_identification.png']),'Resolution',200);
catch plot_error
    warning('Plot skipped: %s',plot_error.message);
end,end
disp(result);
end

function predicted=simulate_model(initial,u,a,b,offset,delay)
predicted=zeros(size(u));predicted(1)=initial;
for k=2:numel(u)
    source=max(1,k-1-delay);
    predicted(k)=a*predicted(k-1)+b*u(source)+offset;
end
end
