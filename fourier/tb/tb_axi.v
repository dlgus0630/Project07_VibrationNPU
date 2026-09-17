`timescale 1ns/1ps
module tb_axi;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0;reg [11:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;reg [3:0] strb=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire bc,br,be;wire [3:0] bwe;wire [31:0] ba,bwd;reg [31:0] brd=0;
    wire sclk,mosi,cs,irq,cv,ci,heartbeat;reg [31:0] mem[0:1023];reg [15:0] samples[0:1279];integer k;
    integer heartbeat_seen=0;
    reg [31:0] value;
    wire open_loop_enable_probe,anti_windup_enable_probe;
    wire [12:0] open_loop_duty_probe;
    wire signed [17:0] kp_gain_probe,ki_gain_probe;
    wire quad_position_wr_en_probe;wire signed [31:0] quad_position_wr_value_probe;
    axi_vibration_top dut(clk,resetn,awaddr,3'd0,awvalid,awready,wdata,strb,wvalid,wready,bresp,bvalid,bready,
        araddr,3'd0,arvalid,arready,rdata,rresp,rvalid,rready,bc,br,be,bwe,ba,bwd,brd,sclk,mosi,1'b0,cs,irq,cv,ci,
        1'b0,1'b1,1'b1,1'b1,2'b10,8'h02,16'h1234,heartbeat,
        13'd0,13'd0,13'd0,32'sd0,1'b0,32'd0,
        open_loop_enable_probe,anti_windup_enable_probe,open_loop_duty_probe,kp_gain_probe,ki_gain_probe,
        1'b1,32'sd12345,1'b1,16'd7,1'b1,1'b1,
        quad_position_wr_en_probe,quad_position_wr_value_probe);
    always @(posedge clk)if(be)begin if(bwe==4'hf)mem[ba[11:2]]<=bwd;else brd<=mem[ba[11:2]];end
    always @(posedge clk)if(heartbeat)heartbeat_seen<=heartbeat_seen+1;
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
        wr(0,1,0,0,0);rd(4,0,value);if(value[2:0]!==0)begin $display("TEST FAIL zero WSTRB");$finish;end
        wr(12'h003,1,15,1,2);rd(12'h002,2,value);
        wr(0,1,1,1,0);wr(0,1,15,0,2);rd(4,0,value);
        if(value[2:0]!==3'b101)begin $display("TEST FAIL busy start reject");$finish;end
        wait(irq);rd(4,0,value);if(value[2:0]!==3'b110)begin $display("TEST FAIL sticky status");$finish;end
        rd(12'h020,0,value);if(value!==mem[256])begin $display("TEST FAIL AXI feature");$finish;end
        rd(12'h030,0,value);if(value!==mem[264])begin $display("TEST FAIL AXI signed logit");$finish;end
        wr(0,2,1,1,0);rd(4,0,value);if(value[2:0]!==0 || irq!==0)begin $display("TEST FAIL clear");$finish;end
        wr(12'h040,32'h800000f5,15,0,0);wr(12'h040,32'h800000f5,15,1,2);
        value=0;while(!value[17])rd(12'h044,0,value);
        if(value[16:0]!==0)begin $display("TEST FAIL SPI status");$finish;end
        wr(12'h048,1,1,0,0);repeat(3)@(negedge clk);
        if(heartbeat_seen!=1)begin $display("TEST FAIL AXI heartbeat");$finish;end
        rd(12'h04c,0,value);
        if(value!==32'h12340b02)begin $display("TEST FAIL AXI safety telemetry");$finish;end
        // PI tuning / open-loop registers: reset defaults reproduce the original
        // fixed gains, then confirm writes take effect and read back exactly.
        rd(12'h070,0,value);if(value!==32'sd58982)begin $display("TEST FAIL kp_gain reset default");$finish;end
        rd(12'h074,0,value);if(value!==32'sd3932)begin $display("TEST FAIL ki_gain reset default");$finish;end
        rd(12'h068,0,value);if(value!==32'h2)begin $display("TEST FAIL control2 reset default");$finish;end
        wr(12'h070,32'sd12345,15,0,0);rd(12'h070,0,value);
        if(value!==32'sd12345 || kp_gain_probe!==18'sd12345)begin $display("TEST FAIL kp_gain write");$finish;end
        wr(12'h074,-32'sd500,15,0,0);rd(12'h074,0,value);
        if(value!==-32'sd500 || ki_gain_probe!==-18'sd500)begin $display("TEST FAIL ki_gain write");$finish;end
        wr(12'h06c,13'd2500,15,0,0);rd(12'h06c,0,value);
        if(value!==32'd2500 || open_loop_duty_probe!==13'd2500)begin $display("TEST FAIL open_loop_duty write");$finish;end
        wr(12'h068,32'h1,15,0,0);rd(12'h068,0,value);
        if(value!==32'h1 || open_loop_enable_probe!==1 || anti_windup_enable_probe!==0)begin
            $display("TEST FAIL control2 write (open_loop on, anti-windup off)");$finish;end
        // Encoder channel-B direction/fault status is read-only, tied to fixed
        // probe values above; just confirm the register map echoes them.
        rd(12'h078,0,value);if(value!==32'hf)begin $display("TEST FAIL quad status");$finish;end
        rd(12'h07c,0,value);if(value!==32'sd12345)begin $display("TEST FAIL quad position");$finish;end
        rd(12'h080,0,value);if(value!==32'd7)begin $display("TEST FAIL quad illegal count");$finish;end
        // 0x07c is read-write: a write pulses quad_position_wr_en for one
        // cycle (encoder_quadrature.v's homing/overflow-test preset) and
        // latches the value; by the time the B response settles the pulse
        // must already have cleared.
        wr(12'h07c,32'sd2147483646,15,0,0);
        if(quad_position_wr_value_probe!==32'sd2147483646)begin
            $display("TEST FAIL quad position write value");$finish;end
        if(quad_position_wr_en_probe!==0)begin
            $display("TEST FAIL quad position write pulse did not clear");$finish;end
        $display("TEST PASS tb_axi AW/W skew, backpressure, byte strobes, busy reject, SPI status, PI tuning regs, quad status");$finish;
    end
    initial begin #2000000;$display("TEST FAIL timeout tb_axi");$finish;end
endmodule
