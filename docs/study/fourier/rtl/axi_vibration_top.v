// ============================================================================
// [공부용 주석 사본] fourier/rtl/axi_vibration_top.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "ARM(PS, Cortex-A9)이 AXI4-Lite 버스를 통해
// 이 프로젝트의 모든 것(진동 분류 가속기 vibration_core, SPI 센서 엔진
// mpu_reg_spi, 모터 제어 fourier_motor_control)을 제어하고 상태를 읽어갈 수
// 있게 해주는 '레지스터 인터페이스' — 즉 소프트웨어와 하드웨어 사이의 대화
// 창구"
//
// AXI4-Lite가 왜 이렇게 생겼는가 (배경지식)
// -----------------------------------------------------------------------
// ARM 코어는 "메모리 주소에 값을 쓰거나 읽는다"는 동작 하나로 모든 주변장치를
// 제어합니다(memory-mapped I/O). 예를 들어 소프트웨어가 `Xil_Out32(0x43c00048,1)`
// 이라고 쓰면, 그 요청이 AXI 버스를 타고 이 모듈까지 전달되어 "0x048번지에
// 1을 써라"가 됩니다. AXI4-Lite는 이런 요청을 주고받는 표준 규약인데, 특이한
// 점은 "쓰기"와 "읽기"가 완전히 별개의 채널 5개로 나뉘어 있다는 것입니다:
//   - AW(Write Address) 채널: "이 주소에 쓰고 싶다"
//   - W (Write Data)    채널: "이 데이터를 쓰고 싶다"
//   - B (Write Response) 채널: "쓰기 완료됐다/실패했다"
//   - AR(Read Address)  채널: "이 주소를 읽고 싶다"
//   - R (Read Data)     채널: "이 데이터가 읽힌 값이다"
// 왜 주소와 데이터를 쓰기에서조차 따로 나눴을까요? AXI는 여러 개의 요청이
// 동시에 파이프라인처럼 겹쳐서 진행될 수 있도록(고성능을 위해) 설계된
// 버스이기 때문입니다 — 하지만 이 프로젝트처럼 단순한 레지스터 슬레이브는
// 그런 고성능 기능을 다 쓸 필요가 없어서 "AXI4-Lite"라는 단순화된 버전을
// 씁니다(그래도 채널이 5개로 나뉜 기본 구조는 그대로 유지됩니다).
//
// "핸드셰이크(handshake)"란?
// -----------------------------------------------------------------------
// 각 채널마다 VALID(보내는 쪽이 "데이터 준비됐다"는 신호)와 READY(받는 쪽이
// "받을 준비됐다"는 신호) 한 쌍이 있습니다. 두 신호가 동시에 1인 그 클럭에만
// 실제로 데이터가 전달된 것으로 간주합니다(VALID만 1이고 READY가 0이면 보내는
// 쪽이 계속 기다려야 함). 이 모듈에서 `s_axi_awready`, `s_axi_wvalid` 같은
// 이름들이 전부 이 규약을 따릅니다. 이 프로젝트는 슬레이브(Slave, 요청을
// 받는 쪽)이므로 s_axi_* 접두어를 씁니다(마스터인 ARM 쪽은 m_axi_* 였을 것).
//
// 전체 레지스터 맵 (이 파일을 이해하는 데 가장 중요한 표)
// -----------------------------------------------------------------------
// 아래 always 블록의 case(addr_hold)/case(s_axi_araddr)에서 실제로 어떤
// 주소가 무엇을 의미하는지 한눈에 정리했습니다. R=읽기전용, W=쓰기전용,
// RW=읽기/쓰기 둘 다.
//
//   주소     R/W  의미
//   -------  ---  --------------------------------------------------------
//   0x000    W    제어: bit0=1 쓰면 start_pulse(진동 분류 시작), bit1=1 쓰면
//                 sticky_done/sticky_error 클리어. busy 중에 bit0을 쓰면
//                 에러 응답(bresp=2)으로 거부됨(이미 도는데 또 시작 못 함).
//   0x004    R    상태 비트 묶음: {watchdog_fault,derated,warning,fault_latched,
//                 sticky_error,sticky_done,visible_busy}
//   0x008    R    class_id(마지막 분류 결과: 0=정상,1=이상)
//   0x00c    R    cycles(vibration_core가 이번 추론에 걸린 클럭수, 성능측정용)
//   0x010    R    ncycles(그 중 NPU 파트만 걸린 클럭수)
//   0x020~   R    feat[7:0]~feat[31:24] — FFT 특징 4개를 바이트 단위로 4번에
//   0x02c         나눠 읽음(레지스터가 32비트 폭이라 4바이트 특징을 한 번에
//                 하나씩 읽게 설계됨)
//   0x030    R    logits[7:0] (부호확장된 32비트로 반환)
//   0x034    R    logits[15:8] (부호확장)
//   0x040    W    SPI 트랜잭션 시작: bit31=1(트리거), bit8=two-byte 모드,
//                 bit7=read/write, bit6:0=레지스터 주소, bit23:16=쓸 데이터
//   0x044    R    SPI 상태/결과: {spi_done_sticky, spi_busy|spi_start, 결과값}
//   0x048    W    ps_heartbeat 펄스(bit0=1 쓰면 그 클럭만 1) — safety_supervisor의
//                 watchdog을 먹여살리는 "나 아직 살아있다" 신호
//   0x04c    R    안전 세부정보: {abnormal_count, fault_cause, derated, warning,
//                 fault_consec}
//   0x050    R    motor_speed_reference (목표 속도)
//   0x054    R    motor_measured_speed (실측 속도)
//   0x058    R    motor_requested_duty (실제 나간 PWM duty)
//   0x05c    R    motor_pid_integral (PI 적분 누적값, signed)
//   0x060    R    motor_armed_status (모터가 무장/구동 상태인지)
//   0x064    R    motor_watchdog_count (워치독 관련 카운트)
//   0x068    RW   ctrl2: bit0=open_loop_enable, bit1=anti_windup_enable
//   0x06c    RW   open_loop_duty (13비트, 시스템 식별용 강제 duty)
//   0x070    RW   kp_gain (Q16 고정소수점, signed 18비트)
//   0x074    RW   ki_gain (Q16*Ts 고정소수점, signed 18비트)
//   0x078    R    쿼드러처 상태: {overflow_fault,timeout_fault,illegal_fault,direction}
//   0x07c    RW   quad_position (32비트 signed 위치 카운터 — 쓰면 프리셋됨, 아래 설명)
//   0x080    R    quad_illegal_count (비정상 쿼드러처 신호 카운트)
//   그 외     -    존재하지 않는 주소: 쓰기는 bresp=2(에러), 읽기는 rdata=0,rresp=2
//
// AW/W를 따로 latch하는 이유 ("Separate AW/W latches tolerate either arrival order")
// -----------------------------------------------------------------------
// AXI 프로토콜은 "AW(주소)와 W(데이터)가 반드시 같은 클럭에 함께 와야 한다"고
// 보장하지 않습니다 — 마스터(ARM 쪽 AXI 인터커넥트) 구현에 따라 주소가 먼저
// 올 수도, 데이터가 먼저 올 수도, 둘이 동시에 올 수도 있습니다. 이 모듈은
// 이걸 다 받아낼 수 있도록 aw_hold/w_hold라는 별도의 "도착 여부 기억 플래그"를
// 둡니다: AW가 오면(핸드셰이크 성립하면) 즉시 addr_hold에 주소를 저장하고
// aw_hold<=1, W가 오면 data_hold/strb_hold에 저장하고 w_hold<=1. 그리고 실제
// 레지스터 쓰기 동작(case(addr_hold) ...)은 "aw_hold && w_hold가 둘 다 1이
// 되는 순간"에만 실행됩니다 — 즉 어느 쪽이 먼저 왔든 상관없이, 둘 다 도착한
// 게 확인된 다음에야 실제 쓰기를 수행합니다. 이렇게 하면 "AW가 먼저 오고 한
// 클럭 뒤에 W가 오는" 마스터와도, "W가 먼저 오고 AW가 나중에 오는" 마스터와도
// 모두 올바르게 동작합니다. aw_hold/w_hold는 쓰기가 실제로 처리되고 나면(위
// case문이 실행된 직후) 0으로 다시 클리어되어 다음 트랜잭션을 받을 준비를 함.
//
// "쓰면 한 클럭만 1이 되는 펄스" 레지스터 패턴 (ps_heartbeat, start_pulse 등)
// -----------------------------------------------------------------------
// always 블록 맨 위에서 `start_pulse<=0;spi_start<=0;ps_heartbeat<=0;
// quad_position_wr_en<=0;` 처럼 관련 신호들을 매 클럭 일단 전부 0으로
// 깔아놓고 시작합니다. 그 다음 아래쪽 조건문에서 "지금 이 주소에 이 값이
// 쓰였다"는 조건이 맞으면 그제서야 해당 신호를 1로 override합니다. 그 결과
// 이 신호들은 "쓰기가 일어난 바로 그 한 클럭에만 1이고, 다음 클럭엔 자동으로
// 다시 0"이 되는 원샷 펄스가 됩니다. 왜 이렇게 설계했을까요? start_pulse나
// ps_heartbeat 같은 신호는 "그 순간에 한 번 트리거되는 이벤트"를 의미하지,
// "계속 켜져 있는 상태"를 의미하지 않기 때문입니다(레벨이 아니라 엣지가
// 중요). 만약 이걸 그냥 레벨 레지스터로 만들었다면(한번 쓰면 계속 1로
// 남아있게), vibration_core는 "start가 계속 1이니 계속 재시작해야 하나?"
// 같은 모호한 상황에 빠집니다. "매번 0으로 리셋 후 조건부로 1 override"
// 패턴은 이 문제를 깔끔하게 해결하는 표준적인 방법입니다.
//
// quad_position_wr_en / quad_position_wr_value (0x07c, 오늘 추가된 기능)
// -----------------------------------------------------------------------
// 원래 0x07c는 읽기 전용(쿼드러처 위치를 관찰만 함)이었는데, 이번에
// 읽기/쓰기(RW)로 확장되었습니다. 목적은 "오버플로우(overflow) 실물 테스트"
// 입니다 — quad_position은 32비트 signed 카운터라서 이론적으로는 실제
// 엔코더 펄스를 수십억 번 넣어야 +-2^31 경계에 도달해 오버플로우를 재현할 수
// 있는데, 그건 현실적으로 너무 오래 걸립니다. 그래서 0x07c에 값을 쓰면
// quad_position_wr_en이 한 클럭 펄스로 서서(위 패턴과 동일), encoder_quadrature.v가
// 그 값(quad_position_wr_value)을 내부 카운터에 즉시 프리셋할 수 있게
// 됩니다 — 예를 들어 경계 바로 1칸 앞(0x7ffffffe)으로 미리 세팅해두면, 실제
// 엔코더를 손으로 두 번만 돌려도 오버플로우 상황을 즉시 재현해서 안전장치가
// 제대로 걸리는지 실물로 확인할 수 있습니다(펌웨어의 'o' 명령이 이 레지스터를
// 씀 — main.c study 사본 참고).
// ============================================================================

// AXI4-Lite control peripheral. Separate AW/W latches tolerate either arrival order.
module axi_vibration_top #(
    parameter integer CLK_HZ=100000000
)(
    // 아래 (* X_INTERFACE_INFO=... *) 속성들은 Vivado IP Integrator가 이
    // 모듈을 "AXI4-Lite 슬레이브 IP"로 자동 인식해서 블록 디자인에서 배선을
    // 자동으로 이어주기 위한 메타데이터입니다. 회로 동작 자체와는 무관하고,
    // 툴에게 "이 포트가 AXI의 어떤 신호에 해당하는지"를 알려주는 태그입니다.
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 ACLK CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI:M_BRAM, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input wire aclk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 ARESETN RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
    input wire aresetn, // active-low: 0일 때 리셋 상태(즉 !aresetn이 "리셋 걸림")
    // ---- AW(Write Address) 채널: "이 주소(awaddr)에 쓰고 싶다"는 요청 ----
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR", X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    input wire [11:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *) input wire [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    // ---- W(Write Data) 채널: "이 데이터(wdata)를 쓰고 싶다"는 요청 ----
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb, // 바이트 단위로 어느 바이트를 실제로 쓸지(strobe)
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    // ---- B(Write Response) 채널: "쓰기 끝났다"는 응답 ----
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output reg [1:0] s_axi_bresp, // 0=성공(OKAY), 2=에러(SLVERR)
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output reg s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    // ---- AR(Read Address) 채널: "이 주소(araddr)를 읽고 싶다"는 요청 ----
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [11:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    // ---- R(Read Data) 채널: "이 데이터(rdata)가 읽힌 값이다" 응답 ----
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output reg [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output reg s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
    // ---- M_BRAM: 이 모듈이 반대로 "마스터"가 되어 BRAM 컨트롤러를 직접
    // 제어하는 인터페이스(64샘플 입력 + 결과 저장용 메모리). vibration_core가
    // 실제 주소/데이터를 만들어내고 이 포트들은 그걸 그대로 밖으로 내보냄.
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM CLK", X_INTERFACE_MODE="MASTER", X_INTERFACE_PARAMETER="MEM_SIZE 4096, MEM_WIDTH 32, MASTER_TYPE BRAM_CTRL" *) output wire m_bram_clk,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM RST" *) output wire m_bram_rst,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM EN" *) output wire m_bram_en,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM WE" *) output wire [3:0] m_bram_we,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM ADDR" *) output wire [31:0] m_bram_addr,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM DIN" *) output wire [31:0] m_bram_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM DOUT" *) input wire [31:0] m_bram_rdata,
    output wire mpu_sclk,output wire mpu_mosi,input wire mpu_miso,output wire mpu_cs_n, // SPI 센서 물리 핀
    output wire irq, // 진동 분류 완료 시 ARM에 인터럽트를 걸기 위한 선(sticky_done과 연결됨)
    // Classification stream out to the motor guard, latched-fault state back in.
    // (한국어) 이 두 신호는 AXI와 무관하게, 이 칩 안에서 axi_vibration_top이
    // fourier_motor_control과 직접 배선되는 부분입니다 — "방금 분류 결과가
    // 나왔다(class_valid)"와 "그 결과가 이상(class_id=1)인지"를 모터
    // 안전장치 쪽으로 바로 흘려보냄(ARM 소프트웨어를 거치지 않는 하드웨어
    // 직결 안전경로).
    output wire class_valid,output wire class_id,
    input wire motor_fault_latched,input wire motor_warning,input wire motor_derated,
    input wire motor_watchdog_fault,input wire [1:0] motor_fault_cause,
    input wire [7:0] motor_fault_consec,input wire [15:0] motor_abnormal_count,
    output reg ps_heartbeat,
    // Closed-loop speed telemetry, streamed on to the host by the Cortex-A9 application.
    input wire [12:0] motor_speed_reference,
    input wire [12:0] motor_measured_speed,
    input wire [12:0] motor_requested_duty,
    input wire signed [31:0] motor_pid_integral,
    input wire motor_armed_status,
    input wire [31:0] motor_watchdog_count,
    // Runtime PI tuning / open-loop override for system identification (0x068,
    // 0x06c, 0x070, 0x074). Reset defaults reproduce the original fixed tuning
    // exactly, so leaving these unwritten is behaviorally identical to before.
    output reg open_loop_enable,output reg anti_windup_enable,
    output reg [12:0] open_loop_duty,
    output reg signed [17:0] kp_gain,output reg signed [17:0] ki_gain,
    // Encoder channel-B direction/fault status (0x078 read-only, 0x080
    // read-only). 0x07c (position) is read-write: writing it pulses
    // quad_position_wr_en for one cycle so encoder_quadrature.v can preset
    // position (homing, or seeding an overflow test near the +-2^31 edge).
    input wire quad_direction,input wire signed [31:0] quad_position,
    input wire quad_illegal_fault,input wire [15:0] quad_illegal_count,
    input wire quad_timeout_fault,input wire quad_overflow_fault,
    output reg quad_position_wr_en,output reg signed [31:0] quad_position_wr_value
);
    // aw_hold/w_hold/addr_hold/data_hold/strb_hold: 위에서 설명한 "AW와 W를
    // 각각 독립적으로 latch"하는 레지스터들.
    reg aw_hold,w_hold;reg [11:0] addr_hold;reg [31:0] data_hold;reg [3:0] strb_hold;
    reg start_pulse,sticky_done,sticky_error;
    wire busy,core_done,cls;wire [31:0] cycles,ncycles,feat,hidden;wire [15:0] logits;wire [9:0] word_addr;
    // visible_busy: start_pulse를 막 세운 바로 그 클럭에는 아직 vibration_core의
    // busy가 1클럭 지연 때문에 미처 못 올라왔을 수 있으므로, "지금 시작
    // 명령했거나 이미 돌고 있는 중"을 소프트웨어에게 정확히 보여주기 위해
    // busy||start_pulse로 OR를 취함(레지스터 읽기(0x004)에서 이 값을 노출).
    wire visible_busy=busy||start_pulse;
    // READY 신호들: "aresetn이 살아있고, 아직 이전 요청을 처리 중(hold됨)이
    // 아니고, 이전 쓰기 응답(bvalid)이 아직 안 빠졌으면" 새 요청을 받지 않음
    // — 즉 한 번에 하나의 트랜잭션만 순차 처리(파이프라이닝 없음, Lite
    // 슬레이브다운 단순한 방식).
    assign s_axi_awready=aresetn && !aw_hold && !s_axi_bvalid;
    assign s_axi_wready=aresetn && !w_hold && !s_axi_bvalid;
    assign s_axi_arready=aresetn && !s_axi_rvalid;
    assign m_bram_clk=aclk;assign m_bram_rst=!aresetn;
    assign m_bram_addr={20'd0,word_addr,2'b00}; // BRAM controller mode uses BYTE addressing.
    // (한국어) vibration_core는 워드(32비트) 단위 주소(word_addr)로 계산하지만
    // BRAM 컨트롤러는 바이트 주소를 기대하므로, 워드 주소를 왼쪽으로 2비트
    // 시프트(={word_addr,2'b00})해서 4를 곱한 것과 같은 효과를 냄(워드당
    // 4바이트이므로).
    assign irq=sticky_done; // 완료 플래그가 서는 순간 ARM에 인터럽트로 알림(폴링 대신 인터럽트 방식도 가능하게)
    assign class_valid=core_done;
    assign class_id=cls;
    // vibration_core 인스턴스: 이 AXI 래퍼가 start_pulse로 시작을 명령하고,
    // core_done/cycles/feat/hidden/logits/cls로 결과를 받아 위 레지스터 맵에
    // 그대로 노출함. m_bram_* 포트들이 이 인스턴스의 BRAM 포트 B 접근을 그대로
    // 외부로 통과시키는 구조(자세한 내부는 vibration_core.v study 사본 참고).
    vibration_core core(aclk,!aresetn,start_pulse,busy,core_done,cycles,ncycles,feat,hidden,logits,cls,
        m_bram_en,m_bram_we,word_addr,m_bram_wdata,m_bram_rdata);
    reg spi_start,spi_rd,spi_two,spi_done_sticky;reg [6:0] spi_addr;reg [7:0] spi_wdata;
    wire spi_busy,spi_done;wire [7:0] spi_r8;wire [15:0] spi_r16;
    // MISO(센서->FPGA 데이터선)도 물리 핀이라 비동기 -> 2단 동기화(같은 패턴 반복)
    (* ASYNC_REG="TRUE" *) reg [1:0] miso_sync;
    always @(posedge aclk)if(!aresetn)miso_sync<=0;else miso_sync<={miso_sync[0],mpu_miso};
    // mpu_reg_spi 인스턴스: 0x040 쓰기로 트리거된 spi_start 등을 받아 실제
    // SPI 트랜잭션을 수행하는 엔진. 결과(spi_r8/spi_r16)는 0x044 읽기로 노출.
    mpu_reg_spi #(.CLK_HZ(CLK_HZ)) spi(aclk,!aresetn,spi_start,spi_rd,spi_two,spi_addr,spi_wdata,
        spi_r8,spi_r16,spi_busy,spi_done,mpu_sclk,mpu_mosi,miso_sync[1],mpu_cs_n);
    always @(posedge aclk)begin
        // (한국어) 위에서 설명한 "펄스 레지스터" 패턴의 실제 코드: 이 네
        // 신호를 매 클럭 일단 전부 0으로 깔아놓고 시작. 아래 case문에서
        // 조건이 맞을 때만 1로 override됨 -> 결과적으로 딱 한 클럭만 1.
        start_pulse<=0;spi_start<=0;ps_heartbeat<=0;quad_position_wr_en<=0;
        if(!aresetn)begin
            aw_hold<=0;w_hold<=0;addr_hold<=0;data_hold<=0;strb_hold<=0;
            s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
            sticky_done<=0;sticky_error<=0;spi_rd<=0;spi_two<=0;spi_addr<=0;spi_wdata<=0;spi_done_sticky<=0;
            ps_heartbeat<=0;
            // 리셋 시 기본값: open_loop 꺼짐, anti-windup 켜짐(안전한 기본),
            // kp/ki는 "원래 고정 튜닝값"과 정확히 같은 값으로 초기화 —
            // 즉 AXI로 아무것도 안 써도 예전(고정 상수) 버전과 동일하게 동작.
            open_loop_enable<=0;anti_windup_enable<=1;open_loop_duty<=0;
            kp_gain<=18'sd58982;ki_gain<=18'sd3932;
            quad_position_wr_en<=0;quad_position_wr_value<=0;
        end else begin
            if(core_done)sticky_done<=1; // "완료됨" 플래그는 소프트웨어가 0x000 bit1로 지울 때까지 계속 유지(sticky)
            if(spi_done)spi_done_sticky<=1;
            if(s_axi_bvalid && s_axi_bready)s_axi_bvalid<=0; // 응답을 마스터가 받아갔으면(bready) 내림
            if(s_axi_rvalid && s_axi_rready)s_axi_rvalid<=0; // 읽기 데이터를 마스터가 받아갔으면 내림
            // AW/W 핸드셰이크 성립 시 각각 독립적으로 latch(도착 순서 무관하게 받기 위함, 위 설명 참고)
            if(s_axi_awready && s_axi_awvalid)begin aw_hold<=1;addr_hold<=s_axi_awaddr;end
            if(s_axi_wready && s_axi_wvalid)begin w_hold<=1;data_hold<=s_axi_wdata;strb_hold<=s_axi_wstrb;end
            // 둘 다 도착 확인되면(aw_hold && w_hold) 그제서야 실제 레지스터 쓰기 수행
            if(aw_hold && w_hold && !s_axi_bvalid)begin
                aw_hold<=0;w_hold<=0;s_axi_bvalid<=1;s_axi_bresp<=0; // 기본은 성공(OKAY) 응답, 아래에서 에러면 override
                case(addr_hold)
                // 0x000: 제어 레지스터
                12'h000:if(strb_hold[0])begin
                    if(data_hold[1])begin sticky_done<=0;sticky_error<=0;end // bit1: 상태 클리어
                    if(data_hold[0])begin // bit0: 시작 요청
                        if(visible_busy)begin sticky_error<=1;s_axi_bresp<=2;end // 이미 도는 중이면 거부(에러 응답)
                        else begin start_pulse<=1;sticky_done<=0;sticky_error<=0;end
                    end
                end
                // 0x040: SPI 트랜잭션 시작(bit31이 트리거, 나머지 비트는 SPI 파라미터)
                12'h040:if(strb_hold==4'hf && data_hold[31])begin
                    if(spi_busy||spi_start)s_axi_bresp<=2; // SPI가 이미 바쁘면 거부
                    else begin spi_rd<=data_hold[7];spi_two<=data_hold[8];spi_addr<=data_hold[6:0];
                        spi_wdata<=data_hold[23:16];spi_start<=1;spi_done_sticky<=0;end
                end else if(strb_hold!=0)s_axi_bresp<=2;
                // 0x048: ps_heartbeat 펄스 -- safety_supervisor의 watchdog을 먹여살림
                12'h048:if(strb_hold[0] && data_hold[0])ps_heartbeat<=1;
                // 0x068: open_loop_enable(bit0) / anti_windup_enable(bit1)
                12'h068:if(strb_hold[0])begin
                    open_loop_enable<=data_hold[0];anti_windup_enable<=data_hold[1];
                end
                // 0x06c: open_loop_duty(13비트) -- 하위 두 바이트 strobe 아무거나 있으면 반영
                12'h06c:if(strb_hold[0]||strb_hold[1])open_loop_duty<=data_hold[12:0];
                // 0x070/0x074: kp_gain/ki_gain -- 4바이트(4'hf)가 전부 실릴 때만 갱신(부분쓰기 방지)
                12'h070:if(strb_hold==4'hf)kp_gain<=data_hold[17:0];
                12'h074:if(strb_hold==4'hf)ki_gain<=data_hold[17:0];
                // 0x07c: quad_position 프리셋 쓰기 -- wr_en 펄스 + 값 latch (오늘 추가된 오버플로우 테스트용 기능)
                12'h07c:if(strb_hold==4'hf)begin
                    quad_position_wr_en<=1;quad_position_wr_value<=data_hold;
                end
                default:s_axi_bresp<=2; // 정의되지 않은 주소에 쓰면 에러 응답
                endcase
            end
            // 읽기 채널: AR 핸드셰이크가 성립하면 그 클럭에 바로 rdata를 채워서
            // rvalid를 세움(Lite라서 별도의 BRAM 읽기 지연 없이 조합적으로 값을 고름).
            if(s_axi_arready && s_axi_arvalid)begin
                s_axi_rvalid<=1;s_axi_rresp<=0;
                case(s_axi_araddr)
                12'h000:s_axi_rdata<=0; // 제어 레지스터는 쓰기 전용 개념이라 읽으면 0
                12'h004:s_axi_rdata<={25'd0,motor_watchdog_fault,motor_derated,motor_warning,
                    motor_fault_latched,sticky_error,sticky_done,visible_busy};
                12'h008:s_axi_rdata<={31'd0,cls};
                12'h00c:s_axi_rdata<=cycles;
                12'h010:s_axi_rdata<=ncycles;
                12'h020:s_axi_rdata<={24'd0,feat[7:0]};
                12'h024:s_axi_rdata<={24'd0,feat[15:8]};
                12'h028:s_axi_rdata<={24'd0,feat[23:16]};
                12'h02c:s_axi_rdata<={24'd0,feat[31:24]};
                12'h030:s_axi_rdata<={{24{logits[7]}},logits[7:0]};     // 부호확장(8비트 signed -> 32비트)
                12'h034:s_axi_rdata<={{24{logits[15]}},logits[15:8]};   // 부호확장
                12'h044:s_axi_rdata<={14'd0,spi_done_sticky,(spi_busy||spi_start),(spi_two?spi_r16:{8'd0,spi_r8})};
                12'h048:s_axi_rdata<=0; // heartbeat도 쓰기 전용, 읽으면 0
                12'h04c:s_axi_rdata<={motor_abnormal_count,4'd0,motor_fault_cause,
                    motor_derated,motor_warning,motor_fault_consec};
                12'h050:s_axi_rdata<={19'd0,motor_speed_reference};
                12'h054:s_axi_rdata<={19'd0,motor_measured_speed};
                12'h058:s_axi_rdata<={19'd0,motor_requested_duty};
                12'h05c:s_axi_rdata<=motor_pid_integral;
                12'h060:s_axi_rdata<={31'd0,motor_armed_status};
                12'h064:s_axi_rdata<=motor_watchdog_count;
                12'h068:s_axi_rdata<={30'd0,anti_windup_enable,open_loop_enable};
                12'h06c:s_axi_rdata<={19'd0,open_loop_duty};
                12'h070:s_axi_rdata<={{14{kp_gain[17]}},kp_gain};   // 18비트 signed -> 32비트 부호확장
                12'h074:s_axi_rdata<={{14{ki_gain[17]}},ki_gain};
                12'h078:s_axi_rdata<={28'd0,quad_overflow_fault,quad_timeout_fault,
                    quad_illegal_fault,quad_direction};
                12'h07c:s_axi_rdata<=quad_position; // 읽으면 현재 위치값 그대로(RW 레지스터의 읽기 쪽)
                12'h080:s_axi_rdata<={16'd0,quad_illegal_count};
                default:begin s_axi_rdata<=0;s_axi_rresp<=2;end // 존재하지 않는 주소 읽기: 에러 응답
                endcase
            end
        end
    end
endmodule
