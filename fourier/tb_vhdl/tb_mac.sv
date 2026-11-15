//------------------------------------------------------------
// TB: tb_mac
// TC1: signed INT8 전체 65,536쌍과 bias
// TC2: enable=0에서 누산값 유지
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_mac;
    reg clk = 0;
    reg rst = 1;
    reg clear = 0;
    reg enable = 0;
    reg signed [7:0] x = 0;
    reg signed [7:0] weight = 0;
    reg signed [31:0] bias = 123456;
    wire signed [31:0] acc;
    integer signed_input, signed_weight, expected_accumulator;
    mac_pe dut(
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .enable(enable),
        .x(x),
        .weight(weight),
        .bias(bias),
        .acc(acc)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    initial begin : stim_proc
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        for(signed_input = - 128; signed_input <= 127; signed_input = signed_input + 1) begin
            for(signed_weight = - 128; signed_weight <= 127; signed_weight = signed_weight + 1) begin
                clear = 1;
                enable = 0;
                x = signed_input;
                weight = signed_weight;
                @(negedge clk);
                clear = 0;
                enable = 1;
                @(negedge clk);
                expected_accumulator = 123456 + signed_input * signed_weight;
                if(acc !== expected_accumulator) begin
                    $display("TEST FAIL signed MAC %d %d", signed_input, signed_weight);
                    $finish;
                end
            end
        end
        enable = 0;
        repeat(3) begin
            @(negedge clk);
        end
        if(acc !== expected_accumulator) begin
            $display("TEST FAIL MAC hold");
            $finish;
        end
        $display("TEST PASS tb_mac 65536 signed INT8 products plus bias and hold");
        $finish;
    end

    initial begin : timeout_proc
        #5000000;
        $display("TEST FAIL timeout tb_mac");
        $finish;
    end
endmodule
