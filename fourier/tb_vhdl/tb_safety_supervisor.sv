//------------------------------------------------------------
// TB: tb_safety_supervisor
// TC1: warning/derate/분류 latch
// TC2: heartbeat watchdog과 clear
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_safety_supervisor;
    reg clk = 0;
    reg rst = 1;
    reg clear = 0;
    reg armed = 0;
    reg class_valid = 0;
    reg class_id = 0;
    reg heartbeat = 0;
    wire warning;
    wire derated;
    wire latched;
    wire watchdog_fault;
    wire [1:0] cause;
    wire [7:0] consec;
    wire [15:0] abnormal_count;
    integer element_index;
    safety_supervisor #(
        .TRIP_CONSEC(3),
        .DERATE_CONSEC(2),
        .WATCHDOG_CYCLES(12)
    ) dut(
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .armed(armed),
        .class_valid(class_valid),
        .class_id(class_id),
        .heartbeat(heartbeat),
        .warning(warning),
        .derated(derated),
        .latched(latched),
        .watchdog_fault(watchdog_fault),
        .fault_cause(cause),
        .consec_count(consec),
        .abnormal_count(abnormal_count),
        .watchdog_count_out()
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    task classify;
        input value;
        begin
            @(negedge clk);
            class_id = value;
            class_valid = 1;
            @(negedge clk);
            class_valid = 0;
            class_id = 0;
            @(negedge clk);
        end
    endtask

    task beat;
        begin
            @(negedge clk);
            heartbeat = 1;
            @(negedge clk);
            heartbeat = 0;
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
        classify(1);
        if(! warning || derated || latched || consec != 1) begin
            $display("TEST FAIL safety warning");
            $finish;
        end
        classify(1);
        if(! warning || ! derated || latched || consec != 2) begin
            $display("TEST FAIL safety derate");
            $finish;
        end
        classify(0);
        if(warning || derated || latched || consec != 0) begin
            $display("TEST FAIL safety recovery");
            $finish;
        end
        classify(1);
        classify(1);
        classify(1);
        if(! latched || cause != 1 || abnormal_count != 5) begin
            $display("TEST FAIL safety classifier trip");
            $finish;
        end
        classify(0);
        if(! latched) begin
            $display("TEST FAIL safety latch persistence");
            $finish;
        end
        clear = 1;
        repeat(2) begin
            @(negedge clk);
        end
        clear = 0;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched || cause != 0 || consec != 0 || abnormal_count != 5) begin
            $display("TEST FAIL safety clear");
            $finish;
        end
        armed = 1;
        for(element_index = 0; element_index < 30; element_index = element_index + 1) begin
            beat;
            repeat(5) begin
                @(negedge clk);
            end
            if(latched) begin
                $display("TEST FAIL safety heartbeat hold");
                $finish;
            end
        end
        repeat(14) begin
            @(negedge clk);
        end
        if(! latched || ! watchdog_fault || cause != 2) begin
            $display("TEST FAIL safety watchdog trip");
            $finish;
        end
        clear = 1;
        repeat(2) begin
            @(negedge clk);
        end
        clear = 0;
        armed = 0;
        repeat(2) begin
            @(negedge clk);
        end
        if(latched || cause != 0) begin
            $display("TEST FAIL safety watchdog clear");
            $finish;
        end
        $display("TEST PASS tb_safety_supervisor");
        $finish;
    end

    initial begin : timeout_proc
        #300000;
        $display("TEST FAIL timeout tb_safety_supervisor");
        $finish;
    end
endmodule
