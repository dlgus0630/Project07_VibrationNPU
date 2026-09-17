// ============================================================================
// [공부용 주석 사본] fourier/rtl/encoder_quadrature.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "엔코더의 두 번째 채널(B상)까지 이용해서
// 회전 '방향'을 알아내고, 엔코더/배선/모터에 생길 수 있는 4가지 이상 상황
// (물리적으로 불가능한 신호 변화, 정지 상태 타임아웃, 위치 카운터 오버플로우)
// 을 감지해서 AXI로 보고하는 모듈" — 이 모듈은 오늘(2026-09-17) 새로 작성된
// 것입니다.
//
// 배경지식: quadrature(직교) 인코딩이 뭔가?
// -----------------------------------------------------------------------
// encoder_speed_hybrid.v는 채널 A 하나만 보고 "얼마나 빨리 도는지"(속도
// 크기)만 알아냈습니다. 그런데 A 하나만으로는 "어느 방향으로 도는지"는 알
// 수 없습니다(펄스가 그냥 순서대로 나오기 때문에 시계방향인지 반시계방향
// 인지 구분이 안 됨). 그래서 실제 광학/자기 엔코더는 보통 90도 위상차를
// 둔 두 번째 채널(B상)을 함께 냅니다. 두 채널을 합쳐 2비트로 보면
// {A,B}가 회전하면서 다음과 같은 "그레이 코드(Gray code)" 순서로 바뀝니다:
//   00 -> 01 -> 11 -> 10 -> 00 -> ...(정방향)
//   00 -> 10 -> 11 -> 01 -> 00 -> ...(역방향, 이 보드는 반대로 매핑됨. 아래 참고)
// 이 4단계 순환에서 "지금 상태"와 "바로 다음 상태"를 비교하면, 어느
// 방향으로 진행했는지(정방향 vs 역방향)를 알 수 있습니다 — 이것이
// quadrature 방향 판별의 핵심 원리입니다.
//
// 왜 하필 그레이 코드 순서(00,01,11,10)를 쓰는가? — "인접 상태끼리는 항상
// 1비트만 바뀐다"는 성질 때문입니다. 예를 들어 00->01은 B만 바뀌고,
// 01->11은 A만 바뀝니다. 만약 00->11처럼 A와 B가 "동시에" 바뀌는 것처럼
// 보인다면, 그건 정상적인 회전이 아니라 신호를 놓쳤거나(샘플링 타이밍이
// 안 맞음) 배선이 잘못됐다는 뜻입니다 — 물리적으로 모터 축이 도는 동안
// A와 B가 정확히 같은 순간에 동시에 토글되는 일은 있을 수 없기 때문입니다
// (두 채널은 기계적으로 위상이 어긋나 있게 만들어져 있음). 이게 아래
// "illegal_transition"(비정상 변화) 검출의 근거입니다.
//
// 이 모듈이 하는 일: 순수 관찰자(observational)
// -----------------------------------------------------------------------
// 맨 위 원본 주석에 명시되어 있듯, 이 모듈은 PI 제어 루프나 안전 감독자에
// 직접 피드백을 주지 않습니다. 그냥 방향과 고장 상태를 계산해서 AXI
// 레지스터로 내보내기만 합니다(호스트 소프트웨어가 읽어서 판단). 즉,
// "제어에 관여하지 않고 관찰만 하는" 진단 모듈입니다.
//
// state_now / moved / valid_forward / valid_backward
// -----------------------------------------------------------------------
// `state_now`는 지금 이 순간의 {A,B} 2비트 값입니다. `moved`는 "지난
// 클럭에 저장해둔 state와 지금 state_now가 다르다"는 뜻으로, 즉 "엔코더가
// 한 단계 움직였다"는 신호입니다. `valid_forward`/`valid_backward`는
// 조합 논리(always @(*), 클럭과 무관하게 즉시 계산되는 블록)로, "state ->
// state_now"로의 전이가 그레이 코드 순환에서 유효한 정방향/역방향 한 걸음
// 인지를 case문으로 검사합니다. 이 case에 없는 조합(예: 00<->11, 01<->10
// 처럼 2비트가 동시에 바뀐 것처럼 보이는 경우)은 default로 빠지며,
// valid_forward와 valid_backward가 둘 다 0으로 남습니다 — 이게 곧
// "비정상 변화"입니다.
//
// 어느 방향이 "정방향"인지는 임의 결정 — 실측으로 확정
// -----------------------------------------------------------------------
// 그레이 코드 순환 자체는 대칭이라(00->01->11->10->00과 00->10->11->01->00
// 둘 다 수학적으로는 똑같이 유효한 "한쪽 방향"입니다), 어느 쪽을
// "forward(정방향)"이라 부를지는 실제로 모터를 정방향 duty로 돌려보고
// 그때 나오는 신호 패턴을 관찰해야만 알 수 있습니다. 코드 주석에 있듯
// 2026-09-16일 이 보드의 C1/C2 배선으로 실측한 결과 00->10->11->01->00
// 순서가 실제 "정방향"이었기에, 그 case 조합이 valid_forward에 매핑되어
// 있습니다. 이건 배선을 바꾸거나 다른 엔코더를 쓰면 반대로 뒤집힐 수도
// 있는, 보드에 종속적인 상수적 사실입니다.
//
// position_wr_en / position_wr_value — 오늘 오버플로우 실물 테스트를 위해 추가
// -----------------------------------------------------------------------
// `position`은 32비트 signed 카운터라서, 정상적으로 오버플로우를 재현하려면
// 실제 엔코더 펄스가 2^31개(약 21억 개) 가까이 들어와야 합니다 — 실제
// 모터로는 현실적으로 테스트가 불가능한 숫자입니다. 그래서 AXI로 소프트
// 웨어가 `position`을 원하는 값(예: 2^31에 아주 가까운 값)으로 미리
// "프리셋"할 수 있는 기능을 추가했습니다. 그러면 그 근처에서 실제 엔코더
// 펄스 몇 개만 더 들어와도 진짜 오버플로우 경계를 실제로 통과시켜 볼 수
// 있습니다(억지로 값을 만들어서 "오버플로우 났다고 치자"가 아니라, 진짜
// 오버플로우 산술 경로를 실제로 통과시켜 검증한다는 점이 중요합니다).
// 덤으로 이 기능은 평범한 "원점 잡기(homing/zero)" 용도로도 그대로 쓸 수
// 있습니다.
//
// overflow_fwd / overflow_bwd — 32비트 signed 오버플로우를 어떻게 감지하는가?
// -----------------------------------------------------------------------
// `position`은 signed 32비트라서 표현 범위가 -2^31 ~ +2^31-1입니다.
// 정방향으로 한 걸음 갈 때마다 `position_fwd = position + 1`을 계산하는데,
// 만약 `position`이 이미 +2^31-1(최댓값)이었다면 `position_fwd`는 진짜
// 수학적으로는 +2^31이 되어야 하지만, 32비트 signed로는 표현할 수 없어서
// "랩어라운드"되어 -2^31(가장 작은 음수)이 되어버립니다. 이때 무슨 일이
// 일어나느냐면: MSB(맨 앞 비트, [31])가 부호비트인데, 양수였던 `position`
// (부호비트=0)이 `position_fwd`에서는 갑자기 부호비트=1(음수처럼 보임)로
// "이유 없이" 뒤집힙니다. 정상적인 상황(오버플로우가 아닌 보통의 +1)
// 이라면 값이 조금만 바뀌므로 부호비트가 이렇게 갑자기 뒤집힐 이유가
// 없습니다. 그래서 `overflow_fwd = (position[31]==0) && (position_fwd[31]
// ==1)` — "더하기 전엔 양수였는데, 더한 후엔 갑자기 음수로 보인다"라는
// 조건이 바로 "2의 보수(two's complement) signed 오버플로우가 일어났다"
// 는 확실한 신호입니다. `overflow_bwd`는 반대 방향(음수 최솟값에서 1을
// 뺐더니 갑자기 양수로 뒤집히는 경우)을 같은 논리로 검사합니다. 이 트릭은
// "덧셈 전후의 부호비트 변화 패턴을 보는 것"으로, 실제 값의 크기를 직접
// 비교하지 않고도(즉 2^31이라는 큰 수와 직접 비교하는 대신) 아주 싸게
// (비트 3개만 보면 됨) 오버플로우를 검출하는 고전적인 하드웨어 기법입니다.
//
// timeout_fault — 정지 감지
// -----------------------------------------------------------------------
// `enabled && duty!=0`(모터가 돌아가라는 명령을 받고 있는 상태)인데도
// 일정 시간(TIMEOUT_MS) 동안 `moved`가 한 번도 안 뜨면(엔코더가 전혀
// 움직이지 않으면), 모터가 걸렸거나(stall) 엔코더가 고장났다고 보고
// `timeout_fault`를 세웁니다. `duty==0`(정지 명령)일 때는 당연히 안
// 움직이는 게 정상이므로 타임아웃 카운터를 0으로 유지합니다(오검출 방지).
//
// illegal_transition_count — 몇 번 발생했는지도 함께 기록
// -----------------------------------------------------------------------
// fault 플래그(1비트, "지금까지 한 번이라도 있었다")뿐 아니라 발생 횟수도
// 16비트로 세어둡니다. `clear`로 fault 플래그는 지울 수 있어도 이 카운트는
// 지워지지 않는 걸로 보아(코드 확인: clear 블록에 illegal_transition_count
// 는 없음), 이건 "누적 진단 통계"로 남겨서 문제가 얼마나 자주 있었는지
// 추적하려는 의도로 보입니다. 0xFFFF에서 더 늘리지 않는 것은 다른 모듈의
// window_count/period_count와 같은 "카운터 포화" 패턴입니다.
//
// position 갱신이 방향 판정 로직과 독립적으로 처리되는 이유
// -----------------------------------------------------------------------
// 아래 코드 끝부분 주석에도 있듯, `position`을 갱신하는 if-else 체인은
// `state`를 갱신하는 로직과 분리되어 있습니다. 그래서 소프트웨어가
// `position_wr_en`으로 값을 쓰는 클럭에 마침 진짜 엔코더도 움직였다면,
// "소프트웨어가 쓴 값이 이긴다"(맨 위 우선순위)는 규칙이 명확하게
// 적용되고, 그 클럭에서 계산된 오버플로우 체크는 "쓰기 전의 원래 position"
// 값을 기준으로 이미 끝난 뒤이므로 여전히 유효합니다. 이건 드물게만
// 발생하는 경쟁 상황(race)을 "어느 쪽이 이기는지" 명시적으로 정의해서
// 처리한 것입니다.
// ============================================================================

// Quadrature direction and reliability check from encoder channels A and B.
// encoder_speed_hybrid already estimates speed magnitude from channel A alone;
// this module adds direction and three independent fault signals that a
// magnitude-only estimator cannot provide: an illegal (two-bit) Gray-code
// jump, a stall while the motor is being driven, and position-counter
// overflow. It is purely observational -- nothing here feeds back into the
// PI loop or the safety supervisor; faults are exposed on AXI for the host
// to read.
module encoder_quadrature #(
    parameter integer CLK_HZ=100000000,
    parameter integer TIMEOUT_MS=200
)(input wire clk,input wire rst,input wire clear,
    input wire enabled,input wire [12:0] duty,
    input wire encoder_a,input wire encoder_b,
    // Software preset (AXI-driven, one-cycle pulse): lets the host seed
    // position near the +-2^31 boundary so a couple of real encoder edges
    // exercise the genuine overflow arithmetic below without needing billions
    // of real pulses. Doubles as an ordinary homing/zero feature.
    // position_wr_en=1인 그 클럭에 position_wr_value로 강제로 덮어씀
    // (위 "오늘 오버플로우 실물 테스트를 위해 추가" 설명 참고).
    input wire position_wr_en,input wire signed [31:0] position_wr_value,
    output reg direction,                    // 0=정방향, 1=역방향(마지막으로 확인된 이동 방향)
    output reg signed [31:0] position,       // 누적 위치(엔코더 카운트, signed라 방향까지 반영)
    output reg illegal_transition_fault,output reg [15:0] illegal_transition_count,
    output reg timeout_fault,
    output reg overflow_fault);
    localparam integer TIMEOUT_CLOCKS=(CLK_HZ/1000)*TIMEOUT_MS; // TIMEOUT_MS -> 클럭 수 환산
    // 두 채널 모두 비동기 외부 입력이므로 각각 2단 동기화
    // (encoder_speed_hybrid.v의 sync 레지스터와 같은 이유/같은 패턴).
    (* ASYNC_REG="TRUE" *) reg [1:0] a_sync,b_sync;
    reg [1:0] state;             // 직전에 확인했던 {A,B} 상태(그레이 코드 4단계 중 하나)
    reg [31:0] timeout_count;    // 안 움직인 지 얼마나 됐는지 세는 카운터
    wire [1:0] state_now={a_sync[1],b_sync[1]}; // 지금 이 순간의(동기화된) {A,B} 상태
    wire moved=(state_now!=state);              // 직전과 다르면 "한 단계 움직였다"
    // Valid single-step Gray sequence: 00 -> 01 -> 11 -> 10 -> 00 is forward,
    // the reverse walk is backward. Any other change (00<->11 or 01<->10) is
    // a two-bit jump: physically impossible for real quadrature signals
    // sampled at 100 MHz against a mechanical encoder, so it means a missed
    // edge (aliasing/glitch) or a wiring fault.
    //
    // valid_forward/valid_backward: 클럭에 안 걸리는 조합 논리(always @(*))로
    // "state->state_now 전이가 그레이 코드상 유효한 한 걸음인지" 즉시 판정.
    reg valid_forward,valid_backward;
    always @(*)begin
        valid_forward=0;valid_backward=0; // 기본값: case에 안 걸리면(=비정상 전이) 둘 다 0으로 남음
        // Which Gray-code walk direction is "forward" is an arbitrary choice
        // until it's checked against the real motor: on this board's C1/C2
        // wiring (measured 2026-09-16 with the motor driven closed-loop at a
        // known positive duty), the 00->10->11->01->00 walk is the one that
        // actually happens, so that's the branch mapped to valid_forward here.
        //
        // 이 보드에서는(실측으로 확정) 00->10->11->01->00 순서가 "정방향".
        // {state,state_now} 4비트를 만들어서 유효한 전이 8가지(정방향 4개
        // + 역방향 4개)만 매치시키고, 나머지 조합(2비트 동시 변화 등)은
        // default로 빠져 illegal 상태로 남는다.
        case({state,state_now})
        {2'b00,2'b10},{2'b10,2'b11},{2'b11,2'b01},{2'b01,2'b00}:valid_forward=1;
        {2'b00,2'b01},{2'b01,2'b11},{2'b11,2'b10},{2'b10,2'b00}:valid_backward=1;
        default:; // 물리적으로 불가능한 전이(2비트 동시 변화) -> 아래에서 illegal fault로 처리
        endcase
    end
    // 방향별로 "만약 이번에 한 걸음 더 간다면" 될 다음 position 값을 미리 계산해 둔다.
    wire signed [31:0] position_fwd=position+32'sd1;
    wire signed [31:0] position_bwd=position-32'sd1;
    // 32비트 signed 오버플로우 검출: "더하기 전엔 양수(부호비트0)였는데
    // 더한 후 갑자기 음수(부호비트1)로 보인다" = 오버플로우가 일어났다는
    // 확실한 신호 (위 배경 설명의 "부호비트 비교" 원리 그대로).
    wire overflow_fwd=(position[31]==1'b0)&&(position_fwd[31]==1'b1);
    // 반대 방향: "빼기 전엔 음수(부호비트1)였는데 뺀 후 갑자기 양수(부호비트0)로
    // 보인다" = 최솟값 아래로 내려가는 오버플로우(언더플로우)가 일어났다는 신호.
    wire overflow_bwd=(position[31]==1'b1)&&(position_bwd[31]==1'b0);
    always @(posedge clk)begin
        if(rst)begin
            a_sync<=0;b_sync<=0;state<=0;direction<=0;position<=0;
            illegal_transition_fault<=0;illegal_transition_count<=0;
            timeout_fault<=0;overflow_fault<=0;timeout_count<=0;
        end else begin
            a_sync<={a_sync[0],encoder_a};b_sync<={b_sync[0],encoder_b}; // 2단 동기화 시프트
            if(clear)begin
                // 소프트웨어가 "확인했으니 플래그를 지워달라"고 요청 — 단, 아래에서 보듯
                // illegal_transition_count(누적 통계)는 여기서 지우지 않는다(의도적).
                illegal_transition_fault<=0;timeout_fault<=0;overflow_fault<=0;
            end
            if(moved)begin
                // 엔코더가 한 단계 움직였다 -> state 갱신 + 정지 타이머 리셋
                state<=state_now;timeout_count<=0;
                if(valid_forward)begin
                    direction<=0;
                    if(overflow_fwd)overflow_fault<=1; // fault는 한 번 세워지면 clear 전까지 유지(래치)
                end else if(valid_backward)begin
                    direction<=1;
                    if(overflow_bwd)overflow_fault<=1;
                end else begin
                    // 2비트가 동시에 바뀐 것처럼 보이는, 물리적으로 불가능한 전이
                    illegal_transition_fault<=1;
                    if(illegal_transition_count!=16'hffff) // 다른 카운터들과 같은 포화 패턴
                        illegal_transition_count<=illegal_transition_count+1'b1;
                end
            end else if(enabled && duty!=0)begin
                // 모터를 돌리라는 명령은 있는데(duty!=0) 엔코더가 안 움직임 -> 정지 의심
                if(timeout_count>=TIMEOUT_CLOCKS-1)timeout_fault<=1;
                else timeout_count<=timeout_count+1'b1;
            end else timeout_count<=0; // 애초에 정지 명령이면 타임아웃 카운트를 쌓지 않는다(오검출 방지)
            // Position update is independent of the state-tracking above so a
            // software preset never desyncs `state` from the real encoder
            // phase: a write this cycle simply wins over a move this same
            // cycle (the rare case), and the overflow checks above still ran
            // against the pre-write value, which is what a genuine move
            // arriving in the same cycle as a preset should do.
            //
            // position 갱신은 위의 state 추적 로직과 완전히 분리된 별도의
            // if-else 체인 — 그래서 소프트웨어 프리셋이 들어와도 state가
            // 실제 엔코더 위상과 어긋나지(desync) 않는다. 같은 클럭에
            // 쓰기와 실제 이동이 동시에 일어나는 드문 경우엔 "쓰기가
            // 이긴다"(맨 위 우선순위)로 명확히 정의되어 있고, 그 클럭의
            // 오버플로우 체크는 이미 "쓰기 전의 원래 position" 기준으로
            // 끝난 뒤이므로(위 always 블록 앞부분에서 계산됨) 정확하다.
            if(position_wr_en)position<=position_wr_value;
            else if(moved && valid_forward)position<=position_fwd;
            else if(moved && valid_backward)position<=position_bwd;
        end
    end
endmodule
