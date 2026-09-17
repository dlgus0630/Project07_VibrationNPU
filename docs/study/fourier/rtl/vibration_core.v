// ============================================================================
// [공부용 주석 사본] fourier/rtl/vibration_core.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "fft64_features와 npu_2pe를 순서대로 실행시키고,
// 결과를 듀얼포트 BRAM에 써서 ARM(PS)이 읽어갈 수 있게 만드는 상위 제어기"
//
// 왜 이 모듈이 필요한가(오케스트레이션 역할)
// -----------------------------------------------------------------------
// fft64_features와 npu_2pe는 각각 자기 할 일만 하는 부품입니다(FFT 따로,
// 신경망 따로). 이 모듈은 "① 먼저 FFT를 돌려서 특징을 뽑고, ② 그 특징을
// 신경망에 넣어서 판정을 받고, ③ 결과를 BRAM에 순서대로 써넣는다"는
// 전체 흐름을 관리하는 "지휘자" 역할입니다. 이 프로젝트 전체에서 반복되는
// 패턴 — 작은 부품들을 만들고, 그걸 조합하는 상위 모듈을 또 만드는 계층
// 구조 — 를 보여주는 좋은 예입니다.
//
// 듀얼포트 BRAM과 "포트 소유권"이라는 개념
// -----------------------------------------------------------------------
// 원본 주석의 "Owns BRAM port B from START until the final result write.
// PS owns port A."가 핵심입니다. FPGA의 BRAM(Block RAM)은 보통 포트가
// 2개라서 두 "주인"이 동시에 각자의 포트로 접근할 수 있습니다. 이
// 프로젝트에서는:
//   - 포트 A: ARM(PS)이 소프트웨어에서 직접 씀 — 원본 64개 샘플을
//     BRAM에 써넣는 것도, 최종 결과를 BRAM에서 읽어가는 것도 포트 A를
//     통해서 합니다.
//   - 포트 B: 이 vibration_core 모듈이 "계산하는 동안만" 독점합니다.
//     `start` 신호가 오면 포트 B의 소유권을 가져가서(bram_en, bram_we,
//     bram_addr를 이 모듈이 만들어냄) FFT 입력을 읽고 최종 결과를 쓴
//     다음, done이 되면 다시 손을 뗍니다.
// 이렇게 "누가 언제 어느 포트를 쓰는지"를 명확히 나누면, 두 주체(ARM
// 소프트웨어와 FPGA 하드웨어)가 서로 레이스 컨디션(같은 메모리를 동시에
// 건드려서 꼬이는 문제) 없이 안전하게 데이터를 주고받을 수 있습니다.
//
// 상태 기계: FSTART → FWAIT → NSTART → NWAIT → STORE
// -----------------------------------------------------------------------
// - IDLE: 대기
// - FSTART: fft64_features에 `start` 펄스를 한 클럭 세움
// - FWAIT: fft64_features가 끝날 때까지(`fdone`) 기다림. 끝나면 결과를
//   `features` 레지스터에 복사해두고 다음 단계(신경망)로 넘어감
// - NSTART: npu_2pe에 `start` 펄스를 세움
// - NWAIT: npu_2pe가 끝날 때까지(`ndone`) 기다림. 끝나면 결과(hidden,
//   logits, class_id)를 레지스터에 복사하고 BRAM에 쓸 준비(out_index=0)
// - STORE: 결과를 BRAM에 한 워드씩 써넣는 단계(총 11워드: 특징 4개 +
//   은닉값 4개 + logit 2개 + class_id 1개)
//
// 왜 `fen`(fft64_features의 sample_en)을 여기서도 BRAM enable에 포함시키는가?
// -----------------------------------------------------------------------
// `assign bram_en=(state==STORE)||fen;` — STORE 단계에서 결과를 쓸 때도
// BRAM이 필요하지만, FFT가 원본 샘플을 읽어올 때(fft64_features 내부의
// LREQ 상태, 그때 fen=sample_en=1)도 BRAM 포트 B가 필요합니다. 그래서
// "STORE 상태이거나, FFT가 샘플을 요청 중이거나" 둘 중 하나면 BRAM을
// 활성화합니다. 주소(`bram_addr`)도 마찬가지로 STORE 중엔 "결과를 쓸
// 주소"(256번지부터), 그 외엔 "FFT가 읽고 싶어하는 주소"(`faddr`)를
// 그대로 통과시킵니다 — 이런 "상태에 따라 여러 하위 모듈의 요청 중 하나를
// 고르는" 패턴을 멀티플렉싱(multiplexing)이라고 부릅니다.
//
// STORE 단계에서 무엇을, 어떤 순서로 쓰는가
// -----------------------------------------------------------------------
// `out_index`가 0부터 10까지(총 11개) 올라가면서, `always @(*)` 블록이
// 그때그때 알맞은 값을 골라 `bram_wdata`에 담습니다:
//   - 0~3: features의 각 8비트 조각(4개 FFT 대역 특징)
//   - 4~7: hidden의 각 8비트 조각(4개 은닉층 출력)
//   - 8: logits의 하위 바이트(부호 확장해서 32비트로)
//   - 9: logits의 상위 바이트(부호 확장)
//   - 10: class_id(0 또는 1)
// `main.c`에서 이 순서 그대로 BRAM 256번지부터 읽어서 golden.c(ARM
// 소프트웨어가 독자적으로 계산한 결과)와 하나씩 비교하는 코드
// (`run_window()`의 `for(n=0;n<4;n++)if(Xil_In32(RAM+4*(256+n))!=...)`)와
// 정확히 대응됩니다 — 하드웨어가 이 순서로 쓰고, 소프트웨어가 같은
// 순서로 읽는다는 "암묵적 계약"이 두 코드 사이에 있는 셈입니다.
// ============================================================================

// Owns BRAM port B from START until the final result write. PS owns port A.
module vibration_core(input wire clk,input wire rst,input wire start,
    output reg busy,output reg done,output reg [31:0] cycles,
    output wire [31:0] npu_cycles,output reg [31:0] features,
    output reg [31:0] hidden,output reg [15:0] logits,output reg class_id,
    output wire bram_en,output wire [3:0] bram_we,output wire [9:0] bram_addr,
    output reg [31:0] bram_wdata,input wire [31:0] bram_rdata);
    localparam IDLE=0,FSTART=1,FWAIT=2,NSTART=3,NWAIT=4,STORE=5;
    reg [2:0] state;reg [3:0] out_index; // out_index: STORE 단계에서 지금 몇 번째 워드를 쓰는 중인지
    wire fen,fdone,fbusy,nbusy; // fft64_features 쪽 핸드셰이크 신호들(F는 FFT)
    wire ndone;                  // npu_2pe 쪽 완료 신호(N은 NPU)
    wire [5:0] faddr;            // fft64_features가 읽고 싶어하는 BRAM 주소
    wire [31:0] feat,nhidden;wire [15:0] nlogits;wire nclass; // 각 하위모듈의 "출력 그 자체" 배선

    // 하위 모듈 2개를 인스턴스화 — 이 상위 모듈은 언제 start를 눌러줄지만 결정하고,
    // 실제 계산 로직은 전혀 모른다(캡슐화). state==FSTART인 그 한 클럭만 fft에 start가 감.
    fft64_features fft(clk,rst,state==FSTART,fen,faddr,bram_rdata[15:0],fbusy,fdone,feat);
    npu_2pe npu(clk,rst,state==NSTART,features,nbusy,ndone,nhidden,nlogits,nclass,npu_cycles);

    // BRAM 포트 B를 누가 쓰는지 결정(멀티플렉싱): STORE 중이거나 FFT가 샘플을 요청 중이면 활성화
    assign bram_en=(state==STORE)||fen;
    assign bram_we=(state==STORE)?4'hf:4'h0; // 쓰기는 STORE 단계에서만(그 외엔 읽기 전용)
    // STORE 중엔 "결과를 쓸 주소"(256번지+out_index), 아니면 "FFT가 읽고 싶은 주소"를 그대로 통과
    assign bram_addr=(state==STORE)?10'd256+out_index:{4'd0,faddr};

    // STORE 단계에서 지금 몇 번째 워드를 쓰는지에 따라 알맞은 값을 고르는 조합 논리(멀티플렉서)
    always @(*)begin
        bram_wdata=0;
        if(out_index<4)bram_wdata={24'd0,features[out_index*8 +: 8]};      // FFT 특징 4개
        else if(out_index<8)bram_wdata={24'd0,hidden[(out_index-4)*8 +: 8]}; // 은닉층 출력 4개
        else if(out_index==8)bram_wdata={{24{logits[7]}},logits[7:0]};     // logit[0], 부호확장
        else if(out_index==9)bram_wdata={{24{logits[15]}},logits[15:8]};   // logit[1], 부호확장
        else bram_wdata={31'd0,class_id};                                   // 최종 판정
    end

    always @(posedge clk)begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;cycles<=0;features<=0;hidden<=0;logits<=0;class_id<=0;out_index<=0;end
        else begin
            if(busy)cycles<=cycles+1; // 이번 전체 추론이 몇 클럭 걸렸는지(성능 측정용)
            case(state)
            IDLE:if(start)begin busy<=1;cycles<=0;state<=FSTART;end
            FSTART:state<=FWAIT; // start 펄스는 1클럭만이면 충분, 다음 클럭엔 그냥 기다림
            FWAIT:if(fdone)begin features<=feat;state<=NSTART;end // FFT 완료 -> 결과 복사, 신경망 시작
            NSTART:state<=NWAIT;
            NWAIT:if(ndone)begin hidden<=nhidden;logits<=nlogits;class_id<=nclass;out_index<=0;state<=STORE;end
            STORE:if(out_index==10)begin busy<=0;done<=1;state<=IDLE;end else out_index<=out_index+1'b1;
            default:begin state<=IDLE;busy<=0;end
            endcase
        end
    end
endmodule
