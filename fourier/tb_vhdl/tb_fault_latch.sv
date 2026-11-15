//------------------------------------------------------------
// TB: tb_fault_latch
// TC1: 연속 이상/정상 삽입/포화
// TC2: clear와 재발생, 유효하지 않은 입력 유지
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_fault_latch;
    reg clk = 0;
    reg rst = 1;
    reg class_valid = 0;
    reg class_id = 0;
    reg clear = 0;
    wire latched;
    wire [7:0] consec_count;
    integer element_index;
    fault_latch #(
        .CONSEC(3)
    ) dut(
        .clk(clk),
        .rst(rst),
        .class_valid(class_valid),
        .class_id(class_id),
        .clear(clear),
        .latched(latched),
        .consec_count(consec_count)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    task pulse;
        input value;
        begin
            @(negedge clk);
            class_id = value;
            class_valid = 1;
            @(negedge clk);
            class_valid = 0;
            class_id = 0;
        end
    endtask

    initial begin : stim_proc
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched !== 0 || consec_count !== 0) begin
            $display("TEST FAIL fault_latch reset state");
            $finish;
        end
        pulse(1);
        if(latched !== 0 || consec_count !== 1) begin
            $display("TEST FAIL fault_latch isolated abnormal");
            $finish;
        end
        pulse(1);
        pulse(0);
        if(latched !== 0 || consec_count !== 0) begin
            $display("TEST FAIL fault_latch broken run");
            $finish;
        end
        pulse(1);
        if(latched !== 0) begin
            $display("TEST FAIL fault_latch first of run");
            $finish;
        end
        pulse(1);
        if(latched !== 0) begin
            $display("TEST FAIL fault_latch second of run");
            $finish;
        end
        pulse(1);
        if(latched !== 1 || consec_count !== 3) begin
            $display("TEST FAIL fault_latch trip");
            $finish;
        end
        for(element_index = 0; element_index < 4; element_index = element_index + 1) begin
            pulse(0);
            if(latched !== 1) begin
                $display("TEST FAIL fault_latch normal must not release");
                $finish;
            end
        end
        pulse(1);
        pulse(1);
        pulse(1);
        pulse(1);
        if(latched !== 1 || consec_count !== 3) begin
            $display("TEST FAIL fault_latch count saturation");
            $finish;
        end
        @(negedge clk);
        clear = 1;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched !== 0 || consec_count !== 0) begin
            $display("TEST FAIL fault_latch clear");
            $finish;
        end
        @(negedge clk);
        clear = 0;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched !== 0) begin
            $display("TEST FAIL fault_latch clear release");
            $finish;
        end
        pulse(1);
        pulse(1);
        if(latched !== 0) begin
            $display("TEST FAIL fault_latch partial rearm");
            $finish;
        end
        pulse(1);
        if(latched !== 1) begin
            $display("TEST FAIL fault_latch relatch");
            $finish;
        end
        @(negedge clk);
        clear = 1;
        repeat(2) begin
            @(negedge clk);
        end
        @(negedge clk);
        clear = 0;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched !== 0 || consec_count !== 0) begin
            $display("TEST FAIL fault_latch second clear");
            $finish;
        end
        for(element_index = 0; element_index < 8; element_index = element_index + 1) begin
            @(negedge clk);
            class_id = ~ class_id;
            if(latched !== 0 || consec_count !== 0) begin
                $display("TEST FAIL fault_latch idle toggle");
                $finish;
            end
        end
        @(negedge clk);
        class_id = 0;
        pulse(1);
        pulse(1);
        @(negedge clk);
        class_id = 1;
        repeat(6) begin
            @(negedge clk);
        end
        if(latched !== 0 || consec_count !== 2) begin
            $display("TEST FAIL fault_latch idle level hold");
            $finish;
        end
        @(negedge clk);
        class_id = 0;
        repeat(2) begin
            @(negedge clk);
        end
        pulse(1);
        if(latched !== 1 || consec_count !== 3) begin
            $display("TEST FAIL fault_latch trip after idle");
            $finish;
        end
        $display("TEST PASS tb_fault_latch");
        $finish;
    end

    initial begin : timeout_proc
        #300000;
        $display("TEST FAIL timeout tb_fault_latch");
        $finish;
    end
endmodule
