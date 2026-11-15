function spectrum = vib3d_spectral(x,fs,segment_length,overlap_fraction)
% [읽기 안내] 신호를 짧은 구간으로 나누어 주파수별 세기와 시간 변화를 봅니다.
% 입력 x는 N×채널수, fs는 샘플링 주파수(Hz), segment_length는 구간 샘플 수,
% overlap_fraction은 구간 중첩 비율입니다. 각 열은 하나의 센서 축입니다.
% 출력 psd는 주파수×채널, stft_psd는 주파수×시간구간×채널 배열입니다.
% x가 가속도(m/s^2)이면 PSD 단위는 (m/s^2)^2/Hz이며 진폭 자체가 아닙니다.
%VIB3D_SPECTRAL One-sided, Hann-window Welch PSD/STFT without toolboxes.
% Columns are channels. Each segment has its own mean removed. PSD is
% |FFT(w*x)|^2/(fs*sum(w.^2)), doubled except DC and even-length Nyquist.
% Integrating PSD over frequency yields mean-square windowed acceleration.
% Overlapping segments are correlated; no confidence intervals are claimed.
x=double(x); if isvector(x), x=x(:); end
assert(size(x,1)>=8 && all(isfinite(x(:))) && fs>0);
L=min(floor(segment_length),size(x,1));
assert(L>=8 && overlap_fraction>=0 && overlap_fraction<1);
hop=max(1,round(L*(1-overlap_fraction)));
% [주1] hop은 다음 창으로 이동할 샘플 수입니다. 중첩을 늘리면 시간축이
% 촘촘해지지만 이웃 구간은 독립 표본이 아니므로 정보량이 같은 비율로 늘지 않습니다.
starts=1:hop:(size(x,1)-L+1);
w=0.5-0.5*cos(2*pi*(0:L-1)'/L); % Periodic Hann, explicit convention.
% Hann 창은 구간 양 끝을 부드럽게 줄여 주파수 누설을 완화합니다.
% 각 창의 평균도 빼서 큰 DC 성분이 진동 해석을 가리지 않게 합니다.
nfrequency=floor(L/2)+1;
S=zeros(nfrequency,numel(starts),size(x,2));
for j=1:numel(starts)
    segment=x(starts(j)+(0:L-1),:);
    segment=bsxfun(@minus,segment,mean(segment,1));
    F=fft(bsxfun(@times,segment,w),L,1);
    P=abs(F(1:nfrequency,:)).^2/(fs*sum(w.^2));
    % [주2] fs*sum(w.^2)로 나누어 샘플링 주파수와 창의 에너지를 보정합니다.
    % 양수 주파수만 남겼으므로 짝인 음수 주파수의 전력을 2배로 합칩니다.
    % DC와 짝수 길이의 Nyquist 성분은 짝이 없어서 2배로 만들지 않습니다.
    if mod(L,2)==0, P(2:end-1,:)=2*P(2:end-1,:);
    else, P(2:end,:)=2*P(2:end,:); end
    S(:,j,:)=reshape(P,[nfrequency 1 size(x,2)]);
end
spectrum.frequency=(0:nfrequency-1)'*fs/L;
% [주3] 창별 PSD를 평균한 것이 Welch PSD, 창별로 남긴 것이 STFT 전력 지도입니다.
% sum(psd)*df는 창 가중 평균제곱에 대응하며, sqrt로 RMS 크기를 해석합니다.
% PSD 봉우리 하나의 높이를 정현파 진폭으로 바로 읽으면 안 됩니다.
spectrum.psd=reshape(mean(S,2),nfrequency,size(x,2));
spectrum.stft_psd=S;
spectrum.time=((starts-1)+(L-1)/2)'/fs;
spectrum.df=fs/L;
spectrum.enbw_hz=fs*sum(w.^2)/sum(w)^2;
% [주4] df=fs/L은 주파수 칸 간격입니다. ENBW는 창이 잡음을 받아들이는
% 유효 대역폭으로, 여기의 주기적 Hann 창은 1.5*df입니다.
spectrum.segment_length=L;
spectrum.hop=hop;
spectrum.segments=numel(starts);
end
