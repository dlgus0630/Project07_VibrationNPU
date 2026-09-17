`timescale 1ns/1ps
// Wiring check for the encoder estimator and the PI controller inside the motor
// guard.  Loop performance itself is covered by the standalone controller bench;
// here we only prove the feedback path reaches PWM and that the safety override
// still wins.  CLK_HZ is shrunk so the 100 Hz sample tick lands every 1000 cycles.
module tb_speed_pi_integration;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,stop_button=0;
    reg [3:0] sw=4'b0111;
    reg class_valid=0,class_id=0;
    reg encoder_a=0,encoder_run=0;
    wire encoder_b=1'b0; // channel B unused here; exercised in tb_fourier_motor
    wire quad_direction;wire signed [31:0] quad_position;
    wire quad_illegal_fault;wire [15:0] quad_illegal_count;
    wire quad_timeout_fault,quad_overflow_fault;
    wire pwm,in1,in2,armed,motor_fault,motor_warning,motor_derated,motor_watchdog_fault;
    wire [1:0] motor_fault_cause;wire [7:0] motor_fault_consec;wire [15:0] motor_abnormal_count;
    wire [12:0] speed_reference,measured_speed,requested_duty;wire signed [31:0] pid_integral;
    reg duty_moved=0;reg [12:0] duty_at_arm;integer k;
    // Runtime PI tuning / open-loop override, tied to the original fixed values so
    // this loop-wiring check is unaffected; exercised separately in tb_fourier_motor.
    reg signed [17:0] kp_gain=18'sd58982,ki_gain=18'sd3932;
    reg anti_windup_enable=1,open_loop_enable=0;
    reg [12:0] open_loop_duty=13'd0;
    fourier_motor_control #(.CLK_HZ(100000),.FAULT_HZ(1000),.FAULT_CONSEC(3)) dut(
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
        .motor_pid_integral(pid_integral),
        .kp_gain(kp_gain),.ki_gain(ki_gain),.anti_windup_enable(anti_windup_enable),
        .open_loop_enable(open_loop_enable),.open_loop_duty(open_loop_duty));
    // Clean quadrature-free channel A: 50 clocks high, 50 low, so roughly ten edges
    // land in every 1000 clock sample window and the estimator stays in reciprocal mode.
    always begin
        repeat(50)@(negedge clk);
        if(encoder_run)encoder_a=~encoder_a;
    end
    always @(posedge clk)if(requested_duty!=0)duty_moved<=1;
    task classify;
        input value;
        begin
            @(negedge clk);class_id=value;class_valid=1;
            @(negedge clk);class_valid=0;class_id=0;
            repeat(4)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        if(armed!==1)begin $display("TEST FAIL speed PI arm");$finish;end
        duty_at_arm=requested_duty;
        if(duty_at_arm!==0)begin
            $display("TEST FAIL speed PI duty not idle at arm %d",duty_at_arm);$finish;
        end
        encoder_run=1;
        // Ten sample windows give the reciprocal estimate and its filter time to settle.
        repeat(10000)@(negedge clk);
        if(speed_reference!==13'd3072)begin
            $display("TEST FAIL speed PI reference %d",speed_reference);$finish;
        end
        if(measured_speed===0)begin $display("TEST FAIL speed PI encoder idle");$finish;end
        if(!duty_moved)begin $display("TEST FAIL speed PI duty stuck at zero");$finish;end
        if(requested_duty===0)begin $display("TEST FAIL speed PI duty settled at zero");$finish;end
        // SW3 drives PWM directly; the loop keeps estimating but must not reach the pin.
        sw[3]=1;
        wait(dut.fault_phase==1);repeat(8)@(negedge clk);
        if(requested_duty!==13'd3072)begin
            $display("TEST FAIL speed PI inject high %d",requested_duty);$finish;
        end
        wait(dut.fault_phase==0);repeat(8)@(negedge clk);
        if(requested_duty!==13'd1024)begin
            $display("TEST FAIL speed PI inject low %d",requested_duty);$finish;
        end
        sw[3]=0;repeat(2000)@(negedge clk);
        if(requested_duty===0 || motor_fault!==0)begin
            $display("TEST FAIL speed PI inject release");$finish;
        end
        // Three consecutive abnormal windows must stop the pin no matter what the loop wants.
        classify(1);classify(1);
        if(motor_derated!==1 || armed!==1)begin $display("TEST FAIL speed PI derate");$finish;end
        if(requested_duty>13'd1024)begin
            $display("TEST FAIL speed PI derate clamp %d",requested_duty);$finish;
        end
        classify(1);
        if(motor_fault!==1 || armed!==0 || pwm!==0 || in1!==0)begin
            $display("TEST FAIL speed PI latched stop");$finish;
        end
        for(k=0;k<200;k=k+1)begin
            @(negedge clk);
            if(pwm!==0)begin $display("TEST FAIL speed PI pwm after latch");$finish;end
        end
        $display("TEST PASS tb_speed_pi_integration");$finish;
    end
    initial begin #3000000;$display("TEST FAIL timeout tb_speed_pi_integration");$finish;end
endmodule
