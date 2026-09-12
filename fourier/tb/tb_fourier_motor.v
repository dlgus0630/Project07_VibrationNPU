`timescale 1ns/1ps
module tb_fourier_motor;
    reg clk=0;always #5 clk=~clk;
    reg reset_n=0,stop_button=0;
    reg [2:0] sw=3'b111;
    wire pwm,in1,in2,armed;
    integer j,n;
    fourier_motor_control #(.CLK_HZ(320000)) dut(clk,reset_n,stop_button,sw,pwm,in1,in2,armed);
    task frame;
        input [1:0] setting;input integer expected;
        begin
            @(negedge clk);sw[2:1]=setting;
            repeat(40)@(negedge clk);
            while(dut.pwm_unit.count!=0)@(negedge clk);
            n=0;
            for(j=0;j<16;j=j+1)begin if(pwm)n=n+1;@(negedge clk);end
            if(n!=expected || in1!==1 || in2!==0)begin
                $display("TEST FAIL Fourier duty %d expected %d",n,expected);$finish;
            end
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        if(armed!==0 || pwm!==0)begin $display("TEST FAIL Fourier boot arm");$finish;end
        sw[0]=0;repeat(12)@(negedge clk);sw[0]=1;repeat(12)@(negedge clk);
        if(armed!==1)begin $display("TEST FAIL Fourier explicit arm");$finish;end
        frame(0,0);frame(1,4);frame(2,8);frame(3,12);
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
        $display("TEST PASS tb_fourier_motor");$finish;
    end
    initial begin #100000;$display("TEST FAIL timeout tb_fourier_motor");$finish;end
endmodule
