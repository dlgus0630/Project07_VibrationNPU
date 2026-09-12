// Reused V3.1 SPI mode-0 engine; register addresses/WHO_AM_I belong to firmware.
// 16-bit mode: one register read/write. 24-bit mode: atomic two-byte read.
module mpu_reg_spi #(
    parameter integer CLK_HZ = 125000000,
    parameter integer SPI_HZ = 1000000
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire rd,
    input  wire read_two,
    input  wire [6:0] addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    output reg  [15:0] rdata16,
    output reg  busy,
    output reg  done,
    output reg  sclk,
    output reg  mosi,
    input  wire miso,
    output reg  cs_n
);
    // Round the divider upward so the generated clock never exceeds SPI_HZ.
    // At 125 MHz / nominal 1 MHz this selects 63 and yields about 992 kHz.
    localparam integer SPI_DENOM = SPI_HZ*2;
    localparam integer HALF_DIV_CALC = (CLK_HZ+SPI_DENOM-1)/SPI_DENOM;
    localparam integer HALF_DIV = (HALF_DIV_CALC<1) ? 1 : HALF_DIV_CALC;

    reg [31:0] divcnt;
    reg [4:0] bitcnt;
    reg [23:0] tx;
    reg [23:0] rx;
    reg transaction_24;

    always @(posedge clk) begin
        done <= 1'b0;
        if(rst) begin
            busy <= 0;
            sclk <= 0;
            mosi <= 0;
            cs_n <= 1;
            divcnt <= 0;
            bitcnt <= 0;
            tx <= 0;
            rx <= 0;
            rdata <= 0;
            rdata16 <= 0;
            transaction_24 <= 0;
        end else if(start && !busy) begin
            busy <= 1;
            cs_n <= 0;
            sclk <= 0;
            divcnt <= 0;
            rx <= 0;
            mosi <= rd;
            if(read_two) begin
                transaction_24 <= 1;
                bitcnt <= 5'd23;
                tx <= {rd,addr,16'h0000};
            end else begin
                transaction_24 <= 0;
                bitcnt <= 5'd15;
                tx <= {8'h00,rd,addr,wdata};
            end
        end else if(busy) begin
            if(divcnt==HALF_DIV-1) begin
                divcnt <= 0;
                if(sclk==0) begin
                    sclk <= 1;
                    rx <= {rx[22:0],miso};
                end else begin
                    sclk <= 0;
                    if(bitcnt==0) begin
                        busy <= 0;
                        cs_n <= 1;
                        done <= 1;
                        rdata <= rx[7:0];
                        if(transaction_24) rdata16 <= rx[15:0];
                    end else begin
                        bitcnt <= bitcnt - 5'd1;
                        mosi <= tx[bitcnt-1'b1];
                    end
                end
            end else begin
                divcnt <= divcnt + 32'd1;
            end
        end
    end
endmodule
