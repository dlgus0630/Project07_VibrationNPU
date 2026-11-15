# PI 계산식 정리 후 검증

`pid_controller_fsm.vhd`의 P항·적분 증가량·적분 합·측정값 필터·anti-windup 선택을
5개 조합 프로세스로 나눴다. 중간 계산은 의미 있는 이름의 변수로 풀어 썼으며,
기존 클럭 프로세스 10개와 FSM 상태 순서를 유지한다.
적분 합의 하위 워드·carry 레지스터와 상위 워드 결합도 기존 두 클럭 계산을 유지한다.

| 파일 | 확인 내용 |
|---|---|
| `validation.json` | 현재 소스의 SHA-256과 XSim **13/13 PASS** |
| `tb_*_console.log` | 각 시험의 실제 출력 |
| `xvhdl.log`, `xvlog.log` | 설계·TB·비교용 원본의 컴파일 결과 |
| `synthesis_motor.log` | 변경된 PI를 포함한 모터 out-of-context 합성 통과 |
| `motor_ooc_utilization.rpt` | 위 단위 합성의 자원 보고서 |
| `preservation.json` | 원본 115개 파일, 기존 증거 42개, 진동 CSV/JSON 12개 보존 확인 |

PI 2,000회 입력의 duty·적분·필터 출력·busy/done을 원본 Verilog와 클록마다 비교했고,
모터 통합 시험에서도 출력과 telemetry가 일치했다.
기존 실측 자료와 routed 보고서는 보존한다.

코드의 계산/저장 구분은 [PI 프로세스 안내](../../../fourier/vhdl/README.md#pi-계산과-저장)를 참고한다.
