// ============================================================================
// [공부용 주석 사본] fourier/rtl/npu_2pe.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "FFT가 뽑아낸 4개 특징값을 입력으로 받아,
// 아주 작은 2층짜리 신경망(4→4→2)을 돌려서 '정상(0)/이상(1)'을 판정한다"
//
// 이 신경망의 구조
// -----------------------------------------------------------------------
// - 입력층: 4개 값(FFT 특징, fft64_features.v의 출력)
// - 은닉층(hidden layer): 4개 뉴런, 각각 ReLU 활성화(음수는 0으로 자름)
// - 출력층: 2개 값(logit — "정상일 점수", "이상일 점수"), 둘 중 큰 쪽이 class
// 완전연결층(fully-connected)이라 입력 4개 각각이 은닉층 4개 뉴런 모두에
// 연결되고(4×4=16개 가중치), 은닉층 4개가 출력층 2개 모두에 연결됩니다
// (4×2=8개 가중치). 이렇게 작은 신경망이라 이름이 "2pe"(2개의 MAC
// PE만으로 시분할 계산)인 것도 말이 됩니다 — 크게 병렬화할 필요가 없을
// 만큼 작습니다.
//
// mac_pe.v를 "재사용"하는 방식
// -----------------------------------------------------------------------
// `mac_pe p0(...)`, `mac_pe p1(...)`로 딱 2개의 MAC 유닛만 인스턴스화합니다.
// 하나의 물리적 곱셈기를 "은닉층 뉴런 0 계산 → 뉴런 1 계산 → 뉴런 2 계산 →
// 뉴런 3 계산 → (은닉층 다 끝나면) 출력층 0, 1 계산"처럼 여러 번 재사용
// 합니다. `group_id`(0,1,2)가 "지금 어느 뉴런 그룹을 계산 중인지"를
// 나타내는 변수입니다: group_id=0이면 은닉층 뉴런 0·1, group_id=1이면
// 은닉층 뉴런 2·3, group_id=2면 출력층 뉴런 0·1 — p0가 짝수 번째 뉴런,
// p1이 홀수 번째 뉴런을 담당하는 방식으로 2개씩 병렬 계산합니다.
//
// 가중치/편향/시프트 값은 어디서 오는가?
// -----------------------------------------------------------------------
// `$readmemh("w0.mem",w0)` 등으로 파일에서 읽어옵니다. 이 값들은 PC에서
// 파이썬으로 신경망을 학습시킨 뒤 INT8로 양자화해서 미리 만들어둔
// 파일입니다(README의 "학습: PC에서만 수행하며 FPGA는 inference만 수행"이
// 바로 이 부분입니다). `shifts[0]`은 은닉층용, `shifts[1]`은 출력층용
// 시프트 양으로, 양자화된 정수 누적값을 다시 적절한 스케일로 되돌리는 데
// 씁니다(quant 함수의 `value>>>shift` 부분).
//
// 입력을 어디서 가져오는가: `x` 신호
// -----------------------------------------------------------------------
// `x = (group_id==2) ? hidden[...] : xbuf[...]`. 은닉층 계산 중(group_id
// 0,1)에는 처음 받은 4개 특징값(`xbuf`, FFT 결과를 시작할 때 통째로
// 복사해둔 것)을 입력으로 쓰고, 출력층 계산 중(group_id==2)에는 이제 막
// 계산이 끝난 은닉층 결과(`hidden`)를 입력으로 씁니다 — 신경망의 "앞
// 층의 출력이 다음 층의 입력"이라는 원리를 그대로 하드웨어로 옮긴 것입니다.
// `wa = {group_id, index}`는 4비트 주소로, 가중치 배열(`w0`, `w1`)에서
// "지금 계산 중인 (그룹, 입력 인덱스)"에 해당하는 가중치를 뽑아내는
// 인덱스입니다.
//
// 상태 기계
// -----------------------------------------------------------------------
// - IDLE: 대기. start가 오면 입력을 `xbuf`에 복사해두고 group_id=0부터 시작
// - INIT: mac_pe의 `clear`를 한 클럭 세워서 누적값을 bias로 초기화
//   (index도 0으로 리셋)
// - MAC: mac_pe의 `enable`을 세워서 4번의 곱셈-누적을 진행(index 0~3,
//   즉 입력 4개를 다 곱해서 더함)
// - PACK: 누적이 끝난 값을 양자화(quant)해서 결과에 담음. group_id가
//   아직 2가 아니면(은닉층 계산 중이면) 결과를 `hidden`에 저장하고 다음
//   그룹(group_id+1)으로 INIT부터 다시 진행. group_id==2(출력층까지
//   끝남)면 logits와 class_id를 확정하고 완료.
//
// 양자화(quantization)와 ReLU
// -----------------------------------------------------------------------
// `quant()` 함수: 누적값을 시프트해서 스케일을 맞추고, INT8 범위(-128~127)
// 를 벗어나면 그 경계값으로 자릅니다(포화, saturate). `relu` 인자가 1이면
// (은닉층일 때) 추가로 "음수면 0으로" 자르는 ReLU까지 같이 처리합니다 —
// 출력층(group_id==2)에서는 relu를 안 씁니다(`group_id!=2`가 relu 인자로
// 전달됨), 최종 점수는 음수여도 의미가 있기 때문입니다.
//
// 최종 판정: `class_id<=(q1>q0)`
// -----------------------------------------------------------------------
// 출력층의 두 점수(q0="정상" 점수, q1="이상" 점수) 중 큰 쪽을 고르는
// 것뿐입니다. 이게 바로 소프트맥스(softmax)+argmax를 하드웨어에서 가장
// 싸게 구현하는 방법 — 어차피 "어느 쪽이 더 큰가"만 필요하다면 굳이
// 확률로 정규화할 필요 없이 점수(logit) 비교만으로 충분합니다.
// ============================================================================

module npu_2pe(input wire clk,input wire rst,input wire start,
    input wire [31:0] features,output reg busy,output reg done,
    output reg [31:0] hidden,output reg [15:0] logits,
    output reg class_id,output reg [31:0] cycles);
    localparam IDLE=0,INIT=1,MAC=2,PACK=3;
    reg [1:0] state,group_id,index;
    reg [31:0] xbuf; // 입력 4개(각 8비트)를 통째로 담아두는 버퍼 — 은닉층 계산 내내 재사용
    reg signed [7:0] w0[0:11],w1[0:11]; // 가중치: p0용 12개, p1용 12개(은닉층 4×4=16개 중 절반씩+출력층분)
    reg signed [31:0] bias[0:5];        // 편향: 은닉층 뉴런 4개 + 출력층 뉴런 2개 = 6개
    reg [7:0] shifts[0:1];              // 시프트 양: [0]=은닉층용, [1]=출력층용
    initial begin
        $readmemh("w0.mem",w0);$readmemh("w1.mem",w1);
        $readmemh("bias.mem",bias);$readmemh("shift.mem",shifts);
    end
    wire [3:0] wa={group_id,index}; // 가중치 배열 인덱스: (그룹, 이번 입력 번호)
    // 은닉층 계산 중엔 원래 입력(xbuf)을, 출력층 계산 중엔 방금 나온 은닉층 결과(hidden)를 입력으로 사용
    wire signed [7:0] x=(group_id==2)?hidden[index*8 +: 8]:xbuf[index*8 +: 8];
    wire signed [31:0] a0,a1; // p0, p1 각각의 누적 결과
    // p0는 짝수 뉴런(w0 테이블), p1은 홀수 뉴런(w1 테이블) — 2개를 동시에 계산해서 시간을 절반으로 줄임
    mac_pe p0(clk,rst,state==INIT,state==MAC,x,w0[wa],bias[group_id*2],a0);
    mac_pe p1(clk,rst,state==INIT,state==MAC,x,w1[wa],bias[group_id*2+1],a1);

    // 누적값을 시프트해서 스케일 맞추고, ReLU(옵션) + INT8 포화까지 한 번에 처리
    function [7:0] quant;
        input signed [31:0] value;input [7:0] shift;input relu;
        reg signed [31:0] q;
        begin
            q=value>>>shift;
            if(q>127)quant=8'd127;                 // 상한 포화
            else if(relu && q<0)quant=0;            // ReLU: 은닉층에서만 음수를 0으로
            else if(q< -128)quant=8'h80;            // 하한 포화
            else quant=q[7:0];
        end
    endfunction
    // 출력층(group_id==2)일 땐 relu=0(음수 점수도 그대로 유지해야 비교 의미가 있음)
    wire signed [7:0] q0=quant(a0,shifts[(group_id==2)?1:0],group_id!=2);
    wire signed [7:0] q1=quant(a1,shifts[(group_id==2)?1:0],group_id!=2);

    always @(posedge clk) begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;hidden<=0;logits<=0;class_id<=0;
            cycles<=0;group_id<=0;index<=0;xbuf<=0;end
        else begin
            if(busy)cycles<=cycles+1; // 성능 측정용: 이번 추론이 몇 클럭 걸렸는지 계속 셈
            case(state)
            IDLE: if(start)begin
                // 입력을 통째로 복사해두고(은닉층 계산 내내 재사용할 것이므로),
                // 첫 그룹(은닉층 뉴런 0,1)부터 시작
                xbuf<=features;hidden<=0;cycles<=0;busy<=1;group_id<=0;state<=INIT;
            end
            INIT: begin index<=0;state<=MAC;end // mac_pe의 clear가 이 클럭에 걸려 bias로 초기화됨
            MAC: if(index==3)state<=PACK;else index<=index+1'b1; // 입력 4개를 다 곱해 누적할 때까지 반복
            PACK: if(group_id==2)begin
                // 출력층까지 다 끝남 -> 최종 판정 확정하고 종료
                logits<={q1,q0};class_id<=(q1>q0);busy<=0;done<=1;state<=IDLE;
            end else begin
                // 은닉층 그룹 하나(뉴런 2개)가 끝남 -> hidden에 저장하고 다음 그룹으로
                hidden[group_id*16 +: 16]<={q1,q0};group_id<=group_id+1'b1;state<=INIT;
            end
            default:begin state<=IDLE;busy<=0;end
            endcase
        end
    end
endmodule
