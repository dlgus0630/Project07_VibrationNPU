// ============================================================================
// [공부용 주석 사본] fourier/rtl/encoder_speed_hybrid.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "모터 축에 달린 엔코더가 내보내는 펄스를 보고
// 회전 속도를 추정하는 회로. 저속에서는 '펄스와 펄스 사이 시간의 역수'로,
// 고속에서는 '일정 시간(window) 동안 펄스를 몇 개 세었는지'로 계산하고,
// 상황에 따라 이 두 방식을 자동으로 섞어 쓰는 하이브리드 설계"
//
// 왜 방식을 하나로 통일하지 않고 "하이브리드"로 만들었나?
// -----------------------------------------------------------------------
// 이 모듈은 두 가지 속도 추정 방법을 씁니다.
//   (A) window count 방식: `sample_tick`(예: 100Hz, 10ms마다)이 뜰 때마다
//       그 사이에 엔코더 펄스가 몇 개(`window_count`) 들어왔는지 세서
//       "펄스 개수 ∝ 속도"로 계산합니다.
//   (B) reciprocal(역수) 방식: 펄스와 펄스 사이에 걸린 시간(클럭 개수,
//       `period_count`)을 정밀하게 재고, "속도 ∝ 1/시간"으로 계산합니다
//       (역수 계산이 필요해서 `unsigned_divider`를 씁니다).
// 문제는 이 두 방식이 서로 반대의 약점을 가진다는 것입니다.
//   - 저속일 때: 10ms 동안 펄스가 0~1개밖에 안 들어올 수 있습니다(A방식).
//     그러면 "0개냐 1개냐"로만 속도를 구분해야 해서 해상도가 형편없습니다.
//     반면 B방식은 펄스 사이 시간이 길어서(느리게 도니까) 클럭 카운터로
//     아주 정밀하게 잴 수 있습니다 — 저속에서는 B가 유리합니다.
//   - 고속일 때: 펄스 사이 시간이 너무 짧아서(`period_count`가 작아서)
//     나눗셈기(divider)가 다음 펄스가 오기 전에 계산을 못 끝낼 수도 있고
//     (아래 `!divider_busy` 체크가 이 상황을 보호합니다), 짧은 시간을 재는
//     것 자체의 상대 오차도 커집니다. 반면 A방식은 10ms 동안 펄스가 많이
//     들어오니(`window_count`가 큼) 통계적으로 안정적입니다 — 고속에서는
//     A가 유리합니다.
// 그래서 "느릴 땐 B, 빠를 땐 A"를 쓰고, 그 경계 부근에서는 아래 설명할
// 히스테리시스로 자연스럽게 넘어가도록 설계했습니다.
//
// A방식(window count)의 계산: 나눗셈 없이 "역수를 미리 곱하는" 트릭
// -----------------------------------------------------------------------
// `RECIP_Q12 = (16777216+(COUNTS_FULL_SCALE/2))/COUNTS_FULL_SCALE` —
// 16777216 = 2^24 입니다. 즉 이 상수는 "2^24를 COUNTS_FULL_SCALE로 나눈
// 값"(반올림 포함)입니다. 원래는 매 sample_tick마다 `bounded_count /
// COUNTS_FULL_SCALE`을 계산해야 하는데(펄스 개수를 최대값 대비 비율로
// 바꾸는 것), 나눗셈은 느리고 회로가 큽니다. 대신 "나누는 값이 항상
// COUNTS_FULL_SCALE로 고정"이라는 점을 이용해서, 그 나눗셈을 미리 계산해둔
// 상수(RECIP_Q12)를 "곱하는" 걸로 바꿔치기합니다: `bounded_count *
// RECIP_Q12`를 계산한 뒤 12비트만큼 오른쪽으로 밀면(`window_product_reg
// [24:12]`) 결과적으로 "bounded_count/COUNTS_FULL_SCALE을 Q12(4096=100%)
// 스케일로 표현한 값"이 나옵니다(2^24를 곱하고 2^12로 나눴으니 순
// 스케일은 2^12). 곱셈은 FPGA의 DSP48E1 하드웨어 블록으로 한 클럭에 끝나기
// 때문에 나눗셈보다 훨씬 빠릅니다 — "나눗셈을 곱셈으로 바꾸는" 이 트릭은
// 나눗셈 값이 고정 상수일 때 자주 쓰이는 표준적인 최적화입니다.
//
// B방식(reciprocal)의 계산: 진짜 나눗셈기를 재사용
// -----------------------------------------------------------------------
// 여기서는 나누는 값(`period_divisor`, 즉 펄스 사이 시간)이 매번 달라지기
// 때문에 위 트릭을 못 쓰고, 진짜 나눗셈이 필요합니다. 그래서
// `unsigned_divider`(1클럭에 1비트씩 계산하는 반복 나눗셈기, 자세한 설명은
// docs/study/fourier/rtl/unsigned_divider.v 참고)를 그대로 재사용합니다.
// `SPEED_NUMERATOR / measured_period`를 계산하는데, 이건 "속도 = 상수/시간"
// 이라는 물리식 그대로입니다(시간이 짧을수록 = 빨리 돌수록 속도가 큼).
// `SPEED_NUMERATOR`는 "A방식과 B방식이 정확히 같은 스케일(4096=최대)을
// 가리키도록" 미리 계산된 보정 상수입니다 — 그래서 두 방식이 전환되는
// 순간에도 속도값이 뚝 끊기지 않고 이어집니다(아래에서 더 설명).
// 또한 `have_edge && !divider_busy`일 때만 나눗셈을 새로 시작하는데, 이건
// "나눗셈기가 아직 이전 계산 중이면 새 계산을 걸지 않는다"는 뜻으로, 고속
// 회전 시 divider가 못 따라가는 극단적 상황에서도 회로가 깨지지 않게
// 보호합니다(그 주기의 계산은 그냥 건너뛰어짐).
//
// period_speed의 저역통과 필터(스무딩)
// -----------------------------------------------------------------------
// `reciprocal_speed`(방금 계산된 역수 속도)를 그대로 쓰지 않고,
// `period_speed <= period_speed + ((reciprocal_speed-period_speed+2)>>2)`
// 처럼 "차이의 1/4만큼만 이동"시킵니다. 이건 간단한 IIR(무한 임펄스 응답)
// 저역통과 필터로, 엔코더 디스크의 미세한 제작 오차나 노이즈 때문에 매
// 펄스마다 조금씩 흔들리는(jitter) reciprocal 값을 부드럽게 만들어 줍니다
// (`+2`는 우측 시프트로 인한 버림을 보정하는 반올림 트릭).
//
// speed_valid/PIPELINE split (오늘 watchdog-count 빌드에서 타이밍 클로저
// 작업 중 추가됨, pid_fixed.v의 PRODUCTS/PRODUCTS_HI 분할과 같은 세션)
// -----------------------------------------------------------------------
// "타이밍 클로저(timing closure)"란: FPGA는 매 클럭마다 신호가 한 레지스터
// 에서 다음 레지스터까지 "제때(한 클럭 주기 안에)" 도착해야 합니다. 100MHz
// 클럭이면 한 주기가 10ns인데, 만약 계산 경로가 복잡해서 신호가 10ns 안에
// 도착하지 못하면(=타이밍 클로저 실패), 그 회로는 잘못된(오래된 or 중간에
// 걸친) 값을 읽어버려서 오동작합니다. 시뮬레이션에서는 멀쩡해 보여도 실제
// 보드에서는 랜덤하게 틀린 값이 나오는 무서운 버그입니다.
//
// 원래(수정 전) 코드는 `sample_tick`이 뜨는 그 한 클럭 안에서: 살아있는
// `window_total`/`pulse` 신호 → `bounded_count` 먼저 계산 → DSP48E1
// 곱셈기로 `window_product` 계산 → `window_speed` 계산 → 마지막으로
// HIGH/LOW_COUNT_THRESHOLD 4방향 우선순위 멀티플렉서로 `speed`를 결정,
// 이 모든 걸 한 클럭 안에서 다 처리하려고 했습니다. 그런데 합성/배치·배선
// 이후 타이밍 리포트(fourier_watchdog_timing5.rpt)를 보니 이 경로가 설계
// 전체에서 가장 느린 경로(worst path)였습니다: WNS(Worst Negative Slack,
// "얼마나 늦었는지"의 음수값) -0.413ns, 논리 단계 13개(CARRY4 6개 +
// DSP48E1 1개 + LUT류 6개), 실제 신호 지연 10.275ns인데 요구 조건은
// 10.000ns(100MHz)였습니다 — 즉 0.275ns가 모자라서 타이밍 클로저 실패.
//
// 해결책: pid_fixed.v의 PRODUCTS/PRODUCTS_HI 분할과 같은 기법 —
// 한 클럭에 다 하려던 계산을 두 파이프라인 단계로 쪼갰습니다.
//   1단계(여전히 `sample_tick`이 뜰 때 실행): 이번 판단에 필요한 모든
//     "살아있는" 신호값을 그대로 스냅샷(레지스터에 복사)해 둡니다
//     (`window_total_snap`, `period_valid_snap`, `period_timeout_snap`,
//     `high_speed_mode_snap`, `period_speed_snap`), 그리고 DSP48E1
//     곱셈 결과(`window_product`)도 `window_product_reg`에 등록만 해둡니다.
//     이건 근사가 아니라 "정확히 같은 값을 한 클럭 먼저 레지스터에
//     담아두는 것"일 뿐입니다(bounded_count/RECIP_Q12 자체는 그대로).
//   2단계(`speed_calc_pending`이 1일 때, 1클럭 뒤): 이미 레지스터에
//     저장된 값들만 가지고 문턱값 비교와 우선순위 멀티플렉서를 수행해서
//     `speed`를 씁니다. DSP48E1 곱셈이 이 클럭의 경로에는 더 이상 없으므로
//     경로가 훨씬 짧아집니다.
// 결과적으로 한 클럭짜리 긴 계산이 두 클럭짜리 계산으로 나뉘어서, 각
// 클럭마다 처리할 논리가 절반으로 줄었습니다(경로 깊이 절반 ≈ 타이밍
// 여유 확보).
//
// 이렇게 하면 `sample_tick`과 `speed`가 실제로 갱신되는 시점 사이에 클럭
// 1개(10ns)의 지연이 추가로 생깁니다. 그런데 이 모듈의 샘플 주기는
// 100Hz(10ms = 1,000,000클럭@100MHz)이므로, 10ns 지연은 전체 주기의
// 0.001%에 불과해서 실질적으로 아무 영향이 없습니다. 유일하게 진짜
// 문제가 될 수 있었던 곳은 `fourier_motor_control.v`의 `pid_start`
// 였습니다 — 원래는 `speed`가 갱신되는 것과 똑같은 클럭 엣지(둘 다
// `sample_tick`에서 직접 나옴)에서 `pid_start`가 뜬다고 가정했는데,
// 이제 `speed`가 한 클럭 늦게 갱신되니 그 가정이 깨집니다. 그래서
// "`speed`가 실제로 새 값을 갖게 되는 그 클럭에만 1클럭 펄스로 뜨는"
// 새 핸드셰이크 신호 `speed_valid`를 추가했습니다(이 프로젝트에서 반복
// 되는 busy/done 패턴과 같은 정신 — pid_fixed.v, unsigned_divider.v
// 참고). 그리고 `fourier_motor_control.v`는 이제 `pid_start`를 `sample_
// tick` 대신 `speed_valid`에 맞춰 걸도록 수정되었습니다. 전체 XSim
// 회귀 테스트로 비트 단위까지 동일함을 검증했습니다(실행 로그는
// HANDOFF.md 참고).
//
// (ASYNC_REG 2단 동기화, 히스테리시스 등 이 파일에서 반복되는 다른 패턴은
//  아래 코드의 해당 줄에서 짧게 설명합니다.)
// ============================================================================

// Hybrid encoder estimator: reciprocal pulse period at low speed and window count at high speed.
module encoder_speed_hybrid #(
    parameter integer CLK_HZ=100000000,
    parameter integer SAMPLE_HZ=100,
    parameter integer COUNTS_FULL_SCALE=18,
    parameter integer HIGH_COUNT_THRESHOLD=14,
    parameter integer LOW_COUNT_THRESHOLD=10,
    parameter integer TIMEOUT_MS=100
)(input wire clk,input wire rst,input wire sample_tick,input wire encoder_a,
    output reg [12:0] speed,output wire pulse,output reg speed_valid);
    // speed_valid/PIPELINE split (added when closing timing on the watchdog-count
    // build, same session as the PRODUCTS/PRODUCTS_HI split in pid_fixed.v): the
    // original single-cycle sample_tick block read the live `window_total`/`pulse`
    // combinational chain straight through the bounded_count mux, the DSP48E1
    // window_product multiply, the window_speed mux, and the four-way
    // HIGH/LOW_COUNT_THRESHOLD priority-mux into `speed` in one clock. Post-route
    // this was the worst path in the design (fourier_watchdog_timing5.rpt): WNS
    // -0.413ns, 13 logic levels (CARRY4=6 DSP48E1=1 LUT3=1 LUT4=1 LUT5=4), Data
    // Path Delay 10.275ns against the 10.000ns/100MHz requirement, from
    // sync_reg[1]/C through to speed_reg[12]/D.
    //
    // Fix: split into two pipeline stages, same technique as pid_fixed.v's
    // PRODUCTS/PRODUCTS_HI split. Stage 1 (still gated by `sample_tick` itself)
    // snapshots every live signal the decision needs (window_total_snap,
    // period_valid_snap, period_timeout_snap, high_speed_mode_snap,
    // period_speed_snap) and registers the DSP48E1 multiply's output into
    // window_product_reg -- this is exact bit-sliced registration, not an
    // approximation, since bounded_count/RECIP_Q12 are unchanged, only their
    // product is now captured a cycle earlier than it's consumed. Stage 2
    // (gated by `speed_calc_pending`, one cycle later) does the threshold
    // compares and the priority mux entirely off already-registered values and
    // writes `speed`. This halves the combinational depth per cycle and removes
    // the DSP48E1 multiply from the same path as the downstream compares/mux.
    //
    // This adds exactly one extra clock (10ns) of latency between `sample_tick`
    // and `speed` updating -- against this module's 100Hz/10ms sample period
    // (1,000,000 cycles at 100MHz) that is a 0.001% latency increase, functionally
    // invisible. The one real consumer risk was fourier_motor_control.v's
    // `pid_start`, which used to fire on the exact same edge `speed` updated
    // (both driven directly off `sample_tick`); that assumption no longer holds
    // with the extra stage, so a new `speed_valid` handshake output (pulses the
    // cycle `speed` actually holds its new value, mirroring the busy/done style
    // already used by pid_fixed.v and unsigned_divider) was added and
    // fourier_motor_control.v now gates `pid_start` on `speed_valid` instead of
    // `sample_tick` directly -- see the comment there. Verified bit-exact and
    // regression-clean via the full XSim run (see HANDOFF.md for the run log).
    // (* ASYNC_REG="TRUE" *): 비동기 입력(encoder_a)을 2단 플립플롭으로 동기화.
    // 외부에서 들어오는 신호는 이 FPGA의 클럭과 아무 관계없이 아무 때나
    // 바뀔 수 있어서, 레지스터가 값이 바뀌는 그 순간에 딱 걸리면
    // "메타스테이블(준안정, 0도 1도 아닌 애매한 전압)" 상태에 빠질 위험이
    // 있습니다. 2단(sync[0]->sync[1])을 거치게 하면 메타스테이블이 첫
    // 단에서 해소될 시간을 벌어줘서 두 번째 단부터는 안전하게 씁니다.
    // 이 프로젝트 전체에서 외부 신호를 받을 때 반복되는 표준 패턴입니다.
    // ASYNC_REG 속성은 Vivado에게 "이 두 레지스터는 동기화용이니 배치를
    // 서로 가깝게 하고 리타이밍 최적화로 흩트리지 말라"고 알려줍니다.
    (* ASYNC_REG="TRUE" *) reg [1:0] sync;
    reg previous,have_edge,period_valid,high_speed_mode;
    reg [31:0] window_count,period_count,period_divisor;
    reg [12:0] period_speed;
    reg divider_start;
    wire divider_busy,divider_done;
    wire [31:0] divider_quotient;
    reg [33:0] window_product_reg;   // 1단계에서 등록해두는 DSP48E1 곱셈 결과(타이밍 분할용)
    reg [32:0] window_total_snap;    // 1단계 스냅샷: 이번 판단 시점의 window_total
    reg period_valid_snap,period_timeout_snap,high_speed_mode_snap;
    reg [12:0] period_speed_snap;
    reg speed_calc_pending;          // "1단계 끝났고, 2단계(실제 speed 계산) 차례"를 알리는 플래그

    // 동기화된 신호(sync[1])가 직전 클럭 값(previous)과 다르면서 지금 1이면
    // "방금 0->1로 올라간 엣지"라는 뜻 — 그게 펄스 하나가 들어왔다는 신호.
    assign pulse=sync[1]&&!previous;
    // 이번 window 동안 지금까지 센 펄스 수(window_count)에, 이번 클럭에
    // 새로 펄스가 들어왔으면(pulse) 1을 더 얹은 "지금 이 순간의 총합".
    wire [32:0] window_total={1'b0,window_count}+pulse;
    // 위에서 설명한 "나눗셈을 곱셈으로 바꾸는" 트릭의 상수. 2^24를
    // COUNTS_FULL_SCALE로 나눈 값(반올림).
    localparam integer RECIP_Q12=(16777216+(COUNTS_FULL_SCALE/2))/COUNTS_FULL_SCALE;
    // window_total이 COUNTS_FULL_SCALE(설계상 "이 이상이면 확실히 고속"인
    // 상한선)을 넘으면 그냥 상한으로 고정(포화) — 카운터가 계속 커져도
    // 곱셈 결과가 불필요하게 커지는 걸 막는다.
    wire [12:0] bounded_count=(window_total>=COUNTS_FULL_SCALE)?
        COUNTS_FULL_SCALE:window_total[12:0];
    wire [33:0] window_product=bounded_count*RECIP_Q12; // DSP48E1 한 클럭짜리 곱셈
    // Stage-2 speed estimate: built from the registered snapshot/product only,
    // never from the live window_total/window_product wires above (those are
    // only used to feed the stage-1 snapshot registers now).
    // window_product_reg[24:12]: 곱셈 결과를 12비트 오른쪽으로 밀어서
    // Q12(0~4096=0~100%) 스케일로 맞춘다(위 "역수를 미리 곱하는" 설명 참고).
    wire [12:0] window_speed_pipelined=(window_total_snap>=COUNTS_FULL_SCALE)?
        13'd4096:window_product_reg[24:12];

    // SPEED_NUMERATOR: A방식(window count)과 B방식(reciprocal)이 "정확히
    // 같은 크로스오버 지점에서 같은 속도값(4096=풀스케일)"을 내도록 맞춘
    // 보정 상수. 이게 없으면 두 방식을 전환할 때 speed 값이 뚝 끊기는
    // 계단현상이 생길 수 있다.
    localparam [63:0] SPEED_NUMERATOR_64=
        (64'd4096*CLK_HZ)/(COUNTS_FULL_SCALE*SAMPLE_HZ);
    localparam [31:0] SPEED_NUMERATOR=SPEED_NUMERATOR_64[31:0];
    localparam integer TIMEOUT_CLOCKS=(CLK_HZ/1000)*TIMEOUT_MS; // TIMEOUT_MS를 클럭수로 환산
    wire [31:0] measured_period=period_count+1'b1; // 방금 막 끝난 펄스 구간의 길이(클럭수)
    // 나눗셈기 결과(divider_quotient)도 4096으로 포화(같은 이유로 상한 고정)
    wire [12:0] reciprocal_speed=(divider_quotient>=4096)?
        13'd4096:divider_quotient[12:0];

    // B방식(reciprocal)의 실제 나눗셈은 이 나눗셈기 모듈이 담당.
    // SPEED_NUMERATOR(고정 상수, 분자) / period_divisor(매번 다른 분모=측정된 주기)
    unsigned_divider divider(clk,rst,divider_start,SPEED_NUMERATOR,period_divisor,
        divider_busy,divider_done,divider_quotient);

    always @(posedge clk)begin
        divider_start<=0; // 매 클럭 기본값 0(펄스로만 잠깐 1이 됨)
        speed_valid<=0;   // speed_valid도 1클럭짜리 펄스이므로 기본 0
        if(rst)begin
            sync<=0;previous<=0;have_edge<=0;period_valid<=0;high_speed_mode<=0;
            window_count<=0;period_count<=0;period_divisor<=1;period_speed<=0;speed<=0;
            divider_start<=0;
            window_product_reg<=0;window_total_snap<=0;period_valid_snap<=0;
            period_timeout_snap<=0;high_speed_mode_snap<=0;period_speed_snap<=0;
            speed_calc_pending<=0;speed_valid<=0;
        end else begin
            // 2단 동기화 시프트 + 이전 값 기억(엣지 검출용)
            sync<={sync[0],encoder_a};previous<=sync[1];
            // 펄스 사이 시간(period_count)을 계속 세되, 오버플로우 직전(0xFFFFFFFF)
            // 이면 더 이상 증가시키지 않는다(카운터가 랩어라운드해서 갑자기
            // 작은 값이 되는 것을 방지 — "포화"의 또 다른 형태).
            if(have_edge && period_count!=32'hffffffff)period_count<=period_count+1'b1;
            if(pulse)begin
                // 새 펄스가 들어온 순간: 방금 끝난 구간의 길이로 나눗셈을 새로 건다.
                // 단, 나눗셈기가 아직 이전 계산으로 바쁘면(divider_busy) 이번엔
                // 건너뛴다 — 고속에서 나눗셈이 다음 펄스보다 느릴 수 있는 상황에
                // 대한 보호(위 배경 설명 참고).
                if(have_edge && !divider_busy)begin
                    period_divisor<=measured_period;divider_start<=1;
                end
                period_count<=0;have_edge<=1; // 이제부터 새 구간을 잰다
                if(window_count!=32'hffffffff)window_count<=window_count+1'b1; // 이번 window의 펄스 카운트 증가
            end
            if(divider_done)begin
                // 나눗셈이 끝났다 -> 방금 구한 reciprocal_speed로 필터링(스무딩)해서
                // period_speed를 갱신. 처음 한 번은 필터 없이 바로 대입(초기값 안정화).
                if(!period_valid)period_speed<=reciprocal_speed;
                else if(reciprocal_speed>=period_speed)
                    period_speed<=period_speed+((reciprocal_speed-period_speed+2)>>2); // 위로 1/4만큼 이동
                else period_speed<=period_speed-((period_speed-reciprocal_speed+2)>>2); // 아래로 1/4만큼 이동
                period_valid<=1;
            end
            if(have_edge && period_count>=TIMEOUT_CLOCKS-1)begin
                // 너무 오랫동안(TIMEOUT_MS) 새 펄스가 안 들어왔다 -> 사실상 정지 상태로
                // 간주하고 reciprocal 속도값을 무효화 + 0으로 리셋.
                period_valid<=0;period_speed<=0;
            end
            if(sample_tick)begin
                // Stage 1: unchanged window reset, plus register everything the
                // stage-2 decision needs (including the DSP48E1 multiply output)
                // exactly as it stood at this sample_tick -- so stage 2, one cycle
                // later, reproduces the identical decision the old single-cycle
                // logic would have made, just split across two registers.
                window_count<=0; // 새 window 시작 -> 카운트 리셋
                window_total_snap<=window_total;
                period_valid_snap<=period_valid;
                period_timeout_snap<=(period_count>=TIMEOUT_CLOCKS-1);
                high_speed_mode_snap<=high_speed_mode;
                period_speed_snap<=period_speed;
                window_product_reg<=window_product;
                speed_calc_pending<=1; // "다음 클럭에 2단계 계산을 하라"는 예약
            end
            if(speed_calc_pending)begin
                // Stage 2: threshold compare + priority mux, entirely off the
                // stage-1 snapshot/registered product -- no DSP multiply and no
                // live window_total/window_count in this cycle's path.
                //
                // 우선순위 멀티플렉서 (히스테리시스로 A/B 전환 시 떨림 방지):
                if(!period_valid_snap || period_timeout_snap)begin
                    // 정지 상태(타임아웃) -> 무조건 속도 0
                    speed<=0;high_speed_mode<=0;
                end else if(window_total_snap>=HIGH_COUNT_THRESHOLD)begin
                    // 확실히 고속 구간(카운트가 충분히 많음) -> window 방식 채택,
                    // 그리고 high_speed_mode를 1로 "래치"해서 기억해 둔다.
                    speed<=window_speed_pipelined;high_speed_mode<=1;
                end else if(window_total_snap<=LOW_COUNT_THRESHOLD)begin
                    // 확실히 저속 구간(카운트가 충분히 적음) -> reciprocal 방식 채택.
                    speed<=period_speed_snap;high_speed_mode<=0;
                end else if(high_speed_mode_snap)begin
                    // HIGH와 LOW 사이의 애매한 구간: 직전까지 고속 모드였다면
                    // 계속 window 방식을 유지(급전환 방지 = 히스테리시스).
                    speed<=window_speed_pipelined;
                end else begin
                    // 애매한 구간이지만 직전까지 저속 모드였다면 계속 reciprocal 유지.
                    speed<=period_speed_snap;
                end
                speed_valid<=1;        // "speed가 방금 새 값으로 확정됐다"는 1클럭 알림
                speed_calc_pending<=0; // 이번 2단계 계산 완료, 다음 sample_tick까지 대기
            end
        end
    end
endmodule
