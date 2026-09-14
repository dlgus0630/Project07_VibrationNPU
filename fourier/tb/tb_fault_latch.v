`timescale 1ns/1ps
module tb_fault_latch;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,class_valid=0,class_id=0,clear=0;
    wire latched;wire [7:0] consec_count;
    integer k;
    fault_latch #(.CONSEC(3)) dut(clk,rst,class_valid,class_id,clear,latched,consec_count);
    task pulse;
        input value;
        begin
            @(negedge clk);class_id=value;class_valid=1;
            @(negedge clk);class_valid=0;class_id=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(2)@(negedge clk);
        if(latched!==0 || consec_count!==0)begin $display("TEST FAIL fault_latch reset state");$finish;end
        pulse(1);
        if(latched!==0 || consec_count!==1)begin $display("TEST FAIL fault_latch isolated abnormal");$finish;end
        pulse(1);pulse(0);
        if(latched!==0 || consec_count!==0)begin $display("TEST FAIL fault_latch broken run");$finish;end
        pulse(1);
        if(latched!==0)begin $display("TEST FAIL fault_latch first of run");$finish;end
        pulse(1);
        if(latched!==0)begin $display("TEST FAIL fault_latch second of run");$finish;end
        pulse(1);
        if(latched!==1 || consec_count!==3)begin $display("TEST FAIL fault_latch trip");$finish;end
        for(k=0;k<4;k=k+1)begin
            pulse(0);
            if(latched!==1)begin $display("TEST FAIL fault_latch normal must not release");$finish;end
        end
        pulse(1);pulse(1);pulse(1);pulse(1);
        if(latched!==1 || consec_count!==3)begin $display("TEST FAIL fault_latch count saturation");$finish;end
        @(negedge clk);clear=1;repeat(2)@(negedge clk);
        if(latched!==0 || consec_count!==0)begin $display("TEST FAIL fault_latch clear");$finish;end
        @(negedge clk);clear=0;repeat(2)@(negedge clk);
        if(latched!==0)begin $display("TEST FAIL fault_latch clear release");$finish;end
        pulse(1);pulse(1);
        if(latched!==0)begin $display("TEST FAIL fault_latch partial rearm");$finish;end
        pulse(1);
        if(latched!==1)begin $display("TEST FAIL fault_latch relatch");$finish;end
        @(negedge clk);clear=1;repeat(2)@(negedge clk);
        @(negedge clk);clear=0;repeat(2)@(negedge clk);
        if(latched!==0 || consec_count!==0)begin $display("TEST FAIL fault_latch second clear");$finish;end
        for(k=0;k<8;k=k+1)begin
            @(negedge clk);class_id=~class_id;
            if(latched!==0 || consec_count!==0)begin $display("TEST FAIL fault_latch idle toggle");$finish;end
        end
        @(negedge clk);class_id=0;
        pulse(1);pulse(1);
        @(negedge clk);class_id=1;repeat(6)@(negedge clk);
        if(latched!==0 || consec_count!==2)begin $display("TEST FAIL fault_latch idle level hold");$finish;end
        @(negedge clk);class_id=0;repeat(2)@(negedge clk);
        pulse(1);
        if(latched!==1 || consec_count!==3)begin $display("TEST FAIL fault_latch trip after idle");$finish;end
        $display("TEST PASS tb_fault_latch");$finish;
    end
    initial begin #300000;$display("TEST FAIL timeout tb_fault_latch");$finish;end
endmodule
