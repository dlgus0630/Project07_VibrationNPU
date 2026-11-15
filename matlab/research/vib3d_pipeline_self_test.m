function report = vib3d_pipeline_self_test(root)
% [읽기 안내] 기존 FFT/NPU 기준 벡터와 안전 정책의 경계 조건을 확인합니다.
% 입력 root는 data 폴더를 가진 프로젝트 경로, 출력 report는 기준 사례 수와
% 정책 검사 통과 여부입니다. 실패하면 assert가 오류를 내어 실행을 중단합니다.
% [주1] 기준 벡터 일치는 정수 연산의 재현성 검사입니다. 실제 고장 진단 정확도나
% RTL의 모든 클럭 동작, 모터의 실제 안전 정지 성능까지 입증하지는 않습니다.
% Independent supplied hex vectors plus policy boundary cases.
M=jsondecode(fileread(fullfile(root,'data','model.json')));
cases=readmatrix(fullfile(root,'data','cases.csv'));
names={'fft_re.mem','fft_im.mem','features.mem','hidden.mem','logits.mem'};
width=[64 64 4 4 2]; bits=[16 16 8 8 8]; signed=[true true false true true];
% [주2] 파일별로 FFT 실수부/허수부 64개, 특징 4개, 은닉값 4개, logit 2개입니다.
% 16진수 파일에는 부호가 직접 보이지 않아 signed 항목만 2의 보수로 해석합니다.
expected=cell(1,5);
for j=1:5
    x=sscanf(fileread(fullfile(root,'data',names{j})),'%x');
    if signed(j), x(x>=2^(bits(j)-1))=x(x>=2^(bits(j)-1))-2^bits(j); end
    expected{j}=reshape(x,width(j),[])';
end
for k=1:size(cases,1)
    % 최종 클래스만 맞으면 중간 계산 오류가 숨을 수 있어 각 단계의 모든 값을 비교합니다.
    % isequal을 쓰므로 허용 오차를 둔 근사가 아니라 정수값의 완전 일치가 기준입니다.
    [re,im,f]=fft64_fixed(cases(k,:)); [h,o]=npu_int8(f,M);
    actual={re,im,f,h,o};
    for j=1:5
        assert(isequal(actual{j}(:)',expected{j}(k,:)),...
            'Research:GoldenMismatch','Golden %s, case %d.',names{j},k);
    end
end
s=zeros(5,1);
% [주3] 연속 이상 1회는 경고, 2회는 25% 제한, 정상 판정은 연속 횟수 초기화입니다.
% 이후 연속 3회 이상으로 래치를 걸고, 정상 판정만으로 풀리지 않는지 확인합니다.
[s,y]=vib3d_supervisor_step(s,1,true,true,true,false,0.5,500);
assert(y(2)==1 && y(3)==0 && y(6)==0.5);
[s,y]=vib3d_supervisor_step(s,1,true,true,true,false,0.5,500);
assert(y(3)==1 && y(6)==0.25);
[s,y]=vib3d_supervisor_step(s,0,true,true,true,false,0.5,500);
assert(y(1)==0 && y(2)==0 && y(6)==0.5);
for k=1:3, [s,y]=vib3d_supervisor_step(s,1,true,true,true,false,0.5,500); end
assert(y(4)==1 && y(5)==1 && y(6)==0);
[s,y]=vib3d_supervisor_step(s,0,true,true,true,false,0.5,500);
assert(y(4)==1 && y(6)==0,'Normal class must not clear a latch.');
[s,y]=vib3d_supervisor_step(s,0,false,true,false,true,0.5,500);
% [주4] 명시적 해제 후에도 누적 이상 횟수는 남아야 합니다.
% watchdog는 499회째까지 유지, 500회째 정지하는 경계를 검사합니다.
% 500샘플이 500 ms가 되는 것은 샘플링 주파수가 1 kHz일 때입니다.
assert(y(4)==0 && y(7)==5,'Clear must retain abnormal lifetime count.');
for k=1:499, [s,y]=vib3d_supervisor_step(s,0,false,false,true,false,0.5,500); end
assert(y(4)==0);
[~,y]=vib3d_supervisor_step(s,0,false,false,true,false,0.5,500);
assert(y(4)==1 && y(5)==2,'Watchdog boundary mismatch.');
report=struct('golden_cases',size(cases,1),'policy_tests_passed',true);
end
