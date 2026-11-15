function f=fourier_features_sl(u)
% [주1] 입력 u는 FFT 실수부 64개와 허수부 64개를 세로로 붙인 128x1 벡터입니다.
% 출력 f는 NPU로 전달할 4x1 정수 특징이며 각 값은 0~127입니다.
% 아래 숫자는 Hz가 아닌 FFT bin 번호입니다. 실제 Hz는 bin*샘플링주파수/64입니다.
% DC bin 0과 Nyquist bin 32를 제외한 네 대역을 각각 요약합니다.
bands=[1 6;7 12;13 20;21 31]; f=zeros(4,1);
for j=1:4
    % MATLAB은 1부터 인덱싱하므로 bin 번호에 1을 더합니다. 허수부 위치는 다시 +64입니다.
    idx=(bands(j,1):bands(j,2))+1;
    % [주2] abs(Re)+abs(Im)의 합입니다. 전력(제곱합) 또는 복소수 절댓값과는 다릅니다.
    % /32 후 floor로 5비트 우시프트를 재현하고 127에서 포화시킵니다.
    f(j)=min(127,floor(sum(abs(u(idx))+abs(u(idx+64)))/32));
end
end
