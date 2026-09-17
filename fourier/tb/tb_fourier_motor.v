`timescale 1ns/1ps
module tb_fourier_motor;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,stop_button=0;
    reg [3:0] sw=4'b0111;
    reg class_valid=0,class_id=0;
    reg encoder_a=0,encoder_b=0,encoder_run=0;
    wire quad_direction;wire signed [31:0] quad_position;
    wire quad_illegal_fault;wire [15:0] quad_illegal_count;
    wire quad_timeout_fault,quad_overflow_fault;
    wire pwm,in1,in2,armed,motor_fault,motor_warning,motor_derated,motor_watchdog_fault;
    wire [1:0] motor_fault_cause;wire [7:0] motor_fault_consec;wire [15:0] motor_abnormal_count;
    wire [12:0] speed_reference,measured_speed,requested_duty;wire signed [31:0] pid_integral;
    wire [31:0] watchdog_count_probe;
    // Runtime PI tuning / open-loop override, tied to the original fixed values by
    // default so every pre-existing test below is unaffected.
    reg signed [17:0] kp_gain=18'sd58982,ki_gain=18'sd3932;
    reg anti_windup_enable=1,open_loop_enable=0;
    reg [12:0] open_loop_duty=13'd0;
    integer j,n;
    fourier_motor_control #(.CLK_HZ(320000),.FAULT_HZ(1000),.FAULT_CONSEC(3)) dut(
        .clk(clk),.reset_n(reset_n),.stop_button(stop_button),.sw(sw),
        .motor_pwm(pwm),.motor_in1(in1),.motor_in2(in2),.motor_armed(armed),
        .class_valid(class_valid),.class_id(class_id),.ps_heartbeat(1'b1),
        .motor_fault(motor_fault),.motor_warning(motor_warning),.motor_derated(motor_derated),
        .motor_watchdog_fault(motor_watchdog_fault),.motor_fault_cause(motor_fault_cause),
        .motor_fault_consec(motor_fault_consec),.motor_abnormal_count(motor_abnormal_count),
        .encoder_a(encoder_a),.encoder_b(encoder_b),
        .quad_direction(quad_direction),.quad_position(quad_position),
        .quad_illegal_fault(quad_illegal_fault),.quad_illegal_count(quad_illegal_count),
        .quad_timeout_fault(quad_timeout_fault),.quad_overflow_fault(quad_overflow_fault),
        .motor_speed_reference(speed_reference),
        .motor_measured_speed(measured_speed),.motor_requested_duty(requested_duty),
        .motor_pid_integral(pid_integral),.motor_watchdog_count(watchdog_count_probe),
        .kp_gain(kp_gain),.ki_gain(ki_gain),.anti_windup_enable(anti_windup_enable),
        .open_loop_enable(open_loop_enable),.open_loop_duty(open_loop_duty));
    task classify;
        input value;
        begin
            @(negedge clk);class_id=value;class_valid=1;
            @(negedge clk);class_valid=0;class_id=0;
            repeat(4)@(negedge clk);
        end
    endtask
    task pwm_frame;
        input integer expected;
        begin
            while(dut.pwm_unit.count!=0)@(negedge clk);
            n=0;
            for(j=0;j<16;j=j+1)begin if(pwm)n=n+1;@(negedge clk);end
            if(n!=expected || in1!==1 || in2!==0)begin
                $display("TEST FAIL Fourier duty %d expected %d",n,expected);$finish;
            end
        end
    endtask
    task frame;
        input [1:0] setting;input integer expected;
        begin
            @(negedge clk);sw[2:1]=setting;
            repeat(40)@(negedge clk);
            pwm_frame(expected);
        end
    endtask
    // Channel A toggles every 520 clocks, so the estimator stays in reciprocal mode
    // and reports a little under the lowest speed target.  The error therefore stays
    // positive for every setting and the loop always asks for some drive.
    always begin
        repeat(520)@(negedge clk);
        if(encoder_run)encoder_a=~encoder_a;
    end
    // The switches no longer fix the PWM count, so check that the loop responds to the
    // target instead of asserting a duty the open-loop build used to produce.
    task pi_frame;
        input [1:0] setting;
        begin
            @(negedge clk);sw[2:1]=setting;
            repeat(20*3200)@(negedge clk); // twenty 100 Hz sample windows
            if(dut.pid_duty===13'd0 || measured_speed===13'd0)begin
                $display("TEST FAIL Fourier PI response");$finish;
            end
        end
    endtask
    // Drives channel A/B directly (encoder_run stays 0 during this, so the
    // free-running toggle above cannot race it); six clocks is comfortably
    // more than the two-flop synchronizer plus one state-update cycle needs.
    task quad_step;
        input a_val;input b_val;
        begin
            @(negedge clk);encoder_a=a_val;encoder_b=b_val;
            repeat(6)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        if(armed!==0 || pwm!==0)begin $display("TEST FAIL Fourier boot arm");$finish;end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        if(armed!==1)begin $display("TEST FAIL Fourier explicit arm");$finish;end
        frame(0,0);
        encoder_run=1;
        pi_frame(1);pi_frame(2);pi_frame(3);
        sw[2:1]=2;sw[3]=1;
        wait(dut.fault_phase==1);repeat(20)@(negedge clk);pwm_frame(12);
        wait(dut.fault_phase==0);repeat(20)@(negedge clk);pwm_frame(4);
        sw[3]=0;pi_frame(2);
        wait(pwm);#2;stop_button=1;#1;
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier immediate stop");$finish;end
        repeat(5)@(negedge clk);stop_button=0;repeat(20)@(negedge clk);
        if(armed!==0)begin $display("TEST FAIL Fourier stop rearm");$finish;end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        pi_frame(2);
        sw[0]=0;repeat(12)@(negedge clk);
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier switch off");$finish;end
        sw[0]=1;repeat(12)@(negedge clk);wait(pwm);#2;reset_n=0;#1;
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier PS reset");$finish;end
        // Consecutive-abnormal latched stop, end to end through the motor guard.
        reset_n=1;repeat(20)@(negedge clk);
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        pi_frame(2);
        if(motor_fault!==0)begin $display("TEST FAIL Fourier fault idle");$finish;end
        classify(1);
        if(motor_fault!==0 || armed!==1 || motor_warning!==1 || motor_derated!==0)begin
            $display("TEST FAIL Fourier isolated abnormal warning");$finish;
        end
        pi_frame(2);
        classify(0);
        classify(1);classify(1);
        if(motor_fault!==0 || armed!==1 || motor_derated!==1)begin
            $display("TEST FAIL Fourier two abnormal derate");$finish;
        end
        // The loop still wants full drive here, so the derate clamp is what holds the
        // request at 25%.  The clamp logic itself is covered by tb_speed_pi_integration.
        if(requested_duty>13'd1024 || dut.pid_duty<=13'd1024)begin
            $display("TEST FAIL Fourier derate clamp");$finish;
        end
        classify(1);
        if(motor_fault!==1 || pwm!==0 || in1!==0 || armed!==0 || motor_fault_cause!==1)begin
            $display("TEST FAIL Fourier latched stop");$finish;
        end
        repeat(3)begin
            classify(0);
            if(motor_fault!==1 || pwm!==0 || armed!==0)begin
                $display("TEST FAIL Fourier latch release without SW0");$finish;
            end
        end
        sw[0]=0;repeat(12)@(negedge clk);
        if(motor_fault!==0 || motor_fault_cause!==0)begin $display("TEST FAIL Fourier latch clear");$finish;end
        sw[0]=1;repeat(12)@(negedge clk);
        if(motor_fault!==0 || armed!==1)begin $display("TEST FAIL Fourier fault rearm");$finish;end
        pi_frame(2);
        // Open-loop override (system identification path): bypasses the PI output
        // entirely and PWM tracks the AXI-commanded duty directly.
        open_loop_enable=1;open_loop_duty=13'd2048;
        repeat(40)@(negedge clk);
        pwm_frame(8);
        if(requested_duty!==13'd2048)begin $display("TEST FAIL Fourier open-loop override");$finish;end
        open_loop_enable=0;open_loop_duty=13'd0;
        repeat(40)@(negedge clk);
        // Anti-windup: with it disabled, a sustained saturating error (no encoder
        // feedback, max target) drives the integral straight to its hard +-4096
        // clamp. With it enabled, reject_update freezes accumulation as soon as the
        // combined P+I output saturates, well before the integral itself reaches
        // that clamp -- the two runs must therefore land at different integral
        // values for the same excitation and duration.
        encoder_run=0;
        anti_windup_enable=0;sw[2:1]=3;
        repeat(40*3200)@(negedge clk);
        if(pid_integral!==32'sd4096)begin
            $display("TEST FAIL Fourier windup unclamped, integral=%0d",pid_integral);$finish;
        end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        anti_windup_enable=1;sw[2:1]=3;
        repeat(40*3200)@(negedge clk);
        if(pid_integral>=32'sd4096)begin
            $display("TEST FAIL Fourier anti-windup did not hold back integral, integral=%0d",pid_integral);
            $finish;
        end
        anti_windup_enable=1;encoder_run=1;sw[2:1]=2;
        repeat(40)@(negedge clk);
        pi_frame(2);
        // Encoder channel-B quadrature: direction, illegal-jump detection, and
        // stall (timeout) detection. Reset first so encoder_quadrature's state/
        // position/fault registers all start from a known zero.
        reset_n=0;#1;reset_n=1;repeat(20)@(negedge clk);
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        sw[2:1]=0;encoder_run=0;encoder_a=0;encoder_b=0;repeat(6)@(negedge clk);
        // Forward walk: 00 -> 10 -> 11 -> 01 -> 00 (four valid single-bit
        // steps). This is the sequence encoder_quadrature.v maps to
        // valid_forward, matched to the real motor's C1/C2 wiring measured
        // 2026-09-16 -- see the comment there.
        quad_step(1,0);quad_step(1,1);quad_step(0,1);quad_step(0,0);
        if(quad_direction!==0 || quad_illegal_fault!==0 || quad_position!==32'sd4)begin
            $display("TEST FAIL quad forward dir=%d illegal=%d pos=%0d",
                quad_direction,quad_illegal_fault,quad_position);$finish;
        end
        // Backward walk: 00 -> 01 -> 11 -> 10 -> 00, back to position 0.
        quad_step(0,1);quad_step(1,1);quad_step(1,0);quad_step(0,0);
        if(quad_direction!==1 || quad_illegal_fault!==0 || quad_position!==32'sd0)begin
            $display("TEST FAIL quad backward dir=%d illegal=%d pos=%0d",
                quad_direction,quad_illegal_fault,quad_position);$finish;
        end
        // Illegal two-bit jump (00 -> 11): impossible for real quadrature signals.
        quad_step(1,1);
        if(quad_illegal_fault!==1 || quad_illegal_count!==16'd1 || quad_position!==32'sd0)begin
            $display("TEST FAIL quad illegal fault=%d count=%0d pos=%0d",
                quad_illegal_fault,quad_illegal_count,quad_position);$finish;
        end
        // Clear (SW0 OFF->ON) drops the sticky fault but keeps the event count,
        // matching safety_supervisor's abnormal_count convention.
        sw[0]=0;repeat(12)@(negedge clk);
        if(quad_illegal_fault!==0 || quad_illegal_count!==16'd1)begin
            $display("TEST FAIL quad clear");$finish;
        end
        sw[0]=1;repeat(12)@(negedge clk);
        // Stall detection: armed and driving a non-zero duty (sw[2:1]!=0) with
        // channel A/B frozen must latch timeout_fault once TIMEOUT_CLOCKS elapses
        // (200 ms at this testbench's 320 kHz CLK_HZ = 64,000 clocks).
        encoder_a=1'b0;encoder_b=1'b0;sw[2:1]=1;
        // Extra margin over the raw 64,000-clock timeout: duty can briefly sit
        // at zero during the PI's first few iterations before settling
        // nonzero, which would otherwise re-arm the stall counter partway in.
        repeat(64000+64000)@(negedge clk);
        if(quad_timeout_fault!==1)begin $display("TEST FAIL quad timeout not latched");$finish;end
        sw[2:1]=0;sw[0]=0;repeat(12)@(negedge clk);
        if(quad_timeout_fault!==0)begin $display("TEST FAIL quad timeout not cleared");$finish;end
        sw[0]=1;repeat(12)@(negedge clk);
        encoder_run=1;sw[2:1]=2;
        repeat(40)@(negedge clk);
        pi_frame(2);
        $display("TEST PASS tb_fourier_motor");$finish;
    end
    // Extended for the anti-windup comparison (two full 40-sample saturating runs)
    // and the quadrature timeout test (128,000 clocks at 320 kHz).
    initial begin #17000000;$display("TEST FAIL timeout tb_fourier_motor");$finish;end
endmodule
