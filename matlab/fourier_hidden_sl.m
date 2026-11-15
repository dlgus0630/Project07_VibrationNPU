function h=fourier_hidden_sl(u)
% [주1] 특징 4개를 은닉 뉴런 4개로 바꾸는 첫 층입니다. u와 h는 각각 4x1입니다.
% 이 프로젝트의 기본 작업 공간 변수 VIB_MODEL에서 학습된 정수 계수를 읽습니다.
% 상위 통합 프로젝트의 V4_MODEL과 구분하며, RUN_MATLAB_CHECKS가 VIB_MODEL을 준비합니다.
M=evalin('base','VIB_MODEL');
% w1(4x4)*u(4x1)+b1(4x1)은 가중합입니다. bias는 곱셈 누적값과 같은 스케일입니다.
% [주2] /2^shift1 후 floor는 음수에도 산술 우시프트처럼 동작합니다.
% max(0,...)은 ReLU(음수 제거), min(127,...)은 INT8 양수 범위 포화입니다.
% 반환값은 확률이나 물리량이 아니라 다음 층에 전달할 양자화 정수 코드입니다.
h=max(0,min(127,floor((double(M.w1)*u(:)+M.b1(:))/2^M.shift1)));
end
