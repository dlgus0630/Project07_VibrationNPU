//------------------------------------------------------------
// TB: tb_core_equivalence
// TC1: 20개 입력의 모든 외부 포트 클록별 비교
// TC2: reset 중단 동작 비교
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
// Identical BRAM input and start pulses; compare every top-level output each cycle.
module tb_core_equivalence;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg checking = 0;
    wire busy_v;
    wire done_v;
    wire class_v;
    wire en_v;
    wire busy_r;
    wire done_r;
    wire class_r;
    wire en_r;
    wire [31:0] cycles_v;
    wire [31:0] ncycles_v;
    wire [31:0] features_v;
    wire [31:0] hidden_v;
    wire [31:0] wdata_v;
    wire [31:0] cycles_r;
    wire [31:0] ncycles_r;
    wire [31:0] features_r;
    wire [31:0] hidden_r;
    wire [31:0] wdata_r;
    wire [15:0] logits_v;
    wire [15:0] logits_r;
    wire [3:0] we_v;
    wire [3:0] we_r;
    wire [9:0] addr_v;
    wire [9:0] addr_r;
    reg [31:0] bram_read_data = 0;
    reg [31:0] bram_memory[0:1023];
    reg [15:0] samples[0:1279];
    integer case_index, element_index;
    vibration_core dut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .busy(busy_v),
        .done(done_v),
        .cycles(cycles_v),
        .npu_cycles(ncycles_v),
        .features(features_v),
        .hidden(hidden_v),
        .logits(logits_v),
        .class_id(class_v),
        .bram_en(en_v),
        .bram_we(we_v),
        .bram_addr(addr_v),
        .bram_wdata(wdata_v),
        .bram_rdata(bram_read_data)
    );
    vibration_core_ref refdut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .busy(busy_r),
        .done(done_r),
        .cycles(cycles_r),
        .npu_cycles(ncycles_r),
        .features(features_r),
        .hidden(hidden_r),
        .logits(logits_r),
        .class_id(class_r),
        .bram_en(en_r),
        .bram_we(we_r),
        .bram_addr(addr_r),
        .bram_wdata(wdata_r),
        .bram_rdata(bram_read_data)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : bram_model_proc
        @(posedge clk) if(en_r) begin
            if(we_r == 4'hf) begin
                bram_memory[addr_r] <= wdata_r;
            end
            else if(we_r == 0) begin
                bram_read_data <= bram_memory[addr_r];
            end
        end
    end
    // 한 신호씩 비교해 불일치한 이름과 값을 즉시 출력한다.

    task check_signal(input string signal_name, input [31:0] actual, input [31:0] expected);
        begin
            if (actual !== expected) begin
                $fatal(1, "%s mismatch at %0t: actual=%h expected=%h", signal_name, $time, actual, expected);
            end
        end
    endtask

    always begin : output_check_proc
        @(posedge clk);
        #2;
        if (checking) begin
            check_signal("busy", busy_v, busy_r);
            check_signal("done", done_v, done_r);
            check_signal("cycles", cycles_v, cycles_r);
            check_signal("ncycles", ncycles_v, ncycles_r);
            check_signal("features", features_v, features_r);
            check_signal("hidden", hidden_v, hidden_r);
            check_signal("logits", logits_v, logits_r);
            check_signal("class", class_v, class_r);
            check_signal("en", en_v, en_r);
            check_signal("we", we_v, we_r);
            check_signal("addr", addr_v, addr_r);
            check_signal("wdata", wdata_v, wdata_r);
        end
    end

    initial begin : stim_proc
        $readmemh("samples.mem", samples);
        for(element_index = 0; element_index < 1280; element_index = element_index + 1) begin
            if((^ samples[element_index]) === 1'bx) begin
                $fatal(1, "missing input");
            end
        end
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        checking = 1;
        for(case_index = 0; case_index < 20; case_index = case_index + 1) begin
            for(element_index = 0; element_index < 64; element_index = element_index + 1) begin
                bram_memory[element_index] = {16'd0, samples[case_index * 64 + element_index]};
            end
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            wait(done_r);
            @(negedge clk);
        end
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        repeat(40) begin
            @(negedge clk);
        end
        rst = 1;
        repeat(3) begin
            @(negedge clk);
        end
        rst = 0;
        repeat(3) begin
            @(negedge clk);
        end
        $display("TEST PASS tb_core_equivalence: 20 inputs, every output and cycle, reset abort");
        $finish;
    end

    initial begin : timeout_proc
        #1000000;
        $fatal(1, "core timeout");
    end
endmodule
