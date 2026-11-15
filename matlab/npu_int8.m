function [hidden,logits,cls] = npu_int8(feat,M)
% [주1] 4입력 -> 4은닉 -> 2출력인 정수 신경망을 한 번 계산합니다. 학습 함수는 아닙니다.
% feat: 0~127 정수 4개, M: 이미 학습된 가중치/편향/shift를 담은 구조체입니다.
% 출력 hidden: 4x1, logits: 2x1, cls: 스칼라 0 또는 1입니다.
% 가중치는 INT8 코드, 편향은 해당 층의 곱셈 누적값과 같은 스케일입니다.
a=double(M.w1)*double(feat(:))+double(M.b1(:));
% [주2] floor(a/2^shift)는 산술 우시프트를 재현합니다. 음수도 아래 정수로 내려갑니다.
% 첫 층은 ReLU로 음수를 0으로 만들고, 127보다 큰 값은 포화시킵니다.
hidden=max(0,min(127,floor(a/2^M.shift1)));
b=double(M.w2)*hidden+double(M.b2(:));
% 두 번째 층은 음수 점수도 필요하므로 ReLU 없이 INT8 전체 범위 -128~127을 씁니다.
% logits는 비교용 양자화 점수이며 확률이 아닙니다.
logits=max(-128,min(127,floor(b/2^M.shift2)));
% [주3] MATLAB의 logits(1)이 클래스 0, logits(2)가 클래스 1의 점수입니다.
% 두 번째 점수가 엄격히 클 때만 클래스 1입니다. 동점이면 클래스 0을 선택합니다.
cls=double(logits(2)>logits(1));
end
