`timescale 1ns/1ps
module tb_fourier_motor;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,stop_button=0;
    reg [3:0] sw=4'b0111;
    reg class_valid=0,class_id=0;
    reg encoder_a=0,encoder_run=0;
    wire pwm,in1,in2,armed,motor_fault,motor_warning,motor_derated,motor_watchdog_fault;
    wire [1:0] motor_fault_cause;wire [7:0] motor_fault_consec;wire [15:0] motor_abnormal_count;
    wire [12:0] speed_reference,measured_speed,requested_duty;wire signed [31:0] pid_integral;
    wire [31:0] watchdog_count_probe;
    integer j,n;
    fourier_motor_control #(.CLK_HZ(320000),.FAULT_HZ(1000),.FAULT_CONSEC(3)) dut(
        .clk(clk),.reset_n(reset_n),.stop_button(stop_button),.sw(sw),
        .motor_pwm(pwm),.motor_in1(in1),.motor_in2(in2),.motor_armed(armed),
        .class_valid(class_valid),.class_id(class_id),.ps_heartbeat(1'b1),
        .motor_fault(motor_fault),.motor_warning(motor_warning),.motor_derated(motor_derated),
        .motor_watchdog_fault(motor_watchdog_fault),.motor_fault_cause(motor_fault_cause),
        .motor_fault_consec(motor_fault_consec),.motor_abnormal_count(motor_abnormal_count),
        .encoder_a(encoder_a),.motor_speed_reference(speed_reference),
        .motor_measured_speed(measured_speed),.motor_requested_duty(requested_duty),
        .motor_pid_integral(pid_integral),.motor_watchdog_count(watchdog_count_probe));
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
        $display("TEST PASS tb_fourier_motor");$finish;
    end
    initial begin #8000000;$display("TEST FAIL timeout tb_fourier_motor");$finish;end
endmodule
