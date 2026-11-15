function o=fourier_logits_sl(u)
% [주1] 은닉값 u(4x1)를 두 클래스의 비교 점수 o(2x1)로 바꾸는 출력 층입니다.
% 이 프로젝트의 VIB_MODEL을 읽습니다. 상위 통합 프로젝트의 V4_MODEL과 구분합니다.
M=evalin('base','VIB_MODEL');
% w2(2x4)*u+b2 뒤 /2^shift2와 floor로 정수 출력 스케일에 맞춥니다.
% 음수 floor는 0 방향 버림이 아닙니다. FPGA의 부호 있는 우시프트를 맞추기 위해 필요합니다.
% [주2] 출력 점수에는 ReLU를 적용하지 않아 음수를 유지하고 -128~127에서 포화합니다.
% o는 softmax 확률이 아닙니다. 이 함수는 점수만 반환하고 클래스 선택은 하지 않습니다.
o=max(-128,min(127,floor((double(M.w2)*u(:)+M.b2(:))/2^M.shift2)));
end
