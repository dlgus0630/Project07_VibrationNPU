function result = vib3d_classify(result,p,M)
% [읽기 안내] 합성 센서값에 기존 FPGA와 같은 FFT→특징→INT8 NPU를 적용합니다.
% 입력 result.raw는 N×3 int16 카운트, p는 시간 설정, M은 학습된 가중치입니다.
% 출력 result에 프레임별 features(4열), hidden(4열), logits(2열), classes를 붙입니다.
% [주1] 3축을 시뮬레이션해도 기존 NPU 입력은 X축만 사용합니다.
% 연구용 Hann PSD와 달리 NPU는 창을 곱하지 않은 64샘플 정수 FFT 규격입니다.
% Preserve the deployed X-only, rectangular 64-sample integer feature contract.
n=size(result.raw,1); frame_count=floor(n/64);
result.frame_index=(64:64:64*frame_count)';
% [주2] 첫 샘플이 t=0이고 fs=1000이면 64번째 샘플은 63 ms입니다.
% 따라서 첫 판정은 63 ms, 그 뒤 판정 주기는 64 ms이며 남는 샘플은 버립니다.
result.frame_time=result.t(result.frame_index);
result.features=zeros(frame_count,4); result.hidden=zeros(frame_count,4);
result.logits=zeros(frame_count,2); result.classes=zeros(frame_count,1);
result.fft_error_lsb=zeros(frame_count,1);
result.frame_valid=false(n,1); result.class_stream=zeros(n,1);
for k=1:frame_count
    % 프레임이 완성된 시점에만 계산하고, 다음 프레임까지 판정을 유지합니다.
    % valid는 새 판정이 생긴 순간만 참이므로 같은 결과를 매 ms 중복 집계하지 않습니다.
    idx=(k-1)*64+(1:64); x=double(result.raw(idx,1));
    [re,im,f]=fft64_fixed(x); [h,o,cls]=npu_int8(f,M);
    result.features(k,:)=f'; result.hidden(k,:)=h';
    result.logits(k,:)=o'; result.classes(k)=cls;
    result.fft_error_lsb(k)=max(abs(complex(re,im)-fft(x)/64));
    % [주3] 부동소수점 FFT/64와의 차이는 고정소수점 반올림·절삭 오차를 보는
    % 참고 지표입니다. NPU 진단 정확도나 실제 고장 확률을 뜻하지 않습니다.
    first=idx(end); last=min(n,first+63);
    result.frame_valid(first)=true; result.class_stream(first:last)=cls;
end
result.heartbeat=mod((0:n-1)',round(0.1*p.fs))==0;
% [주4] 100 ms 주기 heartbeat를 가정해 안전 정책을 관찰합니다.
% 출력 제한값을 계산할 뿐 외력이나 회전자 속도로 되돌려 보내지 않으므로
% 이 연구 모델은 안전 정지의 실제 기계 응답을 검증하는 폐루프가 아닙니다.
result.safety=zeros(n,7); state=zeros(5,1);
for k=1:n
    [state,y]=vib3d_supervisor_step(state,result.class_stream(k),...
        result.frame_valid(k),result.heartbeat(k),true,false,0.5,round(0.5*p.fs));
    result.safety(k,:)=y';
end
% These predictions probe domain shift; synthetic scenario names are not labels
% for the real-data classifier and must not be used to compute an accuracy.
result.classification_note='X-only trained classifier on illustrative synthetic mechanics; no accuracy claim.';
% [주5] 합성 고장 시나리오와 실제 학습 데이터의 분포는 다를 수 있습니다.
% 시나리오 이름을 정답으로 간주해 이 결과에서 실측 진단 정확도를 계산하지 않습니다.
end
