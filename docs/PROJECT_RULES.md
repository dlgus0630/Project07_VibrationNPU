# 프로젝트 원칙

1. 범위는 학부 수준, 중간 난이도로 유지하고 설명 가능한 완성도를 기능 수보다 우선한다.
2. 개발 순서는 PC 학습, MATLAB Golden, Simulink, Verilog simulation, synthesis,
   implementation, 보드 검증 순서로 유지한다.
3. Behavioral simulation이 실패한 상태에서는 synthesis로 넘어가지 않는다.
4. FPGA에서는 training을 수행하지 않고 inference만 구현한다.
5. 모델은 `4 -> 4 ReLU -> 2` 소형 MLP와 INT8 정수 연산을 유지한다.
6. NPU의 MAC, PE, accumulator, activation, requantization, controller는 직접 작성한 RTL이다.
7. ARM은 센서와 제어를 담당하고 PL은 FFT와 NPU 가속을 담당한다.
8. AXI와 BRAM은 PS-PL 연결에 사용하며 DMA와 cache coherence는 범위에 넣지 않는다.
9. 직접 작성하는 HDL은 Verilog-2001 `.v`만 사용한다. SystemVerilog 문법과 HDL Coder는 사용하지 않는다.
10. bit width, signedness, saturation, truncation, shift를 변경하기 전에 `DESIGN.md`를 갱신한다.
11. MATLAB 중간값, C 기준 모델, RTL testbench 결과를 자동 비교한다.
12. 실제로 실행하거나 측정하지 않은 결과를 PASS 또는 실측값으로 기록하지 않는다.
13. 합성 데이터 정확도를 실제 설비 고장 진단 정확도로 표현하지 않는다.
14. 실측 학습 데이터는 인접 window가 아니라 독립 acquisition run 기준으로 train/validation을 나눈다.
15. 커밋 작성자는 `dlgus0630` 한 명으로 유지하고 공동 작성자 메타데이터를 추가하지 않는다.
