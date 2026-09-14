`timescale 1ns/1ps
module tb_fourier_motor;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,stop_button=0;
    reg [3:0] sw=4'b0111;
    reg class_valid=0,class_id=0;
    wire pwm,in1,in2,armed,motor_fault;
    integer j,n;
    fourier_motor_control #(.CLK_HZ(320000),.FAULT_HZ(1000),.FAULT_CONSEC(3)) dut(
        .clk(clk),.reset_n(reset_n),.stop_button(stop_button),.sw(sw),
        .motor_pwm(pwm),.motor_in1(in1),.motor_in2(in2),.motor_armed(armed),
        .class_valid(class_valid),.class_id(class_id),.motor_fault(motor_fault));
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
    initial begin
        repeat(4)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        if(armed!==0 || pwm!==0)begin $display("TEST FAIL Fourier boot arm");$finish;end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        if(armed!==1)begin $display("TEST FAIL Fourier explicit arm");$finish;end
        frame(0,0);frame(1,4);frame(2,8);frame(3,12);
        sw[2:1]=2;sw[3]=1;
        wait(dut.fault_phase==1);repeat(20)@(negedge clk);pwm_frame(12);
        wait(dut.fault_phase==0);repeat(20)@(negedge clk);pwm_frame(4);
        sw[3]=0;repeat(40)@(negedge clk);pwm_frame(8);
        wait(pwm);#2;stop_button=1;#1;
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier immediate stop");$finish;end
        repeat(5)@(negedge clk);stop_button=0;repeat(20)@(negedge clk);
        if(armed!==0)begin $display("TEST FAIL Fourier stop rearm");$finish;end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        frame(2,8);
        sw[0]=0;repeat(12)@(negedge clk);
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier switch off");$finish;end
        sw[0]=1;repeat(12)@(negedge clk);wait(pwm);#2;reset_n=0;#1;
        if(pwm!==0 || in1!==0 || armed!==0)begin $display("TEST FAIL Fourier PS reset");$finish;end
        // Consecutive-abnormal latched stop, end to end through the motor guard.
        reset_n=1;repeat(20)@(negedge clk);
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        frame(2,8);
        if(motor_fault!==0)begin $display("TEST FAIL Fourier fault idle");$finish;end
        classify(1);
        if(motor_fault!==0 || armed!==1)begin $display("TEST FAIL Fourier isolated abnormal");$finish;end
        pwm_frame(8);
        classify(0);
        classify(1);classify(1);
        if(motor_fault!==0 || armed!==1)begin $display("TEST FAIL Fourier two abnormal");$finish;end
        classify(1);
        if(motor_fault!==1 || pwm!==0 || in1!==0 || armed!==0)begin
            $display("TEST FAIL Fourier latched stop");$finish;
        end
        repeat(3)begin
            classify(0);
            if(motor_fault!==1 || pwm!==0 || armed!==0)begin
                $display("TEST FAIL Fourier latch release without SW0");$finish;
            end
        end
        sw[0]=0;repeat(12)@(negedge clk);
        if(motor_fault!==0)begin $display("TEST FAIL Fourier latch clear");$finish;end
        sw[0]=1;repeat(12)@(negedge clk);
        if(motor_fault!==0 || armed!==1)begin $display("TEST FAIL Fourier fault rearm");$finish;end
        frame(2,8);
        $display("TEST PASS tb_fourier_motor");$finish;
    end
    initial begin #300000;$display("TEST FAIL timeout tb_fourier_motor");$finish;end
endmodule
