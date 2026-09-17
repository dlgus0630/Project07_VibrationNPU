// ============================================================================
// [공부용 주석 사본] fourier/rtl/mpu_reg_spi.v
// 실제 커밋되는 원본에는 이런 상세 주석이 없습니다. 이 파일은 학습 전용입니다.
// ============================================================================
//
// 이 모듈이 하는 일 한 줄 요약: "MPU-6500/9250 가속도 센서와 SPI로 대화하는
// 하드웨어 엔진" — ARM 소프트웨어가 "레지스터 A를 읽어줘"라고 명령하면, 실제
// SPI 클럭/데이터 파형을 만들어서 센서와 통신하고 결과를 돌려줍니다.
//
// SPI(Serial Peripheral Interface)가 뭔가?
// -----------------------------------------------------------------------
// 4개 선(SCLK=클럭, MOSI=주장치→종속장치 데이터, MISO=종속장치→주장치 데이터,
// CS_N=칩 선택, active-low)으로 하는 동기 직렬 통신입니다. 이 프로젝트는
// "Mode 0"라는 SPI 방식을 씁니다: 클럭이 쉬고 있을 때 0(idle low), 클럭의
// 상승 엣지에서 데이터를 샘플링합니다. 코드에서 `sclk<=1;rx<={rx[22:0],miso};`
// (클럭을 올리면서 동시에 miso를 읽음)와 `sclk<=0;...mosi<=tx[bitcnt-1]`
// (클럭을 내리면서 다음에 보낼 비트를 준비)가 번갈아 나오는 게 바로 이
// 방식입니다.
//
// 클럭 분주(clock division): `HALF_DIV`
// -----------------------------------------------------------------------
// FPGA 내부 클럭(CLK_HZ, 예: 100MHz)은 SPI가 실제로 낼 수 있는 속도
// (SPI_HZ, 예: 1MHz)보다 훨씬 빠릅니다. 그래서 SPI 클럭 한 번(반주기)을
// 만들 때마다 내부 클럭을 `HALF_DIV`번 세고 나서야 한 번 토글합니다.
// `HALF_DIV_CALC = (CLK_HZ+SPI_DENOM-1)/SPI_DENOM` — 이건 정수 나눗셈에서
// "올림(ceiling)"을 하는 표준적인 트릭입니다(분자에 분모-1을 더하고
// 나누면, 나누어떨어지지 않을 때 자동으로 올림됩니다). 왜 올림을 쓰는가?
// SPI_HZ를 "절대 넘지 않게" 하려면, 반주기를 실제보다 조금 더 길게(느리게)
// 잡아야 안전하기 때문입니다(주석에도 "the generated clock never exceeds
// SPI_HZ"라고 명시돼 있습니다).
//
// 16비트 모드 vs 24비트 모드(read_two)
// -----------------------------------------------------------------------
// 이 센서 프로토콜은 첫 바이트가 "읽기/쓰기 + 주소", 그다음 바이트(들)가
// 실제 데이터입니다. 보통 레지스터 하나만 읽거나 쓸 때는 주소 1바이트 +
// 데이터 1바이트 = 총 16비트(`bitcnt<=5'd15`)면 됩니다. 그런데 가속도
// 센서값처럼 "16비트짜리 값 하나"를 읽어야 할 때는, 주소 1바이트 + 데이터
// 2바이트 = 총 24비트(`bitcnt<=5'd23`)가 필요하고, 이게 `read_two=1`일 때
// 쓰는 경로입니다. 왜 "atomic(원자적)"이라는 표현을 원본 주석에서
// 강조했는지 생각해보면 — 센서 내부 값이 바뀌는 도중에 상위 바이트와
// 하위 바이트를 따로따로(두 번의 통신으로) 읽으면, 그 사이에 값이 바뀌어서
// 앞뒤가 안 맞는 값을 읽을 위험이 있습니다. 한 번의 연속된 SPI 전송
// 안에서 두 바이트를 다 읽으면 이 위험이 없어집니다.
//
// 전송 시퀀스 만들기: `tx` 레지스터
// -----------------------------------------------------------------------
// `tx = {8'h00, rd, addr, wdata}` 또는 `tx = {rd, addr, 16'h0000}`처럼,
// "보낼 비트들을 미리 한 레지스터에 다 채워 넣고, MSB(가장 왼쪽 비트)부터
// 한 비트씩 내보낸다"는 방식입니다. `mosi <= tx[bitcnt-1]`이 매 클럭
// 인덱스를 하나씩 낮춰가며 다음 비트를 꺼내는 부분입니다.
//
// 상태 관리: start/busy/done의 미묘한 타이밍
// -----------------------------------------------------------------------
// `start && !busy`일 때만 새 전송을 시작합니다(이미 바쁘면 무시). 시작하는
// 그 클럭에는 아직 SPI 클럭을 토글하지 않고 "설정"만 하고, 그다음 클럭부터
// `busy` 분기로 들어가 실제 파형을 만듭니다. `bitcnt`가 0이 되는 순간(모든
// 비트를 다 주고받은 순간) `busy<=0; done<=1;`로 완료를 알립니다.
// ============================================================================

// Reused V3.1 SPI mode-0 engine; register addresses/WHO_AM_I belong to firmware.
// 16-bit mode: one register read/write. 24-bit mode: atomic two-byte read.
module mpu_reg_spi #(
    parameter integer CLK_HZ = 125000000,
    parameter integer SPI_HZ = 1000000
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire rd,          // 1=읽기, 0=쓰기
    input  wire read_two,    // 1=24비트(atomic 2바이트 읽기) 모드
    input  wire [6:0] addr,  // 센서 레지스터 주소
    input  wire [7:0] wdata, // 쓸 데이터(쓰기 모드일 때만 사용)
    output reg  [7:0] rdata, // 읽은 데이터(하위 8비트, 16비트 모드용)
    output reg  [15:0] rdata16, // 읽은 데이터(16비트 전체, 24비트 모드용)
    output reg  busy,
    output reg  done,
    output reg  sclk,
    output reg  mosi,
    input  wire miso,
    output reg  cs_n
);
    // 반주기(half period)를 몇 클럭으로 만들지 계산. "올림 나눗셈"으로
    // 실제 SPI 주파수가 SPI_HZ를 절대 넘지 않도록 보수적으로 잡는다.
    // 100MHz/1MHz 기준 예시로 63이 나와서 실제로는 약 992kHz가 된다(주석 참고).
    localparam integer SPI_DENOM = SPI_HZ*2;
    localparam integer HALF_DIV_CALC = (CLK_HZ+SPI_DENOM-1)/SPI_DENOM;
    localparam integer HALF_DIV = (HALF_DIV_CALC<1) ? 1 : HALF_DIV_CALC; // 혹시나 0이 되는 극단적 설정 방지

    reg [31:0] divcnt;     // 반주기 하나를 만들기 위한 클럭 카운터
    reg [4:0] bitcnt;      // 아직 몇 비트 더 보내야 하는지(15 또는 23부터 0까지 카운트다운)
    reg [23:0] tx;         // 보낼 비트들을 미리 채워둔 시프트 레지스터
    reg [23:0] rx;         // 받은 비트들을 채워나가는 시프트 레지스터
    reg transaction_24;    // 이번 전송이 24비트 모드였는지 기억(완료 시 rdata16 채울지 결정)

    always @(posedge clk) begin
        done <= 1'b0; // done은 1클럭짜리 펄스이므로 매번 기본으로 0에서 시작
        if(rst) begin
            busy <= 0;
            sclk <= 0;
            mosi <= 0;
            cs_n <= 1;      // idle일 땐 칩 선택 해제(active-low라 1이 "선택 안 함")
            divcnt <= 0;
            bitcnt <= 0;
            tx <= 0;
            rx <= 0;
            rdata <= 0;
            rdata16 <= 0;
            transaction_24 <= 0;
        end else if(start && !busy) begin
            // --- 새 전송 시작: 이 클럭엔 "설정"만 하고 SPI 파형은 아직 안 냄 ---
            busy <= 1;
            cs_n <= 0;      // 칩 선택 활성화(전송 시작을 센서에 알림)
            sclk <= 0;
            divcnt <= 0;
            rx <= 0;
            mosi <= rd;     // 첫 비트(읽기/쓰기 플래그)를 미리 mosi에 얹어둔다
            if(read_two) begin
                transaction_24 <= 1;
                bitcnt <= 5'd23;                      // 총 24비트를 보내야 함
                tx <= {rd,addr,16'h0000};              // 주소만 채우고 데이터 자리는 0(어차피 읽기용)
            end else begin
                transaction_24 <= 0;
                bitcnt <= 5'd15;                       // 총 16비트
                tx <= {8'h00,rd,addr,wdata};           // 상위 8비트는 미사용(패딩), 뒤에 실제 15비트 사용
            end
        end else if(busy) begin
            // --- 전송 진행 중: HALF_DIV 클럭마다 SPI 클럭을 한 번씩 토글 ---
            if(divcnt==HALF_DIV-1) begin
                divcnt <= 0;
                if(sclk==0) begin
                    // SCLK를 0->1로 올리는 엣지: Mode 0 규칙대로 "이 순간" miso를 샘플링한다
                    sclk <= 1;
                    rx <= {rx[22:0],miso}; // 시프트 레지스터에 새로 읽은 비트를 오른쪽 끝에 채움
                end else begin
                    // SCLK를 1->0로 내리는 엣지: 다음에 보낼 비트를 준비하거나, 다 끝났으면 마무리
                    sclk <= 0;
                    if(bitcnt==0) begin
                        // 모든 비트를 다 주고받았다 -> 전송 완료
                        busy <= 0;
                        cs_n <= 1;      // 칩 선택 해제
                        done <= 1;
                        rdata <= rx[7:0];                 // 마지막으로 받은 8비트(16비트 모드용)
                        if(transaction_24) rdata16 <= rx[15:0]; // 24비트 모드면 상위 16비트 전체 저장
                    end else begin
                        bitcnt <= bitcnt - 5'd1;
                        mosi <= tx[bitcnt-1'b1]; // 다음에 내보낼 비트를 tx에서 꺼내 mosi에 얹는다
                    end
                end
            end else begin
                divcnt <= divcnt + 32'd1; // 아직 반주기가 다 안 지났으면 그냥 카운트만 증가
            end
        end
        // busy도 아니고 start도 없으면(idle) 아무것도 안 하고 이전 상태 유지
    end
endmodule
