// ============================================================================
// [공부용 주석 사본] fourier/rtl/pid_fixed.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "목표 속도(reference)와 실제로 측정된 속도
// (measured)의 차이를 보고, 모터에 얼마만큼의 힘(duty, PWM 듀티비)을 줄지
// 계산하는 고정소수점 PI(비례-적분) 제어기, anti-windup(적분 폭주 방지)
// 기능 포함"
//
// 배경지식: PI 제어가 뭔가? (제어이론을 전혀 모른다고 가정하고 설명)
// -----------------------------------------------------------------------
// 목표는 "모터가 목표 속도(reference)로 돌게 만드는 것"입니다. 그런데
// 모터에 "몇 % 힘으로 돌아라"(duty)라고 직접 명령해도, 부하나 마찰 때문에
// 실제로 그 속도가 나올지는 모릅니다. 그래서 매 순간(여기서는 10ms마다)
// "목표 - 실제 측정값 = error(오차)"를 계산하고, 이 오차를 보면서 duty를
// 계속 조정합니다. 이게 "피드백 제어"의 기본 아이디어입니다.
//   - P(비례, Proportional) 항: "지금 오차가 크면 클수록 더 세게 밀어준다".
//     `error에 비례하는 만큼`을 그냥 더합니다(`p_term`). 간단하고 반응이
//     빠르지만, P만 쓰면 보통 목표값에 정확히 도달하지 못하고 약간 못
//     미친 상태(정상상태 오차, steady-state error)에서 멈춰버리는 경향이
//     있습니다(마찰 등으로 "딱 그 정도 힘까지만 밀면 더 안 움직이는"
//     지점에서 균형이 맞아버리기 때문).
//   - I(적분, Integral) 항: "오차가 계속 남아있다면(0이 아니라면), 그
//     오차를 시간에 걸쳐 계속 더해(누적해) 나간다". `integral`이 이
//     누적값입니다. 오차가 계속 존재하는 한 이 값은 계속 커지고, 그만큼
//     duty도 계속 더 커져서 결국 오차를 0으로 밀어붙입니다 — P만으로는
//     못 없애는 정상상태 오차를 I가 없애줍니다.
// 이 모듈은 D(미분, Derivative) 항도 계산은 하지만(`derivative`,
// `filter_value` — 측정값의 변화율을 저역통과 필터로 부드럽게 만든 것)
// 실제 duty 계산(OUTPUT_ADD/OUTPUT_SUB)에서는 `output_value=output_sum-
// d_term`을 하는데 `d_term`은 PRODUCTS 상태에서 `0`으로 고정되어 있어서
// (`d_term<=0;`), 사실상 이 구현은 "PI 제어기"로만 동작합니다(D항은
// 배선만 있고 게인이 곱해지지 않음 — 향후 확장 여지로 남겨둔 것으로 보임).
//
// anti-windup이 왜 필요한가? — "windup(와인드업)" 현상 쉽게 설명
// -----------------------------------------------------------------------
// I항(적분)은 "오차가 남아있는 한 계속 누적된다"고 했는데, 문제는 duty에는
// 물리적 한계가 있다는 것입니다(0~4096, 즉 0~100%). 만약 목표 속도가
// 순간적으로 크게 확 바뀌어서 아주 큰 오차가 생기면(예: 정지→최고속
// 급가속 명령), duty는 이미 물리적 최댓값(100%)에 도달해서 더 이상 힘을
// 못 주는 상태인데도 `integral`(적분 누적값)은 계속 쌓이고 또 쌓입니다
// (수학적으로는 "더 세게 밀어야 한다"고 계속 계산하니까). 그러다 마침내
// 실제 속도가 목표에 가까워져서 오차가 줄어들거나 음수로 바뀌어도,
// 그동안 쌓인 integral이 너무 커서(과도하게 쌓인 "부채") 그걸 다 갚기
// 전까지는 duty가 계속 높게 유지되어, 모터가 목표를 한참 지나쳐서까지
// 계속 가속하는(오버슈트, overshoot) 현상이 벌어집니다. 이게 "적분
// 항이 풍선처럼 부풀어 오른다(wind up)"고 해서 windup이라 부릅니다.
// anti-windup은 이걸 막는 안전장치입니다: `reject_update` 신호가
// "이미 duty가 최댓값(4096) 근처인데 오차가 여전히 같은 방향(양수)으로
// 더 밀고 있다" 또는 "이미 duty가 최솟값(0) 근처인데 오차가 여전히 같은
// 방향(음수)으로 더 당기고 있다"는 상황을 감지하면, 그 클럭에는 새로운
// integral 값(`candidate`)을 반영하지 않고 이전 값을 그대로 유지
// (`chosen_i=reject_update?integral:candidate`)합니다 — "이미 한계에
// 부딪혀서 더 밀어봐야 소용없는 방향으로는 적분을 더 쌓지 않는다"는
// 뜻입니다. `anti_windup_enable` 입력으로 이 보호를 꺼서 "안전장치 없는
// 순수 PI가 얼마나 오버슈트하는지"를 일부러 시연해볼 수도 있게 되어
// 있습니다(교육/데모 목적으로 보입니다).
//
// kp_gain / ki_gain이 오늘 하드코딩에서 AXI 런타임 입력으로 바뀐 이유
// -----------------------------------------------------------------------
// 원래대로면 Kp(비례 게인), Ki(적분 게인)는 Verilog 코드 안에 상수로
// 박아 넣고 다시 합성(synthesis)해야 값을 바꿀 수 있습니다. 그런데 이
// 게인 값은 시스템 식별(system identification, 실제 모터의 물리적 특성을
// 측정해서 수학 모델로 만드는 작업)을 통해 "이론적으로 계산된 최적값"과,
// 손으로 튜닝한 "기존 값"을 서로 비교해보고 싶을 때가 많습니다. 매번
// 값을 바꿀 때마다 몇 분씩 걸리는 재합성을 기다리면 실험 속도가 너무
// 느려지므로, `kp_gain`/`ki_gain`을 AXI 레지스터로 노출해서 ARM
// 소프트웨어가 실행 중에 즉시 다른 게인 값을 써넣고 바로 A/B 비교
// (예: "기존 게인으로 5초 돌리고, 모델 기반 게인으로 5초 돌려서 반응을
// 비교")할 수 있게 만든 것입니다. 이렇게 하드코딩 상수를 런타임 레지스터
// 입력으로 바꾸는 패턴은 "설계 파라미터를 실험 변수로 승격시키는" 흔한
// FPGA 설계 관행입니다.
//
// PRODUCTS/PRODUCTS_HI 상태를 나눈 이유 (긴 원본 영어 주석을 쉽게 풀어씀)
// -----------------------------------------------------------------------
// 배경: 이 제어기는 64비트 signed 값(`i64`=현재 integral을 64비트로 부호
// 확장한 것, `e64`=error를 64비트로 부호확장한 것 등)들을 곱하고 더합니다.
// 왜 64비트씩이나 쓰는가 하면, Kp/Ki 게인(Q16, 18비트)과 error/integral
// 값을 곱하면 자리수가 아주 커질 수 있어서 중간 계산에서 값이 잘리지
// (overflow) 않게 넉넉히 64비트로 계산해두고, 마지막에 필요한 만큼만
// 잘라 쓰는 안전한 방식입니다.
//
// "캐리(carry) 전파"가 뭔가? 덧셈을 배울 때 손으로 하는 "받아올림"과
// 똑같습니다. 예를 들어 999+1을 계산할 때 1의 자리부터 더해나가면서
// 자리올림이 다음 자리로, 또 그다음 자리로 전파됩니다. 64비트 덧셈도
// 마찬가지로, 맨 아래 비트(0번)부터 맨 위 비트(63번)까지 자리올림이
// 순서대로 전파되어야 정확한 합이 나옵니다. 문제는 이 "전파"가 물리적인
// 시간이 걸린다는 것입니다 — FPGA 안의 덧셈기는 CARRY4라는 하드웨어
// 블록을 여러 개 체인으로 연결해서 만드는데, 64비트를 한 번에 더하려면
// 이 체인이 아주 길어져야 하고(원래 코드에서 13xCARRY4, 즉 CARRY4 블록
// 13개를 줄줄이 연결), 이 긴 체인을 신호가 끝까지 통과하는 데 걸리는
// 시간이 100MHz(10ns 주기)의 요구 조건을 못 맞췄습니다(합성 후 타이밍
// 리포트 기준 WNS -0.345~-0.56ns, Vivado의 여러 최적화 전략을 다 시도
// 해봐도 해결 안 됨 — 문제가 배치 문제가 아니라 이 out-of-context
// `motor` 서브블록 안의 "논리 깊이(logic depth)" 자체였기 때문입니다).
//
// 해결책: "64비트를 한 번에 더지지 말고, 32비트씩 나눠서 두 클럭에 걸쳐
// 더한다". 손으로 계산할 때 "일의 자리부터 32번째 자리까지 먼저 다 더해서
// 받아올림까지 확정한 다음, 그 받아올림 1비트를 들고 가서 33번째 자리부터
// 64번째 자리까지 마저 더한다"는 것과 같은 생각입니다.
//   - PRODUCTS 상태: 두 64비트 값의 "아래쪽 32비트"끼리만 더합니다
//     (`i_sum_lo = {1'b0,i64[31:0]} + {1'b0,shifted_i_term[31:0]}`, 33비트
//     결과 — 맨 위 비트[32]가 바로 "아래쪽에서 위로 올라가는 받아올림"
//     입니다). 이건 근사가 아니라 정확한 계산입니다: 두 2의 보수 수의
//     합에서 아래쪽 32비트는 그냥 "부호 없는 32비트 워드끼리의 합"과
//     정확히 같고, 그 합의 33번째 비트가 정확히 다음 워드로 넘어가는
//     캐리값이기 때문입니다(이진 덧셈의 수학적 성질).
//   - PRODUCTS_HI 상태: 이번엔 "위쪽 32비트"끼리 더하되, 위에서 넘어온
//     캐리(`i_sum_lo[32]`)까지 함께 더합니다(`i_sum_hi = i64[63:32] +
//     shifted_i_term[63:32] + i_sum_lo[32]`). 이렇게 상/하위를 합치면
//     (`i_candidate_full = {i_sum_hi, i_sum_lo[31:0]}`) 원래 한 번에
//     계산하려던 64비트 값과 정확히 똑같은 결과가 나오고, 이제서야
//     +-4096 범위로 자르는(clamp) 비교를 합니다.
// 두 상태 각각의 논리 깊이는 원래의 13xCARRY4보다 훨씬 얕아져서 타이밍이
// 여유롭게 맞습니다. 대신 클럭이 하나 더 필요해졌는데(10ns 추가), 이
// 컨트롤러는 10ms(1,000,000클럭)에 한 번만 도니까 이 정도 지연은 전체
// 주기에 비하면 있으나 마나 합니다. 게다가 이 모듈을 호출하는 쪽
// (fourier_motor_control.v)은 애초에 "몇 클럭 걸리는지" 세지 않고
// busy/done 핸드셰이크만 보고 기다리므로(이 프로젝트 전반에서 반복되는
// 패턴 — unsigned_divider.v 설명 참고), 클럭이 하나 늘어도 그냥 자동으로
// 안전하게 처리됩니다. 전체 XSim 회귀 테스트로 재검증했습니다(HANDOFF.md
// 참고).
// ============================================================================

// Q12 per-unit PI, Ts=10 ms. All negative divisions round toward -infinity.
// kp_gain (Q16 Kp) and ki_gain (Q16 Ki*Ts) are runtime inputs driven from AXI so a
// system-identified model-based gain set can be A/B compared against the original
// tuning without a resynthesis; anti_windup_enable similarly lets the caller
// disable the reject_update clamp to demonstrate naive-PI windup on demand.
module pid_fixed(input wire clk,input wire rst,input wire start,
    input wire [12:0] reference,input wire [12:0] measured,
    input wire signed [17:0] kp_gain,input wire signed [17:0] ki_gain,
    input wire anti_windup_enable,
    output reg busy,output reg done,output reg [12:0] duty,
    output reg signed [31:0] integral,output reg signed [17:0] derivative);
    // The controller runs once per 10 ms.  Split the anti-windup arithmetic
    // across clock cycles so every registered path meets the 100 MHz board clock.
    //
    // PRODUCTS/PRODUCTS_HI split (added when closing timing on the watchdog-count
    // build): the original single-cycle PRODUCTS state computed
    // i_candidate = i64 + ((3932*e64)>>>16) -- a signed 64-bit add -- and then, in
    // that same cycle, compared the raw sum against +-4096 and registered the
    // clamped/unclamped result into `candidate`.  Post-route this had WNS=-0.345ns
    // to -0.56ns depending on strategy: 15 logic levels (13xCARRY4 + 2 LUT) from the
    // i_candidate1 DSP's registered multiply output through the 64-bit add and the
    // clamp compare into candidate_reg[24].  Four Vivado strategy/AggressiveExplore
    // attempts (Flow_PerfOptimized_high/RETIMING, Performance_ExtraTimingOpt, ...)
    // could not close it because the bottleneck is logic depth inside this
    // out-of-context `motor` boundary, not placement.
    //
    // Fix: split the 64-bit add into two 32-bit adds pipelined across two states.
    // PRODUCTS registers the low 32 bits of the sum plus the carry into bit 32
    // (i_sum_lo, a plain 33-bit unsigned add of the two operands' low words --
    // this is exact bit-sliced binary addition, not an approximation: the low
    // 32 bits of any two's-complement sum equal the unsigned sum of the low
    // 32-bit words, and bit 32 of that unsigned sum is exactly the carry into the
    // next word). PRODUCTS_HI then adds the two operands' high words plus that
    // carry-in (i_sum_hi), reassembles the exact original 64-bit i_candidate value,
    // and only then performs the +-4096 clamp compare into `candidate`. Both new
    // per-cycle logic depths are far short of the 13xCARRY4 original, and the extra
    // state costs one more 10 ns clock cycle out of the controller's 10 ms period
    // (1,000,000 cycles) -- functionally invisible. Downstream consumers
    // (fourier_motor_control.v) only ever poll the busy/done handshake, never a
    // fixed cycle count, so the added latency is safe by construction; verified by
    // re-running the full XSim regression (see HANDOFF.md for the run log).
    //
    // 상태 목록: IDLE(대기) -> FILTER(D항 필터) -> PRODUCTS/PRODUCTS_HI(적분
    // 후보값 계산, 위에서 설명한 32+32비트 분할) -> PROPOSE_ADD/SUB(anti-windup
    // 판단용 "만약 이 integral을 쓴다면" duty 미리 계산) -> SELECT(anti-windup
    // 최종 판단, integral 확정) -> OUTPUT_ADD/SUB(최종 duty 계산) -> CLAMP
    // (0~4096 범위로 자름) -> FINISH(완료, busy/done 갱신) -> IDLE.
    // 여러 상태로 잘게 쪼갠 이유는 전부 "한 클럭 안의 계산량을 줄여 타이밍을
    // 맞추기 위함"으로, 이 파일과 encoder_speed_hybrid.v에서 반복되는 주제입니다.
    localparam IDLE=0,FILTER=1,PRODUCTS=2,PRODUCTS_HI=3,PROPOSE_ADD=4,PROPOSE_SUB=5,
        SELECT=6,OUTPUT_ADD=7,OUTPUT_SUB=8,CLAMP=9,FINISH=10;
    reg [3:0] state;
    reg signed [17:0] error;              // 이번 사이클의 오차 = reference - measured
    reg [12:0] y_hold,y_previous;         // 미분항 필터용: 이번/직전 측정값
    reg signed [31:0] p_term,d_term,candidate; // P항, D항(현재 0으로 고정), 적분 후보값
    reg signed [31:0] proposed_sum,proposed_value,selected_i; // anti-windup 판단용 중간값들
    reg signed [31:0] output_sum,output_value; // 최종 duty 계산용 중간값
    reg [32:0] i_sum_lo;                  // PRODUCTS/PRODUCTS_HI 분할의 "아래쪽 32비트 + 캐리"
    // 각 신호를 64비트로 부호확장(sign-extend). MSB를 반복해서 채우는 방식
    // ({{46{error[17]}},error} 처럼 부호비트를 46번 복사)으로, 값의 크기는
    // 그대로 두고 비트폭만 넓히는 표준적인 Verilog 관용구입니다 — 넓은
    // 비트폭끼리 연산해야 중간에 넘치지(overflow) 않기 때문.
    wire signed [63:0] e64={{46{error[17]}},error};
    wire signed [63:0] df64={{46{derivative[17]}},derivative};
    wire signed [63:0] i64={{32{integral[31]}},integral};
    wire signed [63:0] kp64={{46{kp_gain[17]}},kp_gain};
    wire signed [63:0] ki64={{46{ki_gain[17]}},ki_gain};
    // D항(미분)의 저역통과 필터 계산식. 3*df64(직전 미분값에 가중치)+
    // 측정값의 변화(y_hold-y_previous)를 더한 뒤 4로 나눔(>>>2) — 간단한
    // IIR 필터로, encoder_speed_hybrid.v의 period_speed 필터와 같은 발상
    // (급격한 변화를 그대로 쓰지 않고 부드럽게 만듦). 실제로는 derivative가
      // 최종 duty 계산에 게인 없이(d_term=0으로 고정) 반영되므로 현재는
    // 사실상 미사용 상태(향후 D항 활성화를 위한 배선만 존재).
    wire signed [63:0] filter_value=(64'sd3*df64+$signed({1'b0,y_hold})-$signed({1'b0,y_previous}))>>>2;
    // Same multiply/shift as before; only the final add+compare is now pipelined.
    // I항 계산: Ki(Q16) * error를 곱한 뒤 16만큼 산술 우측 시프트(>>>16)해서
    // 스케일을 되돌림(Q16 고정소수점의 표준적인 "곱한 뒤 시프트로 스케일
    // 복원" 패턴 — docs/study/README.md의 Q-format 배경지식 참고).
    wire signed [63:0] shifted_i_term=(ki64*e64)>>>16;
    // PRODUCTS_HI에서 쓸 "위쪽 32비트 + 캐리" 계산 (위 긴 설명 참고)
    wire [31:0] i_sum_hi=i64[63:32]+shifted_i_term[63:32]+i_sum_lo[32];
    // 위/아래를 합쳐서 원래 한 번에 계산하려던 64비트 값을 정확히 재구성
    wire signed [63:0] i_candidate_full={i_sum_hi,i_sum_lo[31:0]};
    // anti-windup 판단: "이미 duty가 최댓값 근처(proposed_value>4096)인데
    // 오차가 여전히 양수(더 밀려는 방향)" 또는 "이미 최솟값 근처인데
    // 오차가 여전히 음수(더 당기려는 방향)"이면 새 integral 반영을 거부.
    // anti_windup_enable=0이면 이 보호 자체를 꺼서 순수 PI의 windup을
    // 그대로 재현해 보여줄 수 있다(위 배경 설명 참고).
    wire reject_update=anti_windup_enable&&(((proposed_value>4096)&&(error>0))||
        ((proposed_value<0)&&(error<0)));
    // 거부되면 integral을 이번 클럭엔 그대로 유지(candidate 반영 안 함),
    // 아니면 방금 계산한 candidate로 갱신.
    wire signed [31:0] chosen_i=reject_update?integral:candidate;
    always @(posedge clk)begin
        done<=0; // done은 1클럭짜리 완료 펄스, 매 클럭 기본값 0
        if(rst)begin state<=IDLE;busy<=0;done<=0;duty<=0;integral<=0;derivative<=0;
            error<=0;y_hold<=0;y_previous<=0;p_term<=0;d_term<=0;candidate<=0;
            i_sum_lo<=0;
            proposed_sum<=0;proposed_value<=0;selected_i<=0;
            output_sum<=0;output_value<=0;end
        else case(state)
        IDLE:if(start)begin
            // 오차 계산: 둘 다 13비트 unsigned 입력이므로, 뺄셈에서 음수가
            // 나올 수 있게 먼저 1비트를 덧붙여 signed로 만든 뒤 뺌
            // ({1'b0,reference}처럼 부호 없는 값을 signed 문맥에 안전하게
            // 넣는 관용구).
            error<=$signed({1'b0,reference})-$signed({1'b0,measured});
            y_hold<=measured;busy<=1;state<=FILTER;
        end
        FILTER:begin derivative<=filter_value[17:0];y_previous<=y_hold;state<=PRODUCTS;end
        PRODUCTS:begin
            // P항: Kp*error를 Q16 스케일로 계산(곱한 뒤 16비트 시프트)
            p_term<=(kp64*e64)>>>16;d_term<=0; // D항은 현재 게인 없이 0으로 고정(위 설명 참고)
            // I항 후보의 "아래쪽 32비트+캐리"만 이번 클럭에 계산
            // (긴 배경 설명의 "캐리 전파" 문제를 피하기 위한 분할 1단계)
            i_sum_lo<={1'b0,i64[31:0]}+{1'b0,shifted_i_term[31:0]};
            state<=PRODUCTS_HI;
        end
        PRODUCTS_HI:begin
            // 분할 2단계: 위쪽 32비트+캐리를 더해 원래의 64비트 값을 정확히
            // 재구성한 뒤, 비로소 +-4096(Q12 풀스케일) 범위로 클램프(saturate).
            if(i_candidate_full>4096)candidate<=4096;
            else if(i_candidate_full< -4096)candidate<=-4096;else candidate<=i_candidate_full[31:0];
            state<=PROPOSE_ADD;
        end
        PROPOSE_ADD:begin proposed_sum<=p_term+candidate;state<=PROPOSE_SUB;end
        PROPOSE_SUB:begin proposed_value<=proposed_sum-d_term;state<=SELECT;end
        SELECT:begin
            // anti-windup 최종 판단: reject_update면 candidate를 버리고 기존
            // integral을 그대로 유지, 아니면 candidate로 확정 갱신.
            integral<=chosen_i[31:0];
            selected_i<=chosen_i;state<=OUTPUT_ADD;
        end
        OUTPUT_ADD:begin output_sum<=p_term+selected_i;state<=OUTPUT_SUB;end
        OUTPUT_SUB:begin output_value<=output_sum-d_term;state<=CLAMP;end
        CLAMP:begin
            // 최종 duty를 물리적으로 가능한 범위 0~4096(0~100%)으로 자름(포화).
            // 이 최종 클램프는 anti-windup과 별개로 "출력 자체"를 안전 범위 안에
            // 묶어두는 마지막 안전장치.
            if(output_value>4096)duty<=4096;
            else if(output_value<0)duty<=0;
            else duty<=output_value[12:0];
            state<=FINISH;
        end
        FINISH:begin busy<=0;done<=1;state<=IDLE;end // busy/done 핸드셰이크 완료 알림
        default:begin state<=IDLE;busy<=0;duty<=0;end // 혹시 모를 비정상 state 값에서 안전하게 복귀
        endcase
    end
endmodule
