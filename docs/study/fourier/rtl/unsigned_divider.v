// ============================================================================
// [공부용 주석 사본] fourier/rtl/unsigned_divider.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "나눗셈을 여러 클럭에 걸쳐 하는 회로"
//
// 왜 나눗셈이 하드웨어에서 특별히 어려운가?
// -----------------------------------------------------------------------
// 덧셈·뺄셈은 회로 한 줄(조합 논리)로 순식간에 끝나지만, 나눗셈은 사람이
// 손으로 필산할 때처럼 "몫의 한 자리씩 추측 → 빼보고 → 맞으면 확정" 하는
// 과정을 반복해야 합니다. 이걸 조합 논리로 한 번에 만들면 회로가 엄청나게
// 커지고 느려지므로(한 클럭 안에 신호가 통과할 시간이 모자람), 대신
// "한 클럭에 몫 1비트씩" 계산하는 방식(shift-and-subtract 알고리즘)을
// 씁니다. 32비트 나눗셈이면 32클럭이 걸리는 셈입니다.
//
// 인터페이스: busy/done 핸드셰이크
// -----------------------------------------------------------------------
// 이 모듈은 "몇 클럭 걸릴지 모르는 작업"이라서, 시작은 `start` 펄스로,
// 끝은 `done` 펄스로 알려주는 방식을 씁니다. 호출하는 쪽(예:
// encoder_speed_hybrid.v)은 `start`를 한 클럭만 세우고, `busy`가 0이 될
// 때까지(또는 `done`이 뜰 때까지) 기다렸다가 결과를 읽습니다. 이 프로젝트
// 전체에서 "시간이 걸리는 연산 블록"은 거의 다 이 busy/done 패턴을 씁니다
// (pid_fixed.v, fft64_features.v, npu_2pe.v, mpu_reg_spi.v 등).
//
// 알고리즘: 복원 나눗셈(restoring division)
// -----------------------------------------------------------------------
// 핵심 아이디어: 몫(quotient)을 1비트씩 만들어 나가는데, 매 클럭마다
//   1. 지금까지 남은 값(remainder)을 왼쪽으로 1비트 밀면서, 피제수
//      (dividend)의 다음 상위 비트를 오른쪽 끝에 끼워 넣는다
//      (`shifted_remainder = {remainder, dividend_shift의_최상위비트}`).
//   2. 이 값이 제수(divisor)보다 크거나 같으면 → 뺄 수 있다는 뜻이니
//      빼고, 몫의 이번 비트를 1로 기록한다.
//   3. 작으면 → 못 빼니까 그대로 두고, 몫의 이번 비트를 0으로 기록한다.
// 이걸 WIDTH번(예: 32번) 반복하면 몫이 완성됩니다. 사람이 손으로 나눗셈
// 필산할 때 "내려긋고 - 빼보고 - 못 빼면 0, 빼지면 몫에 1 적기"를 하는
// 것과 똑같은 원리입니다. `next_remainder`/`next_quotient`가 매 클럭
// "한 자리 진행한 결과"를 계산하는 조합 논리이고, `always` 블록이 그걸
// 레지스터에 저장하며 32번 반복합니다.
//
// divisor가 0이면?
// -----------------------------------------------------------------------
// 나누기 0은 정의되지 않으므로, `start` 시점에 바로 체크해서 quotient를
// 전부 1(모든 비트 1 = 해당 WIDTH에서 표현 가능한 최댓값)로 만들고 즉시
// done을 세웁니다. "에러를 조용히 삼키지 않고 명백히 알 수 있는 값으로
// 만든다"는 이 프로젝트 전반의 스타일과 일치합니다(예: acquire()의
// TIMING_ERROR 출력처럼).
// ============================================================================

// Iterative unsigned divider: one quotient bit per clock, no combinational / operator.
module unsigned_divider #(parameter integer WIDTH=32)(
    input wire clk,input wire rst,input wire start,
    input wire [WIDTH-1:0] dividend,input wire [WIDTH-1:0] divisor,
    output reg busy,output reg done,output reg [WIDTH-1:0] quotient);
    reg [WIDTH-1:0] dividend_shift,divisor_hold,quotient_work;
    reg [WIDTH:0] remainder;     // WIDTH+1비트: 뺄셈 도중 "음수인가"를 판단하려면 부호용 여유 비트가 필요
    reg [5:0] count;             // 지금 몇 번째 비트를 계산 중인지 세는 카운터(WIDTH<=63 가정)

    // remainder를 왼쪽으로 1비트 밀면서 dividend의 최상위 비트를 오른쪽 끝에 끼워 넣는다.
    // "다음 자리 숫자를 내려긋는다"는 손 나눗셈의 그 동작.
    wire [WIDTH:0] shifted_remainder={remainder[WIDTH-1:0],dividend_shift[WIDTH-1]};

    // 뺄 수 있는지(= 몫의 이번 비트가 1인지) 판단
    wire subtract=shifted_remainder>={1'b0,divisor_hold};

    // 뺄 수 있으면 실제로 빼고, 아니면 그대로 둔다("복원"한다 = restoring division의 그 "복원")
    wire [WIDTH:0] next_remainder=subtract?
        shifted_remainder-{1'b0,divisor_hold}:shifted_remainder;

    // 몫 레지스터도 매 클럭 왼쪽으로 밀면서 이번 비트(subtract 결과)를 오른쪽 끝에 채운다
    wire [WIDTH-1:0] next_quotient={quotient_work[WIDTH-2:0],subtract};

    always @(posedge clk)begin
        done<=0; // done은 "이 클럭에만" 켜지는 1클럭짜리 펄스이므로 매번 기본값 0으로 시작
        if(rst)begin
            busy<=0;done<=0;quotient<=0;dividend_shift<=0;divisor_hold<=0;
            quotient_work<=0;remainder<=0;count<=0;
        end else if(start && !busy)begin
            // 이미 동작 중(busy=1)일 때는 새 start를 무시한다 — "한 번에 한 작업만" 규칙.
            if(divisor==0)begin quotient<={WIDTH{1'b1}};done<=1;end // 0으로 나누기: 즉시 최댓값 반환
            else begin
                busy<=1;dividend_shift<=dividend;divisor_hold<=divisor;
                quotient_work<=0;remainder<=0;count<=0;
                // 여기서 아직 실제 계산은 시작 안 하고, 다음 클럭부터 busy 분기에서 진행됨
                // (이 클럭엔 "초기화"만 하고, 1비트째 계산은 다음 클럭에 일어난다)
            end
        end else if(busy)begin
            // dividend_shift도 매 클럭 왼쪽으로 밀어서, 다음 클럭엔 그다음 비트가 최상위에 오게 한다
            dividend_shift<={dividend_shift[WIDTH-2:0],1'b0};
            remainder<=next_remainder;quotient_work<=next_quotient;
            if(count==WIDTH-1)begin
                // 마지막(WIDTH번째) 비트까지 계산했으면 완료 — 결과를 출력 레지스터에 확정하고 종료
                quotient<=next_quotient;busy<=0;done<=1;
            end
            else count<=count+1'b1;
        end
    end
endmodule
