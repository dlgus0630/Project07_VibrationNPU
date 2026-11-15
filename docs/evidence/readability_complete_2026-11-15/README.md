# 실행 코드·검증 코드 가독성 정리 기록

현재 사용 중인 C 앱과 VHDL 회로, HDL TB를 같은 기준으로 정리한 결과다.

| 대상 | 정리한 구조 |
|---|---|
| C 앱 | `main.c`의 초기화/명령 분기와 플랫폼·센서·추론·텔레메트리·모터 기능 모듈 |
| PC 검사기 | 파일 열기, 입력 읽기, 정수 값 해석, 결과 비교와 종료 함수 |
| VHDL | FFT 주소/복소 곱/포화, NPU 입력/weight/양자화, 인코더 속도/위상, PWM 환산/출력을 역할별 조합 프로세스로 분리 |
| SV TB | 이름 기반 포트, 이름 있는 클럭/주변장치/판정 블록, TC 자극, 신호별 비교 |

VHDL은 패키지 2개, entity 20개와 이름 있는 프로세스 88개다.
기존 FSM의 상태·데이터 저장 클럭은 유지했다.

| 검증 자료 | 내용 |
|---|---|
| `validation.json`, `tb_*_console.log` | 현재 HDL 소스의 XSim **13/13 PASS**와 소스 지문 |
| `firmware_equivalence.json` | 원본/수정 C 앱의 **20개** 명령 시나리오, PC 검사기의 **8개** 성공/오류 경우, 결과 구조체 배치 비교, Cortex-A9 **7개 파일 컴파일 및 링크** |
| `golden_equivalence.json` | 실측 360개를 포함한 **10,651개** 시험 입력에서 각 **139개** 중간값/결과 비교 |
| `preservation.json` | 원본 파일 111개, 기존 증거 42개, 실측 CSV/JSON 12개 보존과 변경한 C 파일 4개의 별도 검증 |
| `synthesis_motor.log`, `synthesis_accelerator.log` | 모터/가속기 out-of-context 합성 |
| `*_ooc_utilization.rpt` | 위 단위 합성의 자원 보고서 |
| `block_design.log` | 새 작업 폴더의 Vivado 블록 디자인 검증/출력 생성 |
| `vitis_build.log`, `vitis_sync.json` | 실제 Vitis 앱 소스/7개 빌드 목록 반영과 앱 빌드 |
| `before/`, `before_sha256.json` | 정리 전 C·VHDL·TB 소스와 지문 |

펌웨어 비교는 동일한 가상 BSP 응답을 두 실제 C 앱에 제공한다.
MMIO 읽기/쓰기 순서와 값, UART의 16바이트 프레임, 문자열, 오류 반환 경로를 비교한다.
가상 시간 값은 소프트웨어 시험용이다. 결과 구조체는 크기 268바이트와 모든 필드 위치가 같다.

기존 실측 CSV·계측 사진·저장된 ELF/bitstream·MATLAB 배열·routed 보고서는 보존한다.
README의 WNS/WHS는 기존 routed 보고서의 값이며 이 단위 합성 기록으로 대체하지 않는다.
설치된 Zybo 보드 preset의 DDR skew 경고는 블록 디자인 로그에 그대로 포함한다.

코드 위치: [C 모듈](../../../fourier/firmware/README.md),
[VHDL 모듈/프로세스](../../../fourier/vhdl/README.md),
[TB/TC](../../../fourier/tb_vhdl/README.md).
