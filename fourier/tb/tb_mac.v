`timescale 1ns/1ps
module tb_mac;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,clear=0,enable=0;reg signed [7:0] x=0,w=0;
    reg signed [31:0] bias=123456;wire signed [31:0] acc;
    integer a,b,expected;
    mac_pe dut(clk,rst,clear,enable,x,w,bias,acc);
    initial begin
        repeat(4)@(negedge clk);rst=0;
        for(a=-128;a<=127;a=a+1)for(b=-128;b<=127;b=b+1)begin
            clear=1;enable=0;x=a;w=b;@(negedge clk);
            clear=0;enable=1;@(negedge clk);
            expected=123456+a*b;
            if(acc!==expected)begin $display("TEST FAIL signed MAC %d %d",a,b);$finish;end
        end
        enable=0;repeat(3)@(negedge clk);if(acc!==expected)begin $display("TEST FAIL MAC hold");$finish;end
        $display("TEST PASS tb_mac 65536 signed INT8 products plus bias and hold");$finish;
    end
    initial begin #5000000;$display("TEST FAIL timeout tb_mac");$finish;end
endmodule
