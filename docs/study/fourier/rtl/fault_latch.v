// ============================================================================
// [공부용 주석 사본] fourier/rtl/fault_latch.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "연속으로 N번(기본 3번) 이상 판정이 나오면
// 래치(latch)를 걸어서 계속 그 상태를 기억한다" — 아주 단순한 초기 버전
// 안전 회로입니다.
//
// 이 모듈의 위치: 이 프로젝트 안전 설계의 "1세대"
// -----------------------------------------------------------------------
// docs/study/fourier/rtl/safety_supervisor.v(같은 폴더, 이후 세션에서 만든
// "최종 버전")와 비교해보면, 이 fault_latch.v는 그 아이디어의 초기 형태임을
// 알 수 있습니다. fault_latch.v는 "연속 CONSEC회 이상 → latch 정지" 딱
// 한 단계짜리 정책만 갖고 있지만, safety_supervisor.v는 여기서 한 걸음 더
// 나아가 "1회부터는 warning, 2회 연속부터는 PWM을 줄이는 derate, 3회
// 연속이어야 비로소 latch" 식으로 단계를 세분화하고, 거기에 더해 PS
// (ARM 소프트웨어)가 살아있는지 감시하는 watchdog 로직까지 독립적으로
// 얹었습니다. 즉 이 파일은 "얼마나 봐줄 것인가"를 딱 한 문턱값(threshold)
// 으로만 표현한 원형이고, safety_supervisor.v는 그걸 다단계 정책 +
// 소프트웨어 무관 워치독으로 확장한 버전이라고 보면 됩니다. 실제로 두
// 파일의 always 블록 구조(rst/clear 처리, consec_count 카운트 로직)가
// 뼈대는 거의 같다는 것도 이 발전 관계를 뒷받침합니다.
//
// 왜 "연속 3회"인가? (파일 상단 원본 주석의 배경)
// -----------------------------------------------------------------------
// 원본 주석에 "Real measurements showed isolated false positives but never
// two in a row"라고 되어 있습니다 — 실제로 실물 장비에서 측정해보니, 신경망
// 분류기가 가끔 노이즈 때문에 "이상"이라고 한 번씩 잘못 판정하는 일
// (오탐, false positive)은 있었지만, 그게 두 번 연속으로 이어진 적은
// 없었다는 뜻입니다. 그래서 "한 번 이상 판정 났다고 바로 정지"하면 오탐
// 때문에 불필요하게 멈추는 일이 잦아지고, 그렇다고 "너무 많이 봐주면"
// 진짜 이상 상황에서 정지가 늦어집니다. 실측 데이터를 근거로 "3번 연속"을
// 트립(trip) 조건으로 정한 것 — 이런 식으로 안전 문턱값을 감(feeling)이
// 아니라 실측 통계로 정하는 게 임베디드 안전 설계에서 중요한 태도입니다.
//
// 신호의 종류: "펄스(pulse)"와 "레벨(level)"의 차이
// -----------------------------------------------------------------------
// 이 프로젝트 전체에서 반복되는 중요한 개념이라 여기서 짚고 갑니다.
// - `class_valid`는 "펄스" 신호입니다: 새 분류 결과가 나온 바로 그 한
//   클럭 동안만 1이었다가 다음 클럭엔 다시 0으로 돌아갑니다. "이벤트가
//   딱 한 번 발생했다"를 알리는 용도이고, 이 always 블록도
//   `if(class_valid)begin ... end`로 "그 한 클럭에만" 카운터를 갱신합니다.
//   펄스 신호를 실수로 레벨처럼 오래 1로 켜놓으면, 카운터가 한 번의
//   이벤트를 여러 클럭에 걸쳐 여러 번 세어버리는 심각한 버그가 됩니다.
// - `clear`는 "레벨" 신호입니다: 어떤 조건(예: 사용자가 스위치를 누르고
//   있는 동안)이 유지되는 동안 계속 1로 켜져 있는 신호입니다. 그래서
//   `if(rst || clear)`처럼 매 클럭 계속 검사해도 괜찮고, 오히려 "그
//   레벨이 켜져 있는 동안 계속 latched를 0으로 강제한다"는 의도를 그대로
//   구현한 것입니다(레벨이 꺼지기 전까지는 다시 래치가 걸릴 수 없음).
// 요약하면: 펄스는 "한 클럭짜리 이벤트 알림"이라 `if(pulse)`로 그 순간만
// 잡아채야 하고, 레벨은 "지속되는 상태"라 계속 검사해도(오히려 그래야)
// 맞는 동작입니다. Verilog 기초 문법 자체는 docs/study/README.md를
// 참고하세요.
//
// consec_count가 "포화(saturate)"하는 이유
// -----------------------------------------------------------------------
// `if(consec_count<CONSEC)consec_count<=consec_count+1'b1;` — 카운터가
// CONSEC(기본 3)에 도달하면 더 이상 증가시키지 않습니다. 8비트 레지스터라
// 이상 상태가 아주 오래 지속되면 255에서 0으로 넘어가는(wrap-around) 일이
// 이론적으로 가능한데, 그러면 `consec_count>=CONSEC-1` 비교가 다시
// 거짓이 되어 오히려 래치 조건을 놓칠 수 있습니다. 문턱값에서 카운트를
// 멈춰두면 그런 오버플로우 위험 자체가 없어집니다.
// ============================================================================

// Latches a fault after CONSEC consecutive abnormal classifications.
// Real measurements showed isolated false positives but never two in a row,
// so three consecutive abnormal windows is the trip condition.
module fault_latch #(parameter integer CONSEC=3)(
    input wire clk,input wire rst,
    input wire class_valid,   // one-cycle pulse: a new classification is ready
    // ↑ 한 클럭짜리 펄스: "새 분류 결과가 방금 나왔다"는 이벤트 알림. 계속 1이 아님.
    input wire class_id,      // 1 = abnormal
    // ↑ 이번 판정이 정상(0)인지 이상(1)인지. class_valid가 1인 그 클럭에서만 의미 있음.
    input wire clear,         // level; clears both the latch and the counter
    // ↑ 레벨 신호: 켜져 있는 동안 계속 래치와 카운터를 0으로 강제(초기화 유지).
    output reg latched,output reg [7:0] consec_count);
    always @(posedge clk)begin
        if(rst || clear)begin latched<=0;consec_count<=0;end
        // ↑ rst(전원/리셋)나 clear(레벨, 예: 스위치 OFF) 둘 중 하나라도 켜져 있으면
        //   무조건 초기 상태로. 최우선순위 조건.
        else if(class_valid)begin
            // ↑ 펄스가 뜬 "바로 그 클럭"에만 아래 로직이 동작. 한 번의 분류 결과를
            //   정확히 한 번만 카운트에 반영하기 위함.
            if(class_id)begin
                // Count saturates at CONSEC so a long abnormal run cannot wrap.
                // ↑ CONSEC(3)에서 카운트를 멈춰 8비트 레지스터가 넘쳐서(255→0)
                //   래치 조건을 놓치는 일이 없도록 함(포화 카운터).
                if(consec_count<CONSEC)consec_count<=consec_count+1'b1;
                if(consec_count>=CONSEC-1)latched<=1;
                // ↑ 이번까지 합쳐서 CONSEC번째 연속 이상 판정이면(카운트가 아직
                //   갱신 전이므로 CONSEC-1과 비교) 래치를 건다.
            end
            // A normal window only breaks the run; the latch itself survives
            // until clear (or rst) releases it.
            // ↑ 정상 판정 한 번은 "연속 카운트"만 0으로 끊을 뿐, 이미 걸린 래치
            //   자체는 절대 스스로 안 풀림 — 오직 clear/rst로만 풀림. 이게
            //   "래치(한 번 걸리면 유지)"라는 이름의 핵심 동작입니다.
            else consec_count<=0;
        end
    end
endmodule
