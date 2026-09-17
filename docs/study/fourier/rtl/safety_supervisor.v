// ============================================================================
// [공부용 주석 사본] fourier/rtl/safety_supervisor.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "이 프로젝트 전체의 안전 정책을 담당하는
// 핵심 모듈" — 신경망 판정 결과에 따라 경고→제한→정지 3단계로 대응하고,
// 그와 완전히 별개로 ARM(PS) 소프트웨어가 살아있는지도 감시해서, 소프트웨어가
// 죽어도 하드웨어 스스로 모터를 세울 수 있게 합니다.
//
// 이 모듈의 위치: fault_latch.v의 "발전형"
// -----------------------------------------------------------------------
// 같은 폴더의 docs/study/fourier/rtl/fault_latch.v(먼저 만들어진 더 단순한
// 버전)와 비교하면, 이 모듈은 그 아이디어를 두 방향으로 확장한 것입니다.
// 첫째, "연속 이상 판정 → 래치" 하나짜리 정책을 "1회=경고, 2회 연속=출력
// 제한, 3회 연속=완전 정지"라는 3단계 정책으로 세분화했습니다. 둘째,
// fault_latch.v에는 전혀 없던 "PS heartbeat watchdog"이라는 완전히 독립된
// 두 번째 안전 메커니즘을 추가했습니다. consec_count를 세는 로직 자체는
// fault_latch.v와 뼈대가 거의 같지만(연속 카운트, 포화, class_valid 펄스로만
// 갱신), 그 카운트를 어디서 얼마나 세분화해서 쓰는지가 달라진 것입니다.
//
// 3단계 정책: warning → derated → latched
// -----------------------------------------------------------------------
// - `warning = !latched && (consec_count>=1)`: 아직 래치되지 않았고,
//   이상 판정이 1번이라도 났으면 켜짐. "일단 주의해라"는 가장 약한 신호.
// - `derated = !latched && (consec_count>=DERATE_CONSEC)`: DERATE_CONSEC
//   (기본 2)번 연속 이상이면 켜짐 — 이 신호를 받은 하위 모듈(모터 제어기
//   쪽)이 PWM 출력을 예를 들어 25%로 제한하는 식으로 반응합니다(그 제한
//   로직 자체는 이 파일이 아니라 이 신호를 받는 쪽에 있습니다 — 이
//   모듈은 "제한하라"는 신호만 내보내는 역할).
// - `latched`: TRIP_CONSEC(기본 3)번 연속이면 완전히 걸림. 한 번 걸리면
//   `clear`가 올 때까지 절대 스스로 안 풀림(fault_latch.v와 같은 래치
//   철학). warning과 derated는 `!latched` 조건이 있어서, 이미 완전
//   정지된 뒤에는 "경고"나 "제한"이라는 중간 단계 표시가 의미 없으므로
//   자동으로 꺼집니다(더 심각한 상태가 약한 상태 표시를 가림).
// 세 신호가 `assign`으로 나온 조합 논리라는 점도 주목할 것 — consec_count
// 라는 "레지스터 하나"의 값만 보고 세 단계를 동시에 계산해내는 방식입니다.
//
// Watchdog: 왜 "소프트웨어와 무관하게 독립적으로" 동작해야 하는가
// -----------------------------------------------------------------------
// 이 프로젝트에서 가장 중요한 안전 설계 개념입니다. `heartbeat`는 ARM에서
// 돌아가는 소프트웨어(main.c)가 "나 아직 살아있고 정상 동작 중이다"라고
// 주기적으로 보내주는 신호입니다(레지스터에 값을 써서 한 클럭 pulse로
// 만들어 보낸다고 생각하면 됩니다). 이 워치독 로직은:
//   - `armed`(감시를 시작하라는 신호)가 켜진 상태에서
//   - `heartbeat`가 오면 `watchdog_count`를 0으로 리셋(=아직 안 죽었다는
//     증거를 받음)
//   - `heartbeat`가 안 오고 시간이 계속 흐르면 `watchdog_count`가 매 클럭
//     증가하다가, `WATCHDOG_CYCLES`(기본 5천만 — 100MHz 클럭 기준 0.5초)에
//     도달하면 `latched<=1; fault_cause[1]<=1;`로 **소프트웨어 개입 없이**
//     스스로 래치를 겁니다.
// 왜 이게 "독립적"이어야만 진짜 안전 설계인가? 만약 "정지 결정"을
// 소프트웨어가 내려야 한다면, 정작 소프트웨어가 무한루프에 빠지거나,
// 크래시하거나, 통신이 끊기는 바로 그 상황에서 아무도 모터를 세우지
// 못하는 역설이 생깁니다. 즉 "소프트웨어가 고장 났을 때 정지시켜야 할
// 바로 그 주체(소프트웨어)에게 정지를 맡기는" 것은 설계가 스스로 무너지는
// 셈입니다. 그래서 이 워치독은 순수하게 PL(하드웨어, FPGA 로직) 안에서만
// 카운터를 돌리고 판단하며, ARM 코드가 단 한 줄도 실행되지 않아도(전원만
// 들어와 있다면) 정확히 WATCHDOG_CYCLES만큼 지나면 스스로 정지합니다.
// 이런 "소프트웨어가 무엇을 하든 상관없이 하드웨어가 최후의 안전망 역할을
// 한다"는 설계를 fail-safe(고장 시에도 안전한 방향으로) 설계라고 부릅니다.
// 참고로 세션 메모(2026-09-16)에는 watchdog_count_out을 AXI 레지스터로
// 노출시켜서, ARM 소프트웨어를 일부러 멈춰보고 정말 약 500ms(WATCHDOG_CYCLES
// 만큼) 뒤에 래치가 걸리는지 실물 보드에서 실측 검증했던 기록이 있습니다
// — "시뮬레이션이 아니라 실제로 재현되는가"를 직접 확인한 사례입니다.
// (참고: 별도 메모에는 트립이 1.3~1.6초로 늦게 걸리고 지터가 있다는
// 미해결 이슈도 남아 있어, ILA로 추가 분석이 필요한 상태입니다.)
//
// `fault_cause`: 두 비트로 "누가 정지시켰는지" 구분
// -----------------------------------------------------------------------
// `fault_cause[0]`은 "신경망이 3연속 이상 판정을 내서" 걸린 것,
// `fault_cause[1]`은 "watchdog이 heartbeat를 못 받아서" 걸린 것을 뜻합니다.
// `watchdog_fault = fault_cause[1]`로 별도 출력까지 뽑아둔 걸 보면, 둘 중
// 어느 원인으로 정지했는지를 소프트웨어(또는 사용자)가 나중에 구분해서
// 진단할 수 있게 하려는 의도입니다 — 그냥 "멈췄다"만 아는 것보다 "왜
// 멈췄는지" 원인을 남겨두는 게 디버깅과 신뢰성 확보에 훨씬 유리합니다.
//
// `clear`가 걸렸을 때 무엇을 지우고, 무엇은 안 지우는가
// -----------------------------------------------------------------------
// `clear` 블록을 보면 `latched`, `fault_cause`, `consec_count`,
// `watchdog_count`는 모두 0으로 되돌리지만, `abnormal_count`(누적 이상
// 판정 총 횟수)는 건드리지 않습니다. 원본 주석 "Keep the lifetime abnormal
// counter until reset so software can audit prior events"가 이유를 그대로
// 말해줍니다: `clear`는 "지금 상태만 정상으로 되돌려서 다시 동작을
// 재개하겠다"는 뜻이지, "과거에 무슨 일이 있었는지 그 기록까지 지우겠다"는
// 뜻이 아닙니다. abnormal_count는 "이 장치가 지금까지 살아오면서 총 몇 번
// 이상 판정을 받았는가"라는 감사(audit)·통계 목적의 기록이라서, 진짜
// 전원을 껐다 켜는 rst가 아니면 지워지지 않도록 일부러 남겨둔 설계입니다
// (`if(abnormal_count!=16'hffff)abnormal_count<=abnormal_count+1'b1;`처럼
// 16비트 포화 처리까지 되어 있어 오버플로우로 값이 도는 일도 없습니다).
// 이런 "운영 상태(state)는 지우되 기록(log/statistics)은 남긴다"는 구분은
// 실제 산업용 안전 장비에서도 흔히 쓰이는 설계 관례입니다.
// ============================================================================

// PL-owned safety policy for the integrated vibration/motor system.
// One abnormal result raises warning, two consecutive results derate PWM,
// and three consecutive results latch the motor off.  A missing PS heartbeat
// independently latches the output off, so software cannot defeat the stop.
module safety_supervisor #(
    parameter integer TRIP_CONSEC=3,     // 완전 정지(latch)까지 필요한 연속 이상 판정 횟수
    parameter integer DERATE_CONSEC=2,   // PWM 제한(derate) 시작까지 필요한 연속 이상 판정 횟수
    parameter integer WATCHDOG_CYCLES=50000000 // heartbeat 없이 버틸 수 있는 최대 클럭 수(100MHz면 0.5초)
)(
    input wire clk,input wire rst,input wire clear,input wire armed,
    // ↑ armed: 워치독 감시를 시작할지 여부(예: 시스템이 아직 초기화 중일 땐 꺼둘 수 있음)
    input wire class_valid,input wire class_id,input wire heartbeat,
    // ↑ heartbeat: ARM 소프트웨어가 "나 살아있다"고 보내는 신호(펄스성으로 사용)
    output wire warning,output wire derated,output reg latched,
    output wire watchdog_fault,output reg [1:0] fault_cause,
    output reg [7:0] consec_count,output reg [15:0] abnormal_count,
    output wire [31:0] watchdog_count_out);
    // ↑ watchdog_count_out: 내부 워치독 카운터를 그대로 밖으로 노출(디버깅/실측용).
    //   실제로 AXI 레지스터에 연결해서, 소프트웨어를 일부러 멈춰보고 이 값이
    //   WATCHDOG_CYCLES에 도달하는 순간 정말 정지하는지 실물로 검증한 사례가 있음.
    reg [31:0] watchdog_count;

    assign warning=!latched && (consec_count>=1);
    // ↑ 아직 안 멈췄고, 이상 판정이 한 번이라도 있었으면 경고
    assign derated=!latched && (consec_count>=DERATE_CONSEC);
    // ↑ 아직 안 멈췄고, DERATE_CONSEC회 이상 연속이면 출력 제한 신호
    assign watchdog_fault=fault_cause[1];
    // ↑ 정지 원인이 "watchdog 때문"인지만 따로 뽑아서 보여줌(비트1)
    assign watchdog_count_out=watchdog_count;

    always @(posedge clk)begin
        if(rst)begin
            latched<=0;fault_cause<=0;consec_count<=0;abnormal_count<=0;watchdog_count<=0;
            // ↑ 진짜 리셋(rst)만 abnormal_count(누적 통계)까지 완전히 지운다
        end else if(clear)begin
            // SW0 OFF releases the latch and run-length state.  Keep the lifetime
            // abnormal counter until reset so software can audit prior events.
            // ↑ clear(레벨 신호, 예: 스위치 SW0을 끄는 것)는 "지금 걸린 상태"만
            //   풀어주고, abnormal_count는 그대로 둔다 — 감사/기록 목적으로
            //   과거 이력을 보존하려는 의도.
            latched<=0;fault_cause<=0;consec_count<=0;watchdog_count<=0;
        end else begin
            if(class_valid)begin
                // ↑ class_valid: 한 클럭짜리 펄스. 새 분류 결과가 나온 그 순간에만
                //   아래 로직이 동작 — fault_latch.v에서 설명한 "펄스 vs 레벨"
                //   구분이 여기서도 똑같이 적용됨.
                if(class_id)begin
                    if(abnormal_count!=16'hffff)abnormal_count<=abnormal_count+1'b1;
                    // ↑ 누적 통계 카운터. 16비트 최댓값에서 멈춰 오버플로우 방지(포화).
                    if(consec_count<TRIP_CONSEC)consec_count<=consec_count+1'b1;
                    // ↑ 연속 이상 판정 횟수. TRIP_CONSEC(3)에서 멈춰 포화.
                    if(consec_count>=TRIP_CONSEC-1)begin
                        latched<=1;fault_cause[0]<=1;
                        // ↑ 이번까지 합쳐 TRIP_CONSEC번째 연속이면 완전 정지 +
                        //   원인 비트0("신경망 판정 때문")을 세운다.
                    end
                end else consec_count<=0;
                // ↑ 정상 판정 한 번은 연속 카운트만 끊는다(래치 자체는 안 풀림).
            end

            if(!armed)watchdog_count<=0;
            // ↑ 감시가 아직 시작 안 됐으면(armed=0) 워치독 카운터를 계속 0으로 유지
            else if(heartbeat)watchdog_count<=0;
            // ↑ 소프트웨어가 살아있다는 신호를 받으면 카운터 리셋(안심하고 다시 0부터)
            else if(!latched)begin
                // ↑ 이미 래치됐으면(다른 이유로든) 워치독 카운터를 더 돌릴 필요 없음
                if(watchdog_count>=WATCHDOG_CYCLES-1)begin
                    watchdog_count<=watchdog_count;
                    // ↑ 카운터를 더 이상 증가시키지 않고 그 값에서 멈춤(오버플로우 방지)
                    latched<=1;fault_cause[1]<=1;
                    // ↑ heartbeat가 WATCHDOG_CYCLES만큼 안 왔다 — 소프트웨어와 무관하게
                    //   하드웨어 스스로 정지 + 원인 비트1("watchdog 때문")을 세운다.
                    //   이 else if 체인 전체가 class_valid/heartbeat와 완전히 독립된
                    //   별도의 always 블록 안 로직이라는 점이 "소프트웨어가 무엇을
                    //   하든 상관없이 동작한다"는 fail-safe 설계의 핵심입니다.
                end else watchdog_count<=watchdog_count+1'b1;
            end
        end
    end
endmodule
