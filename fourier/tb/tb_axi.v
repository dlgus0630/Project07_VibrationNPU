`timescale 1ns/1ps
module tb_axi;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0;reg [11:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;reg [3:0] strb=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire bc,br,be;wire [3:0] bwe;wire [31:0] ba,bwd;reg [31:0] brd=0;
    wire sclk,mosi,cs,irq;reg [31:0] mem[0:1023];reg [15:0] samples[0:1279];integer k;
    reg [31:0] value;
    axi_vibration_top dut(clk,resetn,awaddr,3'd0,awvalid,awready,wdata,strb,wvalid,wready,bresp,bvalid,bready,
        araddr,3'd0,arvalid,arready,rdata,rresp,rvalid,rready,bc,br,be,bwe,ba,bwd,brd,sclk,mosi,1'b0,cs,irq);
    always @(posedge clk)if(be)begin if(bwe==4'hf)mem[ba[11:2]]<=bwd;else brd<=mem[ba[11:2]];end
    task send_aw;
        input [11:0] a;
        begin @(negedge clk);awaddr=a;awvalid=1;@(posedge clk);while(!awready)@(posedge clk);@(negedge clk);awvalid=0;end
    endtask
    task send_w;
        input [31:0] d;input [3:0] st;
        begin @(negedge clk);wdata=d;strb=st;wvalid=1;@(posedge clk);while(!wready)@(posedge clk);@(negedge clk);wvalid=0;end
    endtask
    task wr;
        input [11:0] a;input [31:0] d;input [3:0] st;input reversed;input [1:0] expected;
        begin
            if(reversed)begin send_w(d,st);repeat(3)@(negedge clk);send_aw(a);end
            else begin send_aw(a);repeat(2)@(negedge clk);send_w(d,st);end
            wait(bvalid);repeat(3)begin @(negedge clk);if(!bvalid || bresp!==expected)begin $display("TEST FAIL AXI B");$finish;end end
            bready=1;@(negedge clk);bready=0;
        end
    endtask
    task rd;
        input [11:0] a;input [1:0] expected;output [31:0] result;
        begin
            @(negedge clk);araddr=a;arvalid=1;@(posedge clk);while(!arready)@(posedge clk);
            @(negedge clk);arvalid=0;wait(rvalid);result=rdata;
            repeat(3)begin @(negedge clk);if(!rvalid || rdata!==result || rresp!==expected)begin $display("TEST FAIL AXI R");$finish;end end
            rready=1;@(negedge clk);rready=0;
        end
    endtask
    initial begin
        $readmemh("samples.mem",samples);for(k=0;k<64;k=k+1)mem[k]={16'd0,samples[k]};
        for(k=0;k<64;k=k+1)if((^samples[k])===1'bx)begin $display("TEST FAIL missing AXI input");$finish;end
        repeat(4)@(negedge clk);resetn=1;
        wr(0,1,0,0,0);rd(4,0,value);if(value!==0)begin $display("TEST FAIL zero WSTRB");$finish;end
        wr(12'h003,1,15,1,2);rd(12'h002,2,value);
        wr(0,1,1,1,0);wr(0,1,15,0,2);rd(4,0,value);
        if(value[2:0]!==3'b101)begin $display("TEST FAIL busy start reject");$finish;end
        wait(irq);rd(4,0,value);if(value[2:0]!==3'b110)begin $display("TEST FAIL sticky status");$finish;end
        rd(12'h020,0,value);if(value!==mem[256])begin $display("TEST FAIL AXI feature");$finish;end
        rd(12'h030,0,value);if(value!==mem[264])begin $display("TEST FAIL AXI signed logit");$finish;end
        wr(0,2,1,1,0);rd(4,0,value);if(value!==0 || irq!==0)begin $display("TEST FAIL clear");$finish;end
        wr(12'h040,32'h800000f5,15,0,0);wr(12'h040,32'h800000f5,15,1,2);
        value=0;while(!value[17])rd(12'h044,0,value);
        if(value[16:0]!==0)begin $display("TEST FAIL SPI status");$finish;end
        $display("TEST PASS tb_axi AW/W skew, backpressure, byte strobes, busy reject, SPI status");$finish;
    end
    initial begin #2000000;$display("TEST FAIL timeout tb_axi");$finish;end
endmodule
