`timescale 1ns/1ps
module tb_spi;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0,rd=0,two=0,miso=0;reg [6:0] addr=0;reg [7:0] data=0;
    wire [7:0] r8;wire [15:0] r16;wire busy,done,sclk,mosi,cs;
    reg [23:0] sent;reg [15:0] reply=16'h81fe;integer n,total;
    mpu_reg_spi #(.CLK_HZ(100000000),.SPI_HZ(5000000)) dut(clk,rst,start,rd,two,addr,data,r8,r16,busy,done,sclk,mosi,miso,cs);
    always @(negedge cs)begin n=0;sent=0;miso=0;end
    always @(posedge sclk)if(!cs)begin sent={sent[22:0],mosi};n=n+1;end
    always @(negedge sclk)if(!cs)begin
        if(n>=8 && n<total)miso=reply[total-1-n];else miso=0;
    end
    task transfer;
        input read_op,input_two;input [6:0] address;input [7:0] byte_data;
        begin
            @(negedge clk);rd=read_op;two=input_two;addr=address;data=byte_data;total=input_two?24:16;start=1;
            @(negedge clk);start=0;wait(done);@(negedge clk);
            if(n!=total || cs!==1 || sclk!==0)begin $display("TEST FAIL SPI framing");$finish;end
            if(input_two)begin
                if(sent!=={read_op,address,16'd0} || r16!==reply)begin $display("TEST FAIL SPI two-byte order");$finish;end
            end else if(sent[15:0]!=={read_op,address,byte_data} || r8!==reply[7:0])begin $display("TEST FAIL SPI single byte");$finish;end
        end
    endtask
    initial begin
        total=16;repeat(4)@(negedge clk);rst=0;
        transfer(1,0,7'h75,0);transfer(0,0,7'h6b,8'h01);transfer(1,1,7'h3b,0);
        @(negedge clk);start=1;@(negedge clk);start=0;repeat(15)@(negedge clk);rst=1;
        repeat(2)@(negedge clk);if(cs!==1 || busy!==0 || sclk!==0)begin $display("TEST FAIL SPI abort");$finish;end
        $display("TEST PASS tb_spi read/write, atomic signed sample, reset abort");$finish;
    end
    initial begin #100000;$display("TEST FAIL timeout tb_spi");$finish;end
endmodule
