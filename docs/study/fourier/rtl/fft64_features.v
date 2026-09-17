// ============================================================================
// [공부용 주석 사본] fourier/rtl/fft64_features.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "64개의 진동 샘플(시간 영역)을 받아서 FFT로
// 주파수 성분을 뽑고, 그걸 4개 주파수 대역의 에너지 값(특징 벡터)으로
// 요약한다"
//
// FFT(Fast Fourier Transform)가 왜 필요한가?
// -----------------------------------------------------------------------
// 시간에 따라 흔들리는 진동 신호(가속도 값이 시간순으로 64개)를 그대로 보면
// "언제 얼마나 흔들렸는지"만 알 수 있습니다. 그런데 "베어링이 고장 났는지"
// 같은 판단은 보통 "몇 Hz 성분이 유독 크게 나타나는지"로 훨씬 잘 드러납니다
// (예: 특정 회전 주파수의 배음이 커진다). FFT는 시간 영역 신호를 주파수
// 영역으로 바꿔주는 수학적 변환입니다. 64개 시간 샘플을 넣으면, 64개의
// "주파수 성분"(복소수, 실수부+허수부)이 나옵니다.
//
// 왜 "라딕스-2(radix-2) DIT(Decimation In Time)" FFT인가?
// -----------------------------------------------------------------------
// FFT를 그냥 정의대로 계산하면 64개 입력에 대해 대략 64×64번의 곱셈이
// 필요합니다(느림). 라딕스-2 알고리즘은 "64개를 2개씩 묶어서 계산하고,
// 그 결과를 또 2개씩 묶어서..." 하는 식으로 분할정복을 해서 64×log2(64)
// = 64×6 = 384번 정도의 곱셈으로 줄입니다(훨씬 빠름). "DIT"는 이 분할을
// 입력(시간 영역, Time) 데이터를 미리 순서를 바꿔서(Decimation) 하는
// 방식이라는 뜻입니다 — 그래서 입력을 저장할 때 `reverse6()`로 인덱스의
// 비트 순서를 뒤집어서 저장합니다(bit-reversal, FFT의 표준 준비 단계).
//
// 나비(butterfly) 연산이 뭔가?
// -----------------------------------------------------------------------
// FFT의 핵심 계산 단위입니다. 두 개의 복소수 `a`, `b`와 회전 계수(twiddle
// factor) `w`를 받아서:
//   t = b * w                (b에 회전을 곱함)
//   새로운 a = a + t
//   새로운 b = a - t
// 를 계산합니다. 이 프로젝트에서는 `ar,ai`(a의 실수부/허수부),
// `br,bi`(b의 실수부/허수부), `wr,wi`(w의 실수부/허수부)로 나뉘어 있고,
// 복소수 곱셈 `b*w`를 실수 곱셈 4번으로 풀어서 계산합니다
// (실수부 = br*wr - bi*wi, 허수부 = br*wi + bi*wr — 이게 `real_product`,
// `imag_product`입니다). 결과를 2로 나누는 이유(`>>>1`, 원본 주석의
// "Each butterfly shifts /2")는, 매 단계마다 값이 커지는 걸 막아서 16비트
// 레지스터 안에 계속 담기게 하려는 스케일링입니다 — 6단계를 거치면
// 전체적으로 2^6=64로 나눠진 셈이라, 주석에 "final result is FFT(x)/64"라고
// 적혀 있는 것입니다.
//
// 상태 기계 단계별 정리
// -----------------------------------------------------------------------
// - IDLE: 대기, start를 기다림
// - LREQ/LWAIT/LSTORE: BRAM에서 샘플을 하나씩 읽어와서(64번 반복), 비트
//   반전된 위치에 저장(bit-reversal, 위에서 설명)
// - READ: 이번 나비 연산에 쓸 a, b, twiddle factor를 레지스터에 불러옴
// - MULT: 복소수 곱셈(b*w) 수행, 결과를 다음 클럭에 쓸 수 있게 저장
// - WRITE: 나비 연산 결과(새 a, 새 b)를 다시 배열에 써넣음. 6단계(stage)를
//   전부 돌 때까지 이 READ→MULT→WRITE를 반복(총 64/2 × 6 = 192번의 나비 연산)
// - FACC: FFT 결과를 4개 주파수 대역으로 묶어서 크기(magnitude, 실수부
//   절댓값+허수부 절댓값으로 근사)를 누적
// - FINISH: 4개 대역 합을 8비트로 양자화해서 `features`로 출력
//
// 왜 magnitude를 "|실수부|+|허수부|"로 근사하는가(진짜 크기는 sqrt(re²+im²))?
// -----------------------------------------------------------------------
// 진짜 크기(유클리드 노름)는 제곱과 제곱근이 필요해서 하드웨어가 비쌉니다.
// "맨해튼 거리"(절댓값의 합)는 훨씬 싸게 계산되면서도 상대적 크기 비교
// 목적(어느 대역이 더 큰가)에는 충분히 쓸만한 근사입니다 — 임베디드
// 신호처리에서 흔한 트레이드오프입니다.
//
// 주파수 대역 나누기: `band` 계산
// -----------------------------------------------------------------------
// `k<=6? 0 : k<=12? 1 : k<=20? 2 : 3` — FFT 결과 인덱스 k(1~31, 0번은
// DC 성분이라 제외하고 32번 이상은 대칭이라 제외)를 4개 구간으로 나눕니다.
// 이 구간이 바로 README에 나오는 "band 0(16~94Hz), band 1(109~188Hz)..."
// 같은 실제 Hz 대역에 해당합니다(샘플링 주파수에 따라 인덱스가 실제 Hz로
// 환산됨).
//
// twiddle factor 테이블은 왜 파일에서 읽어오는가?
// -----------------------------------------------------------------------
// `$readmemh("tw_re.mem", twre)`는 시뮬레이션/합성 시점에 미리 계산해둔
// cos/sin 값(회전 계수)을 텍스트 파일에서 읽어와 레지스터 배열을
// 초기화하는 Verilog 표준 방법입니다. 이 값들은 수학적으로 고정된 값이라
// (32개의 서로 다른 각도), 하드웨어에서 실시간으로 삼각함수를 계산하는
// 대신 미리 계산해서 저장해두는 "룩업 테이블(LUT)" 방식을 쓴 것입니다.
// ============================================================================

// 64-point radix-2 DIT FFT. Each butterfly shifts /2: final result is FFT(x)/64.
// Work arrays are small registers/distributed memory. Input storage is external BRAM.
module fft64_features(input wire clk,input wire rst,input wire start,
    output wire sample_en,output wire [5:0] sample_addr,input wire signed [15:0] sample_data,
    output reg busy,output reg done,output reg [31:0] features);
    localparam IDLE=0,LREQ=1,LWAIT=2,LSTORE=3,READ=4,MULT=5,WRITE=6,FACC=7,FINISH=8;
    reg [3:0] state;
    // re/im: 64개 복소수 작업 배열(FFT 계산 중간중간 계속 갱신됨).
    // twre/twim: 32개 회전 계수(twiddle factor) 테이블, 미리 계산해서 로드.
    reg signed [15:0] re[0:63],im[0:63],twre[0:31],twim[0:31];
    reg [5:0] load_index,base,j,k;
    reg [2:0] stage; // 지금 몇 번째 FFT 단계(1~6)인지

    wire [6:0] span=7'd1<<stage;     // 이번 단계에서 묶는 그룹의 크기(단계가 올라갈수록 2배씩 커짐)
    wire [5:0] half=span[6:1];        // 그룹의 절반(나비 연산에서 a와 b 사이의 거리)
    wire [5:0] ia=base+j,ib=base+j+half; // 이번 나비 연산이 다룰 두 원소의 인덱스
    wire [5:0] ti=j<<(6-stage);       // 이번 나비 연산에 쓸 twiddle factor의 인덱스

    reg signed [15:0] ar,ai,br,bi,wr,wi; // 이번 나비 연산의 a, b, w 값을 임시로 담아두는 레지스터

    // 복소수 곱셈 b*w를 실수 곱셈 4개로 전개: (br+j*bi)*(wr+j*wi) = (br*wr - bi*wi) + j*(br*wi + bi*wr)
    wire signed [31:0] pr=br*wr,pi=bi*wi,qr=br*wi,qi=bi*wr;
    wire signed [32:0] real_product={pr[31],pr}-{pi[31],pi}; // 부호 유지하며 33비트로 확장 후 뺄셈
    wire signed [32:0] imag_product={qr[31],qr}+{qi[31],qi};
    reg signed [32:0] tr,tim; // 위 곱셈 결과(스케일 조정 후)를 저장해두는 레지스터

    // 나비 연산의 덧셈/뺄셈에서, ar/ai(16비트)를 tr/tim(33비트)과 자릿수를 맞추기 위해 확장
    wire signed [33:0] ar_ext={{18{ar[15]}},ar},ai_ext={{18{ai[15]}},ai};
    wire signed [33:0] tr_ext={tr[32],tr},tim_ext={tim[32],tim};

    reg [31:0] sums[0:3]; // 4개 주파수 대역별 크기 누적 합

    // FACC 단계에서 쓰는 "크기(magnitude) 근사": |실수부| + |허수부|
    wire signed [16:0] rv={re[k][15],re[k]},iv={im[k][15],im[k]};
    wire [16:0] ra=rv[16]?-rv:rv,ma=iv[16]?-iv:iv; // 부호를 보고 음수면 뒤집어서 절댓값 만들기
    wire [17:0] mag={1'b0,ra}+{1'b0,ma};
    wire [1:0] band=(k<=6)?0:(k<=12)?1:(k<=20)?2:3; // FFT 인덱스 -> 4개 주파수 대역

    assign sample_en=(state==LREQ);
    assign sample_addr=load_index;
    initial begin $readmemh("tw_re.mem",twre);$readmemh("tw_im.mem",twim);end // 미리 계산된 회전계수 로드

    // 6비트 인덱스의 비트 순서를 뒤집는다(bit-reversal) — DIT FFT의 표준 준비 단계.
    // 예: n=0b000001(1) -> reverse6(n)=0b100000(32)
    function [5:0] reverse6;
        input [5:0] n;
        begin reverse6={n[0],n[1],n[2],n[3],n[4],n[5]};end
    endfunction

    // 34비트 값을 2로 나누고(>>>1, 산술 시프트라 부호 보존) 16비트로 포화(saturate)시킨다.
    // "포화"란 표현 가능 범위를 넘으면 그냥 잘라버리지 않고 최댓값/최솟값으로 고정하는 것 —
    // 오버플로우로 부호가 뒤집혀 완전히 엉뚱한 값이 되는 것을 막는다.
    function [15:0] sat16_half;
        input signed [33:0] v;reg signed [33:0] q;
        begin q=v>>>1;
            if(q>32767)sat16_half=16'h7fff;      // 최댓값으로 고정
            else if(q< -32768)sat16_half=16'h8000; // 최솟값으로 고정
            else sat16_half=q[15:0];end
    endfunction

    // 32비트 누적합을 8비트 특징값(0~127)으로 양자화(quantize). >>5는 스케일 조정.
    function [7:0] feature_q;
        input [31:0] v;
        begin if((v>>5)>127)feature_q=127;else feature_q=v[12:5];end
    endfunction

    always @(posedge clk) begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;features<=0;load_index<=0;stage<=1;
            base<=0;j<=0;k<=1;ar<=0;ai<=0;br<=0;bi<=0;wr<=0;wi<=0;tr<=0;tim<=0;
            sums[0]<=0;sums[1]<=0;sums[2]<=0;sums[3]<=0;end
        else case(state)
        IDLE:if(start)begin busy<=1;load_index<=0;state<=LREQ;end
        LREQ:state<=LWAIT;   // BRAM 읽기 요청을 낸 다음 클럭
        LWAIT:state<=LSTORE; // BRAM 읽기 결과가 나올 때까지 한 클럭 더 대기(BRAM 읽기 지연 보정)
        LSTORE:begin
            // 방금 읽은 샘플을 "비트 반전된 위치"에 저장(bit-reversal 준비 단계),
            // 허수부는 원래 실수 신호이므로 0으로 시작.
            re[reverse6(load_index)]<=sample_data;im[reverse6(load_index)]<=0;
            if(load_index==63)begin stage<=1;base<=0;j<=0;state<=READ;end // 64개 다 읽었으면 계산 시작
            else begin load_index<=load_index+1'b1;state<=LREQ;end        // 아직 남았으면 다음 샘플 요청
        end
        READ:begin ar<=re[ia];ai<=im[ia];br<=re[ib];bi<=im[ib];wr<=twre[ti];wi<=twim[ti];state<=MULT;end
        MULT:begin tr<=real_product>>>15;tim<=imag_product>>>15;state<=WRITE;end // Q15 스케일 되돌리기
        WRITE:begin
            // 나비 연산의 핵심: 새 a = (a+t)/2, 새 b = (a-t)/2 (앞서 설명한 /2 스케일링 포함)
            re[ia]<=sat16_half(ar_ext+tr_ext);im[ia]<=sat16_half(ai_ext+tim_ext);
            re[ib]<=sat16_half(ar_ext-tr_ext);im[ib]<=sat16_half(ai_ext-tim_ext);
            if(j==half-1)begin
                // 이번 그룹의 모든 나비 연산이 끝남 -> 다음 그룹으로
                j<=0;
                if({1'b0,base}+span>=64)begin
                    // 이번 단계(stage)의 모든 그룹이 끝남
                    base<=0;
                    if(stage==6)begin
                        // 6단계(64=2^6이므로 총 6단계)를 다 마침 -> FFT 완료, 이제 특징 추출 시작
                        k<=1;sums[0]<=0;sums[1]<=0;sums[2]<=0;sums[3]<=0;state<=FACC;
                    end
                    else begin stage<=stage+1'b1;state<=READ;end // 다음 단계로
                end else begin base<=base+span;state<=READ;end   // 같은 단계, 다음 그룹으로
            end else begin j<=j+1'b1;state<=READ;end              // 같은 그룹, 다음 나비 연산으로
        end
        FACC:begin
            // FFT 결과 인덱스 1~31을 훑으면서 해당 대역의 누적합에 크기를 더함
            sums[band]<=sums[band]+mag;if(k==31)state<=FINISH;else k<=k+1'b1;
        end
        FINISH:begin
            // 4개 대역 합을 각각 8비트로 양자화해서 32비트 하나에 패킹(1바이트씩 4개)
            features<={feature_q(sums[3]),feature_q(sums[2]),feature_q(sums[1]),feature_q(sums[0])};
            busy<=0;done<=1;state<=IDLE;
        end
        default:begin busy<=0;state<=IDLE;end
        endcase
    end
endmodule
