# 2026-11-15 VHDL 모듈·프로세스 구조 검증

최상위 연결을 `*_struct.vhd`에 두고 상태·데이터·카운터의 기록 책임을 나눈 코드의 검증 기록이다.
설계 소스는 패키지 2개와 entity 20개이며, 이름 있는 프로세스는 TB를 제외하고 74개다.

| 파일 | 내용 |
|---|---|
| `validation.json` | XSim **13/13 PASS**, 실행 시각, 소스·기준 입력 SHA-256 |
| `tb_*_console.log` | 각 시험의 실제 XSim 출력 |
| `xvhdl.log`, `xvlog.log` | VHDL 설계/TB와 비교용 Verilog 컴파일 |
| `block_design.log` | AXI·BRAM 연결 검증, IP 출력과 VHDL wrapper 생성 |
| `synthesis_accelerator.log`, `synthesis_motor.log` | 가속기·모터의 out-of-context 합성 |
| `*_ooc_utilization.rpt` | 위 단위 합성의 자원 보고서 |
| `preservation.json` | 원본 115개 파일, 기존 증거 42개와 진동 CSV/JSON 12개의 보존 확인 |

기존 기준값과의 비교에 더해 코어 20개 입력, PI 2,000회 입력, 모터의 외부 출력과 telemetry를
Verilog/VHDL 동시 실행으로 클록마다 비교한다. 추가한 VHDL 단독 TB는 리셋, MAC,
FFT/NPU를 COMPONENT/binding과 TC별 ASSERT로 확인한다.

블록 디자인 로그의 DDR skew 경고는 설치된 Zybo 보드 preset의 값이며 로그에 그대로 보관한다.
README의 WNS +0.091 ns와 WHS +0.020 ns는 기존 2026-09-17 routed 보고서값이다.
이 폴더에는 구조 정리 후 시뮬레이션·단위 합성·블록 디자인 생성 결과를 보관한다.
처음 언어를 전환한 기록은 [별도 폴더](../vhdl_2026-11-15/)에 보존한다.
