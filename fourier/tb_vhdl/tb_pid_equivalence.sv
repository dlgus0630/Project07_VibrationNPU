//------------------------------------------------------------
// TB: tb_pid_equivalence
// TC1: 2,000회 게인/포화/anti-windup 입력 비교
// TC2: 중간 reset, duty/적분/필터/busy/done 비교
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
// Compare original RTL and VHDL every clock, including clipping and reset.
module tb_pid_equivalence;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg anti_windup = 1;
    reg [12:0] reference = 0;
    reg [12:0] measured = 0;
    reg signed [17:0] kp = 18'sd58982;
    reg signed [17:0] ki = 18'sd3932;
    wire busy_v;
    wire done_v;
    wire busy_r;
    wire done_r;
    wire [12:0] duty_v;
    wire [12:0] duty_r;
    wire signed [31:0] integral_v;
    wire signed [31:0] integral_r;
    wire signed [17:0] derivative_v;
    wire signed [17:0] derivative_r;
    integer transaction_index, seed = 20261115;
    pid_fixed dut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .reference(reference),
        .measured(measured),
        .kp_gain(kp),
        .ki_gain(ki),
        .anti_windup_enable(anti_windup),
        .busy(busy_v),
        .done(done_v),
        .duty(duty_v),
        .integral(integral_v),
        .derivative(derivative_v)
    );
    pid_fixed_ref refdut(
        .clk(clk),
        .rst(rst),
        .start(start),
        .reference(reference),
        .measured(measured),
        .kp_gain(kp),
        .ki_gain(ki),
        .anti_windup_enable(anti_windup),
        .busy(busy_r),
        .done(done_r),
        .duty(duty_r),
        .integral(integral_r),
        .derivative(derivative_r)
    );
    // 한 신호씩 비교해 불일치한 이름과 값을 즉시 출력한다.

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    task check_signal(input string signal_name, input [31:0] actual, input [31:0] expected);
        begin
            if (actual !== expected) begin
                $fatal(1, "%s mismatch at %0t: actual=%h expected=%h", signal_name, $time, actual, expected);
            end
        end
    endtask

    always begin : output_check_proc
        @(negedge clk);
        if (!rst) begin
            check_signal("busy", busy_v, busy_r);
            check_signal("done", done_v, done_r);
            check_signal("duty", duty_v, duty_r);
            check_signal("int", integral_v, integral_r);
            check_signal("deriv", derivative_v, derivative_r);
        end
    end

    initial begin : stim_proc
        repeat(4) begin
            @(negedge clk);
        end
        rst = 0;
        for(transaction_index = 0; transaction_index < 2000; transaction_index = transaction_index + 1) begin
            @(negedge clk);
            reference = $random(seed);
            measured = $random(seed);
            anti_windup = $random(seed);
            case(transaction_index % 5)
                0 : begin
                    kp = 18'sd58982;
                    ki = 18'sd3932;
                end
                1 : begin
                    kp = 18'sd131071;
                    ki = - 18'sd131072;
                end
                2 : begin
                    kp = - 18'sd131072;
                    ki = 18'sd131071;
                end
                default : begin
                    kp = $random(seed);
                    ki = $random(seed);
                end
            endcase
            start = 1;
            @(negedge clk);
            start = 0;
            repeat(13) begin
                @(negedge clk);
            end
            if(transaction_index % 107 == 0) begin
                rst = 1;
                @(negedge clk);
                rst = 0;
            end
        end
        $display("TEST PASS tb_pid_equivalence: 2000 transactions cycle-by-cycle");
        $finish;
    end

    initial begin : timeout_proc
        #1000000;
        $fatal(1, "PID timeout");
    end
endmodule
