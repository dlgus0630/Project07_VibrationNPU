# 2026-11-15 VHDL 전환 검증

- `validation.json`: 최종 VHDL 소스의 XSim 검사 **10/10 PASS**와 입력 파일 SHA-256.
- `tb_*_console.log`: 각 테스트의 실제 XSim 출력.
- `block_design.log`: VHDL 최상위의 AXI·BRAM 연결 검증, IP 출력 생성과 VHDL system wrapper 생성.
- `synthesis_accelerator.log`, `synthesis_motor.log`: 각각 가속기·모터의 out-of-context 합성 통과.
- `*_ooc_utilization.rpt`: 위 단위 합성의 자원 보고서. 기존 routed utilization과 구분한다.
- `preservation.json`: 기존 RTL·C 펌웨어·데이터 115개 파일, 원본 증거 42개,
  진동 CSV/JSON 12개의 보존 확인.

VHDL 코드의 기능·클록별 출력과 합성 가능성을 확인한 기록이다. 블록 디자인 생성 로그에는
설치된 Zybo 보드 preset에서 나온 DDR skew 경고도 그대로 포함한다.
README의 기존 WNS +0.091 ns, WHS +0.020 ns는 2026-09-17에 저장된 routed 결과로 보존한다.
이 기록의 단위 합성 결과를 기존 타이밍·실측 수치로 대체하지 않는다.
