//------------------------------------------------------------
// TB: tb_motor_equivalence
// TC1: arm·PI·인코더·PWM·리플 비교
// TC2: 분류 latch/재시작/직교 위치 쓰기
// TC3: watchdog·정지·telemetry 비교
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
// Same external stimuli into the original Verilog and VHDL motor assemblies.
module tb_motor_equivalence;
    reg clk = 0;
    reg reset_n = 0;
    reg stop_button = 0;
    reg [3:0] sw = 4'b0111;
    reg class_valid = 0;
    reg class_id = 0;
    reg heartbeat = 1;
    reg encoder_a = 0;
    reg encoder_b = 0;
    reg position_write = 0;
    reg signed [31:0] position_preset = 0;
    reg signed [17:0] kp = 18'sd58982;
    reg signed [17:0] ki = 18'sd3932;
    reg anti_windup = 1;
    reg open_loop_enable = 0;
    reg [12:0] open_duty = 0;
    wire pwm_v;
    wire in1_v;
    wire in2_v;
    wire armed_v;
    wire fault_v;
    wire warn_v;
    wire derate_v;
    wire watchdog_fault_v;
    wire direction_v;
    wire illegal_fault_v;
    wire timeout_fault_v;
    wire overflow_fault_v;
    wire pwm_r;
    wire in1_r;
    wire in2_r;
    wire armed_r;
    wire fault_r;
    wire warn_r;
    wire derate_r;
    wire watchdog_fault_r;
    wire direction_r;
    wire illegal_fault_r;
    wire timeout_fault_r;
    wire overflow_fault_r;
    wire [1:0] cause_v;
    wire [1:0] cause_r;
    wire [7:0] consec_v;
    wire [7:0] consec_r;
    wire [15:0] abnormal_v;
    wire [15:0] abnormal_r;
    wire [15:0] ill_count_v;
    wire [15:0] ill_count_r;
    wire [12:0] speed_ref_v;
    wire [12:0] speed_ref_r;
    wire [12:0] speed_v;
    wire [12:0] speed_r;
    wire [12:0] duty_v;
    wire [12:0] duty_r;
    wire [31:0] position_v;
    wire [31:0] position_r;
    wire [31:0] integral_v;
    wire [31:0] integral_r;
    wire [31:0] wd_count_v;
    wire [31:0] wd_count_r;
    reg encoder_run = 0;
    reg checking = 0;
    fourier_motor_control #(
        .CLK_HZ(100000),
        .FAULT_HZ(1000)
    ) dut(
        .clk(clk),
        .reset_n(reset_n),
        .stop_button(stop_button),
        .sw(sw),
        .motor_pwm(pwm_v),
        .motor_in1(in1_v),
        .motor_in2(in2_v),
        .motor_armed(armed_v),
        .class_valid(class_valid),
        .class_id(class_id),
        .ps_heartbeat(heartbeat),
        .motor_fault(fault_v),
        .motor_warning(warn_v),
        .motor_derated(derate_v),
        .motor_watchdog_fault(watchdog_fault_v),
        .motor_fault_cause(cause_v),
        .motor_fault_consec(consec_v),
        .motor_abnormal_count(abnormal_v),
        .encoder_a(encoder_a),
        .encoder_b(encoder_b),
        .quad_position_wr_en(position_write),
        .quad_position_wr_value(position_preset),
        .quad_direction(direction_v),
        .quad_position(position_v),
        .quad_illegal_fault(illegal_fault_v),
        .quad_illegal_count(ill_count_v),
        .quad_timeout_fault(timeout_fault_v),
        .quad_overflow_fault(overflow_fault_v),
        .motor_speed_reference(speed_ref_v),
        .motor_measured_speed(speed_v),
        .motor_requested_duty(duty_v),
        .motor_pid_integral(integral_v),
        .motor_watchdog_count(wd_count_v),
        .kp_gain(kp),
        .ki_gain(ki),
        .anti_windup_enable(anti_windup),
        .open_loop_enable(open_loop_enable),
        .open_loop_duty(open_duty)
    );
    fourier_motor_control_ref #(
        .CLK_HZ(100000),
        .FAULT_HZ(1000)
    ) refdut(
        .clk(clk),
        .reset_n(reset_n),
        .stop_button(stop_button),
        .sw(sw),
        .motor_pwm(pwm_r),
        .motor_in1(in1_r),
        .motor_in2(in2_r),
        .motor_armed(armed_r),
        .class_valid(class_valid),
        .class_id(class_id),
        .ps_heartbeat(heartbeat),
        .motor_fault(fault_r),
        .motor_warning(warn_r),
        .motor_derated(derate_r),
        .motor_watchdog_fault(watchdog_fault_r),
        .motor_fault_cause(cause_r),
        .motor_fault_consec(consec_r),
        .motor_abnormal_count(abnormal_r),
        .encoder_a(encoder_a),
        .encoder_b(encoder_b),
        .quad_position_wr_en(position_write),
        .quad_position_wr_value(position_preset),
        .quad_direction(direction_r),
        .quad_position(position_r),
        .quad_illegal_fault(illegal_fault_r),
        .quad_illegal_count(ill_count_r),
        .quad_timeout_fault(timeout_fault_r),
        .quad_overflow_fault(overflow_fault_r),
        .motor_speed_reference(speed_ref_r),
        .motor_measured_speed(speed_r),
        .motor_requested_duty(duty_r),
        .motor_pid_integral(integral_r),
        .motor_watchdog_count(wd_count_r),
        .kp_gain(kp),
        .ki_gain(ki),
        .anti_windup_enable(anti_windup),
        .open_loop_enable(open_loop_enable),
        .open_loop_duty(open_duty)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : encoder_stim_proc
        repeat(50) begin
            @(negedge clk);
        end
        if(encoder_run) begin
            encoder_a = ~ encoder_a;
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
            check_signal("pwm", pwm_v, pwm_r);
            check_signal("in1", in1_v, in1_r);
            check_signal("in2", in2_v, in2_r);
            check_signal("armed", armed_v, armed_r);
            check_signal("fault", fault_v, fault_r);
            check_signal("warn", warn_v, warn_r);
            check_signal("derate", derate_v, derate_r);
            check_signal("wd", watchdog_fault_v, watchdog_fault_r);
            check_signal("cause", cause_v, cause_r);
            check_signal("consec", consec_v, consec_r);
            check_signal("abnormal", abnormal_v, abnormal_r);
            check_signal("dir", direction_v, direction_r);
            check_signal("position", position_v, position_r);
            check_signal("ill", illegal_fault_v, illegal_fault_r);
            check_signal("ill_count", ill_count_v, ill_count_r);
            check_signal("to", timeout_fault_v, timeout_fault_r);
            check_signal("ov", overflow_fault_v, overflow_fault_r);
            check_signal("speed_ref", speed_ref_v, speed_ref_r);
            check_signal("speed", speed_v, speed_r);
            check_signal("duty", duty_v, duty_r);
            check_signal("integral", integral_v, integral_r);
            check_signal("wd_count", wd_count_v, wd_count_r);
        end
    end

    task classify(input val);
        begin
            @(negedge clk);
            class_id = val;
            class_valid = 1;
            @(negedge clk);
            class_valid = 0;
            class_id = 0;
            repeat(4) begin
                @(negedge clk);
            end
        end
    endtask

    initial begin : stim_proc
        repeat(4) begin
            @(negedge clk);
        end
        reset_n = 1;
        repeat(20) begin
            @(negedge clk);
        end
        checking = 1;
        sw[0] = 0;
        repeat(12) begin
            @(negedge clk);
        end
        sw[0] = 1;
        repeat(12) begin
            @(negedge clk);
        end
        encoder_run = 1;
        repeat(10000) begin
            @(negedge clk);
        end
        if(! armed_v || speed_v == 0 || duty_v == 0) begin
            $fatal(1, "motor not producing closed-loop output");
        end
        sw[3] = 1;
        repeat(200) begin
            @(negedge clk);
        end
        sw[3] = 0;
        repeat(200) begin
            @(negedge clk);
        end
        classify(1);
        classify(1);
        classify(1);
        repeat(20) begin
            @(negedge clk);
        end
        if(! fault_v || armed_v) begin
            $fatal(1, "classifier latch missing");
        end
        sw[0] = 0;
        repeat(20) begin
            @(negedge clk);
        end
        sw[0] = 1;
        repeat(20) begin
            @(negedge clk);
        end
        open_loop_enable = 1;
        open_duty = 2500;
        repeat(500) begin
            @(negedge clk);
        end
        position_write = 1;
        position_preset = 32'sh7ffffffe;
        @(negedge clk);
        position_write = 0;
        repeat(500) begin
            @(negedge clk);
        end
        open_loop_enable = 0;
        anti_windup = 0;
        heartbeat = 0;
        repeat(50100) begin
            @(negedge clk);
        end
        if(! watchdog_fault_v || ! fault_v || armed_v) begin
            $fatal(1, "watchdog latch missing");
        end
        sw[0] = 0;
        repeat(20) begin
            @(negedge clk);
        end
        heartbeat = 1;
        sw[0] = 1;
        repeat(100) begin
            @(negedge clk);
        end
        stop_button = 1;
        repeat(10) begin
            @(negedge clk);
        end
        stop_button = 0;
        repeat(50) begin
            @(negedge clk);
        end
        $display("TEST PASS tb_motor_equivalence: cycle-by-cycle motor/safety/telemetry");
        $finish;
    end

    initial begin : timeout_proc
        #1000000;
        $fatal(1, "motor timeout");
    end
endmodule
