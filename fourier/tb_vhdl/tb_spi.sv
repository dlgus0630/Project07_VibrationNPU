//------------------------------------------------------------
// TB: tb_spi
// TC1: 1바이트 읽기/쓰기, TC2: 2바이트 순서
// TC3: reset으로 전송 중단
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_spi;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg rd = 0;
    reg read_two = 0;
    reg miso = 0;
    reg [6:0] register_address = 0;
    reg [7:0] write_data = 0;
    wire [7:0] read_byte;
    wire [15:0] read_word;
    wire busy;
    wire done;
    wire sclk;
    wire mosi;
    wire chip_select_n;
    reg [23:0] transmitted_bits;
    reg [15:0] sensor_reply = 16'h81fe;
    integer bit_count, transfer_bits;
    mpu_reg_spi #(
        .CLK_HZ(100000000),
        .SPI_HZ(5000000)
    ) dut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .rd(rd),
        .read_two(read_two),
        .addr(register_address),
        .wdata(write_data),
        .rdata(read_byte),
        .rdata16(read_word),
        .busy(busy),
        .done(done),
        .sclk(sclk),
        .mosi(mosi),
        .miso(miso),
        .cs_n(chip_select_n)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : chip_select_proc
        @(negedge chip_select_n) begin
            bit_count = 0;
            transmitted_bits = 0;
            miso = 0;
        end
    end

    always begin : mosi_capture_proc
        @(posedge sclk) if(! chip_select_n) begin
            transmitted_bits = {transmitted_bits[22:0], mosi};
            bit_count = bit_count + 1;
        end
    end

    always begin : miso_reply_proc
        @(negedge sclk) if(! chip_select_n) begin
            if(bit_count >= 8 && bit_count < transfer_bits) begin
                miso = sensor_reply[transfer_bits - 1 - bit_count];
            end
            else miso = 0;
        end
    end

    task transfer;
        input read_op, input_two;
        input [6:0] address;
        input [7:0] byte_data;
        begin
            @(negedge clk);
            rd = read_op;
            read_two = input_two;
            register_address = address;
            write_data = byte_data;
            transfer_bits = input_two ? 24 : 16;
            start = 1;
            @(negedge clk);
            start = 0;
            wait(done);
            @(negedge clk);
            if(bit_count != transfer_bits || chip_select_n !== 1 || sclk !== 0) begin
                $display("TEST FAIL SPI framing");
                $finish;
            end
            if(input_two) begin
                if(transmitted_bits !== {read_op, address, 16'd0} || read_word !== sensor_reply) begin
                    $display("TEST FAIL SPI two-byte order");
                    $finish;
                end
            end
            else if(transmitted_bits[15:0] !== {read_op, address, byte_data} || read_byte !== sensor_reply[7:0]) begin
                $display("TEST FAIL SPI single byte");
                $finish;
            end
        end
    endtask

    initial begin : stim_proc
        transfer_bits = 16;
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        transfer(1, 0, 7'h75, 0);
        transfer(0, 0, 7'h6b, 8'h01);
        transfer(1, 1, 7'h3b, 0);
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        repeat(15) begin
            @(negedge clk);
        end
        rst = 1;
        repeat(2) begin
            @(negedge clk);
        end
        if(chip_select_n !== 1 || busy !== 0 || sclk !== 0) begin
            $display("TEST FAIL SPI abort");
            $finish;
        end
        $display("TEST PASS tb_spi read/write, atomic signed sample, reset abort");
        $finish;
    end

    initial begin : timeout_proc
        #100000;
        $display("TEST FAIL timeout tb_spi");
        $finish;
    end
endmodule
