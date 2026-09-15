`timescale 1ns/1ps
module tb_safety_supervisor;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,clear=0,armed=0,class_valid=0,class_id=0,heartbeat=0;
    wire warning,derated,latched,watchdog_fault;wire [1:0] cause;
    wire [7:0] consec;wire [15:0] abnormal_count;
    integer k;
    safety_supervisor #(.TRIP_CONSEC(3),.DERATE_CONSEC(2),.WATCHDOG_CYCLES(12)) dut(
        clk,rst,clear,armed,class_valid,class_id,heartbeat,warning,derated,latched,
        watchdog_fault,cause,consec,abnormal_count);
    task classify;
        input value;
        begin @(negedge clk);class_id=value;class_valid=1;
            @(negedge clk);class_valid=0;class_id=0;@(negedge clk);end
    endtask
    task beat;
        begin @(negedge clk);heartbeat=1;@(negedge clk);heartbeat=0;end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(2)@(negedge clk);
        classify(1);
        if(!warning || derated || latched || consec!=1)begin $display("TEST FAIL safety warning");$finish;end
        classify(1);
        if(!warning || !derated || latched || consec!=2)begin $display("TEST FAIL safety derate");$finish;end
        classify(0);
        if(warning || derated || latched || consec!=0)begin $display("TEST FAIL safety recovery");$finish;end
        classify(1);classify(1);classify(1);
        if(!latched || cause!=1 || abnormal_count!=5)begin $display("TEST FAIL safety classifier trip");$finish;end
        classify(0);
        if(!latched)begin $display("TEST FAIL safety latch persistence");$finish;end
        clear=1;repeat(2)@(negedge clk);clear=0;repeat(2)@(negedge clk);
        if(latched || cause!=0 || consec!=0 || abnormal_count!=5)begin $display("TEST FAIL safety clear");$finish;end
        armed=1;
        for(k=0;k<30;k=k+1)begin beat;repeat(5)@(negedge clk);
            if(latched)begin $display("TEST FAIL safety heartbeat hold");$finish;end
        end
        repeat(14)@(negedge clk);
        if(!latched || !watchdog_fault || cause!=2)begin $display("TEST FAIL safety watchdog trip");$finish;end
        clear=1;repeat(2)@(negedge clk);clear=0;armed=0;repeat(2)@(negedge clk);
        if(latched || cause!=0)begin $display("TEST FAIL safety watchdog clear");$finish;end
        $display("TEST PASS tb_safety_supervisor");$finish;
    end
    initial begin #300000;$display("TEST FAIL timeout tb_safety_supervisor");$finish;end
endmodule
