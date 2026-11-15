//------------------------------------------------------------
// TB: tb_core
// TC1: 20개 입력, BRAM 결과 11개/입력 보존/busy
// TC2: 연산 도중 reset 중단
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_core;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    wire busy;
    wire done;
    wire class_id;
    wire bram_enable;
    wire [31:0] cycles;
    wire [31:0] npu_cycles;
    wire [31:0] features;
    wire [31:0] hidden;
    wire [31:0] bram_write_data;
    wire [15:0] logits;
    wire [3:0] bram_write_strobes;
    wire [9:0] bram_address;
    reg [31:0] bram_read_data = 0;
    reg [31:0] bram_memory[0:1023];
    reg [15:0] samples[0:1279];
    reg [7:0] expected_features[0:79];
    reg [7:0] expected_hidden[0:79];
    reg [7:0] expected_logits[0:39];
    reg [7:0] expected_classes[0:19];
    integer case_index, element_index, writes;
    reg launched = 0;
    vibration_core dut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .busy(busy),
        .done(done),
        .cycles(cycles),
        .npu_cycles(npu_cycles),
        .features(features),
        .hidden(hidden),
        .logits(logits),
        .class_id(class_id),
        .bram_en(bram_enable),
        .bram_we(bram_write_strobes),
        .bram_addr(bram_address),
        .bram_wdata(bram_write_data),
        .bram_rdata(bram_read_data)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : bram_model_proc
        @(posedge clk) if(bram_enable) begin
            if(bram_write_strobes == 4'hf) begin
                if(bram_address < 256 || bram_address > 266) begin
                    $display("TEST FAIL illegal write");
                    $finish;
                end
                bram_memory[bram_address] <= bram_write_data;
                writes = writes + 1;
            end
            else if(bram_write_strobes == 0) begin
                bram_read_data <= bram_memory[bram_address];
            end
            else begin
                $display("TEST FAIL byte enable");
                $finish;
            end
        end
    end

    always begin : busy_check_proc
        @(negedge clk) if(launched && ! rst && ! busy && ! done) begin
            $display("TEST FAIL busy gap");
            $finish;
        end
    end

    initial begin : stim_proc
        writes = 0;
        $readmemh("samples.mem", samples);
        $readmemh("features.mem", expected_features);
        $readmemh("hidden.mem", expected_hidden);
        $readmemh("logits.mem", expected_logits);
        $readmemh("class.mem", expected_classes);
        for(element_index = 0; element_index < 1280; element_index = element_index + 1) begin
            if((^ samples[element_index]) === 1'bx) begin
                $display("TEST FAIL missing input");
                $finish;
            end
        end
        for(element_index = 0; element_index < 80; element_index = element_index + 1) begin
            if((^ {expected_features[element_index], expected_hidden[element_index]}) === 1'bx) begin
                $display("TEST FAIL missing tensor");
                $finish;
            end
        end
        for(element_index = 0; element_index < 40; element_index = element_index + 1) begin
            if((^ expected_logits[element_index]) === 1'bx) begin
                $display("TEST FAIL missing logit");
                $finish;
            end
        end
        for(element_index = 0; element_index < 20; element_index = element_index + 1) begin
            if((^ expected_classes[element_index]) === 1'bx) begin
                $display("TEST FAIL missing class");
                $finish;
            end
        end
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        for(case_index = 0; case_index < 20; case_index = case_index + 1) begin
            for(element_index = 0; element_index < 64; element_index = element_index + 1) begin
                bram_memory[element_index] = {16'd0, samples[case_index * 64 + element_index]};
            end
            for(element_index = 256; element_index <= 266; element_index = element_index + 1) begin
                bram_memory[element_index] = 32'hdeadbeef;
            end
            writes = 0;
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            launched = 1;
            wait(done);
            launched = 0;
            @(negedge clk);
            if(writes != 11 || busy !== 0 || npu_cycles !== 18) begin
                $display("TEST FAIL completion contract");
                $finish;
            end
            for(element_index = 0; element_index < 4; element_index = element_index + 1) begin
                if(bram_memory[256 + element_index] !== {24'd0, expected_features[case_index * 4 + element_index]} || bram_memory[260 + element_index] !== {24'd0, expected_hidden[case_index * 4 + element_index]}) begin
                    $display("TEST FAIL BRAM tensor");
                    $finish;
                end
            end
            if(bram_memory[264] !== {{24 {expected_logits[case_index * 2][7]}}, expected_logits[case_index * 2]} || bram_memory[265] !== {{24 {expected_logits[case_index * 2 + 1][7]}}, expected_logits[case_index * 2 + 1]} ||
            bram_memory[266] !== {31'd0, expected_classes[case_index][0]}) begin
                $display("TEST FAIL BRAM results");
                $finish;
            end
            for(element_index = 0; element_index < 64; element_index = element_index + 1) begin
                if(bram_memory[element_index][15:0] !== samples[case_index * 64 + element_index]) begin
                    $display("TEST FAIL input modified");
                    $finish;
                end
            end
        end
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        repeat(40) begin
            @(negedge clk);
        end
        rst = 1;
        repeat(2) begin
            @(negedge clk);
        end
        if(busy !== 0 || bram_enable !== 0) begin
            $display("TEST FAIL reset abort");
            $finish;
        end
        $display("TEST PASS tb_core 20 windows, BRAM ownership, continuous busy, reset abort");
        $finish;
    end

    initial begin : timeout_proc
        #1000000;
        $display("TEST FAIL timeout tb_core");
        $finish;
    end
endmodule
