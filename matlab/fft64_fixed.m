function [re,im,feat] = fft64_fixed(x)
% [주1] FPGA와 같은 정수 반올림/포화를 재현하는 64점 FFT 기준 함수입니다.
% 입력 x: INT16 범위의 정수 64개. 출력 re/im: 각 64x1, feat: 4x1입니다.
% 단위는 입력 정수 코드 기준이며, 이 함수가 가속도나 전압으로 환산하지는 않습니다.
% Handwritten arithmetic Golden; doubles represent every integer exactly here.
% double 자료형으로 계산하지만 각 단계에서 정수화를 적용해 하드웨어 산술을 맞춥니다.
assert(numel(x)==64); x=double(x(:)); re=zeros(64,1); im=re;
% [주2] 입력 위치 0~63을 6비트로 보고 비트 순서를 뒤집어 배치합니다.
% 예: 1=000001 -> 100000=32. 이 순서로 시작하면 FFT 결과는 주파수 순서가 됩니다.
for n=0:63
    a=n; r=0;
    for b=1:6, r=2*r+mod(a,2); a=floor(a/2); end
    re(n+1)=x(r+1);
end
% 회전 인자 exp(-j*2*pi*k/64)를 Q1.15 정수로 표현합니다. 32768이 수학적 1입니다.
% 다만 INT16 최댓값은 32767이므로 +1만 32767로 포화됩니다.
twre=max(-32768,min(32767,round(32768*cos(-2*pi*(0:31)/64))));
twim=max(-32768,min(32767,round(32768*sin(-2*pi*(0:31)/64))));
% [주3] 2개씩 묶는 radix-2 버터플라이를 6단계 수행합니다(2^6=64).
for stage=1:6
    span=2^stage; half=span/2;
    for base=0:span:63
        for j=0:half-1
            a=base+j+1; b=a+half; t=j*64/span+1;
            % 복소수 곱셈 뒤 /32768로 Q1.15의 소수 비트 15개를 제거합니다.
            % floor는 음수도 -무한대 방향입니다. 예: floor(-3/2)=-2로 산술 우시프트와 같습니다.
            tr=floor((re(b)*twre(t)-im(b)*twim(t))/32768);
            ti=floor((re(b)*twim(t)+im(b)*twre(t))/32768);
            ar=re(a); ai=im(a);
            % 합과 차를 각각 2로 나누고 INT16 범위로 포화시켜 오버플로를 막습니다.
            % 6번의 /2 때문에 전체 크기는 FFT/64에 대응하며 정수화 오차가 포함됩니다.
            re(a)=max(-32768,min(32767,floor((ar+tr)/2)));
            im(a)=max(-32768,min(32767,floor((ai+ti)/2)));
            re(b)=max(-32768,min(32767,floor((ar-tr)/2)));
            im(b)=max(-32768,min(32767,floor((ai-ti)/2)));
        end
    end
end
% [주4] MATLAB 인덱스 k+1이 FFT 주파수 bin k입니다. DC(k=0), Nyquist(k=32)는 제외합니다.
bands=[1 6;7 12;13 20;21 31]; feat=zeros(4,1);
for j=1:4
    idx=(bands(j,1):bands(j,2))+1;
    % abs(Re)+abs(Im)을 대역별로 합칩니다. 제곱합 전력이나 sqrt(Re^2+Im^2)가 아닙니다.
    % /32 후 버림은 5비트 우시프트, min(127,...)은 NPU 입력 범위 0~127 포화입니다.
    feat(j)=min(127,floor(sum(abs(re(idx))+abs(im(idx)))/32));
end
end
