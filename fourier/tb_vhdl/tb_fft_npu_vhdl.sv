//------------------------------------------------------------
// TB: tb_fft_npu_vhdl
// TC1: 20개 특징/은닉/logits/class 기준값
// TC2: NPU 18클럭 계약
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
// Existing 20 Golden vectors, including all four arithmetic edge cases.
// The original Verilog test also checks internal complex bins; this mixed-
// language test checks the externally visible features and every NPU tensor.
module tb_fft_npu_vhdl;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg npu_start = 0;
    wire sample_enable;
    wire busy;
    wire done;
    wire npu_busy;
    wire npu_done;
    wire class_id;
    wire [5:0] sample_address;
    reg signed [15:0] sample_data = 0;
    wire [31:0] features;
    wire [31:0] hidden;
    wire [31:0] npu_cycles;
    wire [15:0] logits;
    reg [15:0] samples[0:1279];
    reg [7:0] expected_features[0:79];
    reg [7:0] expected_hidden[0:79];
    reg [7:0] expected_logits[0:39];
    reg [7:0] expected_classes[0:19];
    integer case_index, element_index;
    fft64_features fft(
        .clk(clk),
        .rst(rst),
        .start(start),
        .sample_en(sample_enable),
        .sample_addr(sample_address),
        .sample_data(sample_data),
        .busy(busy),
        .done(done),
        .features(features)
    );
    npu_2pe npu(
        .clk(clk),
        .rst(rst),
        .start(npu_start),
        .features(features),
        .busy(npu_busy),
        .done(npu_done),
        .hidden(hidden),
        .logits(logits),
        .class_id(class_id),
        .cycles(npu_cycles)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : sample_source_proc
        @(posedge clk) if(sample_enable) begin
            sample_data <= samples[case_index * 64 + sample_address];
        end
    end

    initial begin : stim_proc
        $readmemh("samples.mem", samples);
        $readmemh("features.mem", expected_features);
        $readmemh("hidden.mem", expected_hidden);
        $readmemh("logits.mem", expected_logits);
        $readmemh("class.mem", expected_classes);
        for(element_index = 0; element_index < 1280; element_index = element_index + 1) begin
            if((^ samples[element_index]) === 1'bx) begin
                $fatal(1, "missing input frame");
            end
        end
        case_index = 0;
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        for(case_index = 0; case_index < 20; case_index = case_index + 1) begin
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            wait(done);
            @(negedge clk);
            for(element_index = 0; element_index < 4; element_index = element_index + 1) begin
                if(features[element_index * 8 +: 8] !== expected_features[case_index * 4 + element_index]) begin
                    $fatal(1, "features case %0d channel %0d got %h expected %h", case_index, element_index, features[element_index * 8 +: 8], expected_features[case_index * 4 + element_index]);
                end
            end
            npu_start = 1;
            @(negedge clk);
            npu_start = 0;
            wait(npu_done);
            @(negedge clk);
            for(element_index = 0; element_index < 4; element_index = element_index + 1) begin
                if(hidden[element_index * 8 +: 8] !== expected_hidden[case_index * 4 + element_index]) begin
                    $fatal(1, "hidden case %0d channel %0d got %h expected %h", case_index, element_index, hidden[element_index * 8 +: 8], expected_hidden[case_index * 4 + element_index]);
                end
            end
            if(logits !== {expected_logits[case_index * 2 + 1], expected_logits[case_index * 2]} || class_id !== expected_classes[case_index][0] || npu_cycles !== 18) begin
                $fatal(1, "output case %0d logits %h class %b cycles %0d", case_index, logits, class_id, npu_cycles);
            end
        end
        $display("TEST PASS tb_fft_npu_vhdl: 20 Golden feature/hidden/logit/class cases and NPU 18 cycles");
        $finish;
    end

    initial begin : timeout_proc
        #1000000;
        $fatal(1, "timeout");
    end
endmodule
