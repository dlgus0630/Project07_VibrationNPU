// ============================================================================
// [공부용 주석 사본] fourier/rtl/fourier_motor_control.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "엔코더로 실제 속도를 재고, PI 제어기로 목표
// 속도를 따라가도록 PWM 듀티를 계산하고, 안전 감독자(safety_supervisor)가
// 이상을 감지하면 즉시 모터를 멈추는 — 진동 실험용 독립 모터 구동 시스템의
// 모든 하위 부품(엔코더 2종, PID, PWM, 안전 감독자)을 하나로 묶는 최상위 모듈"
//
// 이 모듈은 fourier/rtl/vibration_core.v와 성격이 같습니다: 자기가 직접
// 계산을 하는 게 아니라, 이미 만들어진 부품들(encoder_speed_hybrid,
// encoder_quadrature, pid_fixed, pwm_period, safety_supervisor)을
// 인스턴스화해서 "누구를 언제 실행시키고, 누구의 출력을 누구의 입력으로
// 연결할지"만 결정하는 "배선 담당·오케스트레이터" 역할입니다. 그래서 아래
// 주석은 "각 하위 모듈이 내부적으로 무엇을 하는지"는 이미 안다고 가정하고
// (그건 각 모듈의 study 사본에 있습니다), "이 모듈이 그것들을 어떻게
// 서로 연결하는가"에 집중합니다.
//
// 전체 데이터 흐름 큰 그림
// -----------------------------------------------------------------------
//   encoder_a (엔코더 펄스)
//        │
//        ▼
//   encoder_speed_hybrid  ──▶ measured_speed (지금 실제로 도는 속도)
//        │                          │
//        │                          ▼
//        │                     pid_fixed (목표속도 - 측정속도 오차를 줄이는 방향으로 duty 계산)
//        │                          │
//        │                          ▼
//        │                     requested_duty (우선순위 로직으로 최종 확정)
//        │                          │
//        │                          ▼
//        │                        duty (안전 감독자가 derate시키면 25%로 clamp)
//        │                          │
//        ├──────────────┬───────────┴───────────┐
//        ▼              ▼                       ▼
//   encoder_quadrature  pwm_period            motor_pwm (실제 모터 구동 신호)
//   (방향/고장 감시,     (duty 비율만큼
//    관찰 전용)           PWM 파형 생성)
//
// 스위치(SW0~SW3)와 버튼(BTN0=stop_button)의 역할
// -----------------------------------------------------------------------
// - SW0: "arm(무장)" 스위치. 그냥 켜져 있다고 바로 모터가 도는 게 아니라
//   아래에서 설명할 seen_off 로직을 통과해야 armed=1이 됩니다.
// - SW2:SW1(2비트): 목표 속도를 0/25/50/75% 중 하나로 선택(speed_reference).
// - SW3: "고장 주입(fault injection)" 스위치. 켜면 32Hz로 25%↔75% duty를
//   왔다갔다 하면서 일부러 진동(토크 리플)을 만들어냅니다 — 이 프로젝트의
//   "진동 분류기(FFT+NPU)"가 진짜로 이상 진동을 구분해내는지 테스트하기
//   위한 알려진 가진(加振) 신호입니다.
// - stop_button(BTN0): 누르면 reset_sync를 통해 즉시 rst를 걸어 모터를
//   멈춥니다(비상정지 개념).
// ============================================================================

// Independent motor drive for vibration experiments; closed-loop speed by default.
// SW0 arms after OFF -> ON. SW2..1 select 0/25/50/75% of full-scale speed. BTN0 stops.
// SW3 injects a controlled 32 Hz torque ripple by alternating 25/75% duty.
// AXI (via axi_vibration_top) can override the PI gains, disable anti-windup, or
// drive an open-loop duty directly for system identification -- see kp_gain/
// ki_gain/anti_windup_enable/open_loop_enable/open_loop_duty above.
module fourier_motor_control #(
    parameter integer CLK_HZ=100000000,
    parameter integer FAULT_HZ=32,
    parameter integer FAULT_CONSEC=3,
    parameter integer WATCHDOG_CYCLES=CLK_HZ/2
)(input wire clk,input wire reset_n,input wire stop_button,input wire [3:0] sw,
    output wire motor_pwm,output wire motor_in1,output wire motor_in2,
    output wire motor_armed,
    input wire class_valid,input wire class_id,input wire ps_heartbeat,
    output wire motor_fault,output wire motor_warning,output wire motor_derated,
    output wire motor_watchdog_fault,output wire [1:0] motor_fault_cause,
    output wire [7:0] motor_fault_consec,output wire [15:0] motor_abnormal_count,
    input wire encoder_a,input wire encoder_b,
    input wire quad_position_wr_en,input wire signed [31:0] quad_position_wr_value,
    output wire quad_direction,output wire signed [31:0] quad_position,
    output wire quad_illegal_fault,output wire [15:0] quad_illegal_count,
    output wire quad_timeout_fault,output wire quad_overflow_fault,
    output wire [12:0] motor_speed_reference,
    output wire [12:0] motor_measured_speed,
    output wire [12:0] motor_requested_duty,
    output wire signed [31:0] motor_pid_integral,
    output wire [31:0] motor_watchdog_count,
    // Runtime PI tuning and an open-loop duty override for system identification;
    // driven from AXI, default-wired at reset to match the original fixed tuning.
    // (한국어) kp_gain/ki_gain/anti_windup_enable/open_loop_enable/open_loop_duty는
    // 전부 axi_vibration_top.v가 ARM 소프트웨어의 레지스터 쓰기를 받아서 이
    // 모듈에 흘려보내는 입력입니다. 즉 이 모듈 자체는 "PI 이득이 몇인지"를
    // 스스로 정하지 않고, 바깥(AXI)에서 주는 값을 그대로 씁니다 — 런타임에
    // 재부팅 없이 게인을 바꿀 수 있게 하려는 설계(시스템 식별 실험에 필요).
    input wire signed [17:0] kp_gain,input wire signed [17:0] ki_gain,
    input wire anti_windup_enable,
    input wire open_loop_enable,input wire [12:0] open_loop_duty);
    wire rst;
    // reset_sync: 비동기 입력(!reset_n||stop_button, 버튼 입력은 클럭과 무관하게
    // 아무 때나 바뀔 수 있음)을 받아서, 메타스테이블(불안정한 중간 전압) 위험
    // 없이 클럭에 동기화된 rst 신호로 바꿔줌. 이 모듈 전체가 이 rst를 기준으로
    // 리셋됨(전원 리셋뿐 아니라 stop_button을 눌러도 똑같이 rst=1이 걸림에 주목).
    reset_sync resetter(clk,!reset_n||stop_button,rst);
    // (* ASYNC_REG="TRUE" *): sw는 물리 스위치라서 클럭과 무관하게 아무 때나
    // 바뀌는 비동기 신호. 2단 플롭(sw_meta -> sw_sync)으로 동기화해서
    // 메타스테이블이 이후 로직으로 전파되지 않게 함(이 프로젝트 전반에 반복되는
    // 표준 패턴). ASYNC_REG 속성은 합성 툴에게 "이 두 플롭은 붙여서 배치하고
    // 최적화로 합치지 마라"고 알려주는 지시자.
    (* ASYNC_REG="TRUE" *) reg [3:0] sw_meta,sw_sync;
    reg [2:0] warmup;      // 전원 인가 직후 몇 클럭 동안은 스위치 판독을 무시(디바운스/안정화 대기)
    reg seen_off,armed;    // seen_off: SW0이 OFF인 순간을 한 번이라도 봤는지 / armed: 실제로 무장됐는지
    reg [31:0] fault_count;// SW3 고장주입용 위상 타이머 카운터
    reg fault_phase;       // 0=25% duty 구간, 1=75% duty 구간 (32Hz로 토글)
    localparam integer FAULT_HALF_CYCLES=CLK_HZ/(2*FAULT_HZ); // 32Hz 사각파의 반주기를 클럭 수로 환산
    wire fault_latched;
    // SW0 low is the operator release.  The supervisor also owns a heartbeat
    // watchdog, so loss of the Cortex-A9 application forces the same latched stop.
    // (한국어) safety_supervisor를 인스턴스화. 입력으로 넘기는 !sw_sync[0]은
    // "운전자가 SW0을 내려서 놓아달라고 한 상태"를 안전 감독자에게 그대로
    // 전달하는 것 — 즉 안전 감독자 입장에서는 "사람이 릴리즈를 눌렀다"와
    // "PS 하트비트가 끊겼다(watchdog)"가 똑같이 "멈춰야 하는 이유"로 취급됨.
    // 출력 fault_latched가 1이 되면 이 모듈 전체가 enabled=0으로 떨어짐(아래).
    safety_supervisor #(.TRIP_CONSEC(FAULT_CONSEC),.DERATE_CONSEC(2),
        .WATCHDOG_CYCLES(WATCHDOG_CYCLES)) safety_unit(
        clk,rst,!sw_sync[0],armed,class_valid,class_id,ps_heartbeat,
        motor_warning,motor_derated,fault_latched,motor_watchdog_fault,
        motor_fault_cause,motor_fault_consec,motor_abnormal_count,motor_watchdog_count);
    // enabled: "지금 이 순간 모터를 실제로 구동해도 되는가"를 한 방에 정리한
    // 최종 판단. armed(무장됨) && 리셋 중 아님 && 물리적으로 reset_n이 살아있음
    // && stop_button 안눌림 && 안전 감독자가 fault를 걸지 않음 — 이 다섯 가지가
    // 전부 참이어야만 1. 이 enabled 하나가 아래 pid_start, duty, PWM, 인코더
    // 관찰 로직 전부에 영향을 미치는 "마스터 스위치" 역할을 합니다.
    wire enabled=armed && !rst && reset_n && !stop_button && !fault_latched;
    wire fault_inject=sw_sync[3]; // SW3: 토크 리플 주입 모드 on/off
    // Same 2-bit encoding the fixed-duty build used, now read as a PI speed target.
    // (한국어) sw_sync[2:1] 2비트를 그대로 상위 비트에 넣고 하위 10비트는 0으로
    // 채움 -> 00=0, 01=1/4, 10=2/4, 11=3/4 스케일의 speed_reference가 만들어짐.
    // 예전 버전(고정 duty 버전)에서 쓰던 것과 똑같은 2비트 인코딩을 재사용해서,
    // 지금은 "duty 자체"가 아니라 "PI 제어기의 목표 속도값"으로 의미만 바뀜.
    wire [12:0] speed_reference={1'b0,sw_sync[2:1],10'd0};
    wire measured_encoder_pulse;
    wire [12:0] measured_speed;
    reg sample_tick;
    reg [31:0] tick_count;
    // 100Hz(10ms마다 1번) sample_tick 생성기: PID 제어 루프를 매 클럭(100MHz)이
    // 아니라 정해진 주기로만 돌리기 위한 타이머. 제어 이론적으로 "샘플링 주기"를
    // 일정하게 유지해야 PI 게인 튜닝이 의미가 있기 때문에 이렇게 명시적인
    // 카운터로 tick을 만듭니다.
    always @(posedge clk)begin
        sample_tick<=0;
        if(rst)tick_count<=0;
        else if(tick_count==CLK_HZ/100-1)begin tick_count<=0;sample_tick<=1;end
        else tick_count<=tick_count+1'b1;
    end
    wire speed_valid;
    // encoder_speed_hybrid: sample_tick이 올 때마다 그동안의 엔코더 펄스 수를
    // 세어 속도로 환산(저속에서는 펄스 간격을, 고속에서는 펄스 개수를 쓰는
    // "하이브리드" 방식 — 자세한 내부 동작은 이 모듈의 study 사본 참고).
    // 여기서 중요한 건 출력 speed_valid: sample_tick 자체가 아니라, 파이프라인을
    // 한 단 더 거쳐 measured_speed가 "진짜로 갱신 완료된" 그 클럭에만 1이 됨.
    encoder_speed_hybrid #(.CLK_HZ(CLK_HZ)) encoder(
        clk,rst,sample_tick,encoder_a,measured_speed,measured_encoder_pulse,speed_valid);
    wire pid_busy,pid_done;
    wire [12:0] pid_duty;
    wire signed [31:0] pid_integral;
    wire signed [17:0] pid_derivative;
    reg pid_start;
    wire controller_reset=rst||!enabled; // enabled가 꺼지면 PID 내부 적분값도 같이 리셋(윈드업 방지)
    // Gate on speed_valid, not sample_tick directly: the encoder's sample_tick ->
    // speed pipeline (added when closing timing on the watchdog-count build) now
    // takes one extra clock past sample_tick before `measured_speed` holds its new
    // value, so triggering the PID straight off sample_tick would feed it a
    // one-sample-stale reading. speed_valid pulses the same cycle measured_speed
    // is actually current, preserving the original same-cycle guarantee.
    //
    // (한국어 보충설명) 이 부분은 실제로 겪은 타이밍 버그를 고친 흔적입니다.
    // 처음 설계할 때는 "sample_tick이 뜨면 바로 그 클럭에 PID를 시작해도
    // measured_speed는 이미 최신값일 것"이라고 가정했습니다. 그런데 나중에
    // watchdog 카운터 기능을 넣으면서 encoder_speed_hybrid 내부 로직이 한
    // 단계(1클럭) 더 깊어졌고, 그러면 sample_tick이 뜬 바로 그 클럭에는
    // measured_speed가 아직 "지난 번 값"이 됩니다(한 클럭 stale). 이걸 그대로
    // 두면 PID가 항상 한 샘플 낡은 속도값으로 제어를 계산하게 되어 미묘하게
    // 성능이 나빠집니다. 해결책은 "언제 시작할지"를 sample_tick이 아니라,
    // encoder_speed_hybrid가 "이제 measured_speed 갱신 끝났다"고 알려주는
    // speed_valid 신호로 바꾸는 것 — 이렇게 하면 파이프라인이 몇 단이든 상관없이
    // "값이 준비된 바로 그 클럭"에 PID가 시작되도록 자동으로 맞춰집니다.
    // 교훈: 여러 모듈을 이어붙일 때는 "누가 언제 값을 최종 확정하는지"를
    // 명시적인 valid 신호로 주고받는 게, 타이밍을 암묵적으로 가정하는 것보다
    // 훨씬 안전합니다(하위 모듈 내부 구현이 바뀌어도 상위 모듈을 고칠 필요가 없음).
    always @(posedge clk)begin
        pid_start<=0;
        if(speed_valid && enabled && !pid_busy)pid_start<=1;
    end
    // pid_fixed: speed_reference(목표) - measured_speed(측정)의 오차를 보고
    // Q-format 고정소수점 PI 연산으로 pid_duty를 계산. kp_gain/ki_gain/
    // anti_windup_enable은 모두 AXI에서 흘러들어온 런타임 파라미터(위 참고).
    pid_fixed controller(clk,controller_reset,pid_start,speed_reference,measured_speed,
        kp_gain,ki_gain,anti_windup_enable,
        pid_busy,pid_done,pid_duty,pid_integral,pid_derivative);
    // Open-loop override (system identification) wins over everything else; SW3
    // otherwise overrides the loop output so the ripple injection stays a known
    // excitation.
    //
    // (한국어) requested_duty 우선순위 로직 — "결국 무엇이 모터를 실제로
    // 구동하는가"를 정하는 이 모듈에서 제일 중요한 한 줄입니다. 우선순위는
    // 위에서부터 아래로:
    //   1순위) open_loop_enable=1 이면 무조건 open_loop_duty를 그대로 씀.
    //          이건 "시스템 식별(system identification)" 실험 모드 — PI
    //          제어기를 아예 거치지 않고 ARM 소프트웨어가 원하는 duty를
    //          직접 강제로 넣어서, "이 duty를 넣으면 실제로 얼마나 빨리
                //          도는가"를 측정해 plant(제어 대상)의 특성을 알아내려는
    //          목적입니다(펌웨어의 'p' 명령이 이 경로를 씀). 최우선인 이유:
    //          실험 중에는 PI나 fault_inject가 끼어들면 순수한 duty->속도
    //          관계를 측정할 수 없기 때문.
    //   2순위) open_loop_enable=0 이고 fault_inject(SW3)=1 이면, fault_phase에
    //          따라 25%(13'd1024) 또는 75%(13'd3072) duty를 강제. 이게 위에서
    //          설명한 32Hz 토크 리플 — PI 루프를 거치지 않고 "정상 PI 출력을
    //          덮어씌워서" 알려진 가진 신호를 만듭니다.
    //   3순위) 둘 다 아니면 pid_duty, 즉 정상적인 PI 폐루프 제어 출력이 실제로
    //          모터를 구동합니다 — 이게 "기본" 동작 모드입니다.
    wire [12:0] requested_duty=open_loop_enable ? open_loop_duty :
        (fault_inject ? (fault_phase ? 13'd3072 : 13'd1024) : pid_duty);
    // A second consecutive abnormal window caps the drive at 25%.  A third one
    // takes enabled low through fault_latched and therefore forces PWM to zero.
    // (한국어) motor_derated는 safety_supervisor가 "연속 2번째 이상 판정"일 때
    // 세우는 신호. requested_duty가 25%(13'd1024)보다 크면 강제로 25%로
    // 깎아버림(clamp) — "완전히 멈추기 전에 먼저 힘을 줄여서 경고"하는 단계적
    // 대응. 3번째 연속 이상이면 안전 감독자가 fault_latched를 걸어 enabled
    // 자체가 0이 되므로, duty 값과 무관하게 PWM이 완전히 0이 됩니다.
    wire [12:0] duty=(motor_derated && requested_duty>13'd1024) ? 13'd1024 : requested_duty;
    // Direction and reliability check from the second channel; purely
    // observational, does not feed the PI loop or the safety supervisor. Placed
    // after `duty` is declared above so this positional instantiation doesn't
    // implicitly (and wrongly, 1-bit) declare it first.
    //
    // (한국어, 실제로 겪은 Verilog 버그 이야기) 이 인스턴스가 `duty` 선언보다
    // "아래"에 있는 건 우연이 아니라 의도적인 순서입니다. Verilog는 wire를
    // 포지셔널(순서대로) 포트 연결에 쓸 때, 만약 그 wire가 아직 어디서도
    // 선언(assign이나 output wire 등)된 적이 없으면 폭(비트수) 정보 없이
    // "암묵적으로 1비트짜리 wire"를 자동으로 만들어버립니다(경고만 뜨고 컴파일은
    // 통과되는 경우가 많아서 더 위험함). 실제로 이 프로젝트에서 겪은 문제가
    // 바로 이것이었습니다: encoder_quadrature 인스턴스를 duty 선언보다 먼저
    // 써놓았더니, 그 시점에는 duty가 아직 폭 13비트로 확정되기 전이라 Verilog가
    // duty를 1비트 wire로 암묵 선언해버렸고, 그 결과 encoder_quadrature에
    // 실제로는 13비트여야 할 duty 값이 1비트만 들어가서 동작이 완전히 틀어지는
    // 버그가 생겼습니다. 고친 방법은 간단합니다 — "duty를 만드는 코드"를 먼저
    // 쓰고, "duty를 쓰는 코드(이 quadrature 인스턴스)"를 그 뒤에 배치하는 것.
    // 교훈: Verilog에서 신호를 포지셔널로 연결할 때는 그 신호가 먼저
    // 선언(폭이 확정)된 뒤에 참조해야 하고, 가능하면 이런 실수를 원천 차단하기
    // 위해 이름으로 연결하는 문법(.port_name(signal))을 쓰는 것도 좋은 습관입니다.
    encoder_quadrature #(.CLK_HZ(CLK_HZ)) quadrature(
        clk,rst,!sw_sync[0],enabled,duty,encoder_a,encoder_b,
        quad_position_wr_en,quad_position_wr_value,
        quad_direction,quad_position,quad_illegal_fault,quad_illegal_count,
        quad_timeout_fault,quad_overflow_fault);
    wire [12:0] active_duty;
    // pwm_period: duty 비율에 맞춰 실제 PWM 파형(motor_pwm)을 만들어내는 부품.
    // PERIOD=CLK_HZ/20000 -> 100MHz/20000=5000클럭마다 한 주기, 즉 20kHz PWM
    // (가청 주파수 위쪽이라 "삐" 소리 안 나게 하려는 의도로 보임).
    pwm_period #(.PERIOD(CLK_HZ/20000)) pwm_unit(clk,rst,enabled,duty,motor_pwm,active_duty);
    assign motor_in1=enabled; // 모터 드라이버 방향핀: 이 프로젝트는 항상 한 방향으로만 구동
    assign motor_in2=1'b0;    // (양방향 제어를 안 쓰므로 in2는 항상 0으로 고정)
    assign motor_armed=enabled;
    assign motor_fault=fault_latched;
    assign motor_speed_reference=speed_reference;
    assign motor_measured_speed=measured_speed;
    assign motor_requested_duty=duty; // AXI가 읽어가는 값은 clamp까지 적용된 "실제로 나간" duty
    assign motor_pid_integral=pid_integral;
    // quad_* outputs are already top-level ports driven directly by the
    // quadrature instance above (no motor_ prefix; there is no naming clash
    // with the vibration classifier's own motor_* status signals).
    // (한국어) quad_direction/quad_position 등은 위 quadrature 인스턴스의
    // 포트 연결에서 이미 이 모듈의 출력 포트에 직접 assign된 상태라, 여기서
    // 따로 또 assign할 필요가 없다는 뜻. 이름에 motor_ 접두어가 없는 이유도
    // "진동 분류기 쪽의 motor_* 상태 신호들과 이름이 겹치지 않는다"는 설명.
    always @(posedge clk)begin
        if(rst)begin
            sw_meta<=0;sw_sync<=0;warmup<=0;seen_off<=0;armed<=0;
            fault_count<=0;fault_phase<=0;
        end
        else begin
            sw_meta<=sw;sw_sync<=sw_meta; // 2단 동기화 시프트(비동기 스위치 입력 안정화)
            if(warmup<4)warmup<=warmup+1'b1; // 리셋 직후 4클럭 동안은 아래 armed 판단을 아예 안 함
            // (한국어, seen_off / armed 안전장치 설명)
            // 이 로직의 목적: "전원을 켰을 때 SW0이 우연히 이미 ON 위치에
            // 있어도 모터가 저절로 돌기 시작하면 안 된다"는 물리적 안전
            // 요구사항. 만약 단순히 "SW0이 ON이면 armed=1"이라고만 짰다면,
            // 전원 인가 시점에 스위치가 이미 켜져 있는 상태(운전자가 이전
            // 실험 끝나고 안 끄고 그냥 둔 경우 등)에서 바로 모터가 움직여버려
            // 위험합니다. 그래서 "반드시 OFF 상태를 한 번은 거쳐야만(seen_off=1)
            // 그 다음에 ON으로 바뀔 때 armed=1이 된다"는 규칙을 둡니다:
            //   - warmup 끝난 뒤 SW0이 OFF(!sw_sync[0])면: seen_off<=1로
            //     "OFF를 봤다"고 기록하고, armed는 즉시 0(안전 상태 유지).
            //   - SW0이 ON인데 seen_off가 이미 1이면(=과거에 OFF를 본 적
            //     있으면): 그제서야 armed<=1.
            //   - 만약 seen_off가 아직 0인 채로 SW0이 계속 ON이면(=전원 켤 때
            //     부터 쭉 ON이었던 경우): armed는 절대 1이 되지 않음 — 바로 이
            //     경우가 막고 싶었던 "저절로 도는" 상황입니다. 운전자가 SW0을
            //     한 번 내렸다가 다시 올려야만 비로소 무장됩니다.
            else if(!sw_sync[0])begin seen_off<=1;armed<=0;end
            else if(seen_off)armed<=1;
            // fault_inject(SW3) 위상 생성: enabled이고 fault_inject가 켜져
            // 있을 때만 카운터가 돌아가며, FAULT_HALF_CYCLES마다 fault_phase를
            // 뒤집어서 32Hz 사각파를 만듦. enabled가 꺼지거나 fault_inject가
            // 꺼지면 즉시 카운터/위상을 리셋(다음에 다시 켤 때 항상 25%부터
            // 시작하도록 — 재현성을 위한 설계).
            if(!enabled || !fault_inject)begin fault_count<=0;fault_phase<=0;end
            else if(fault_count==FAULT_HALF_CYCLES-1)begin
                fault_count<=0;fault_phase<=~fault_phase;
            end else fault_count<=fault_count+1'b1;
        end
    end
endmodule
