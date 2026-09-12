`timescale 1ns/1ps
module tb_core;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0;wire busy,done,cls,en;wire [31:0] cycles,ncycles,feat,hidden,wd;
    wire [15:0] logits;wire [3:0] we;wire [9:0] addr;reg [31:0] rd=0;
    reg [31:0] mem[0:1023];reg [15:0] samples[0:1279];reg [7:0] ff[0:79],hh[0:79],oo[0:39],cc[0:19];
    integer c,k,writes;reg launched=0;
    vibration_core dut(clk,rst,start,busy,done,cycles,ncycles,feat,hidden,logits,cls,en,we,addr,wd,rd);
    always @(posedge clk)if(en)begin
        if(we==4'hf)begin
            if(addr<256 || addr>266)begin $display("TEST FAIL illegal write");$finish;end
            mem[addr]<=wd;writes=writes+1;
        end else if(we==0)rd<=mem[addr];else begin $display("TEST FAIL byte enable");$finish;end
    end
    always @(negedge clk)if(launched && !rst && !busy && !done)begin $display("TEST FAIL busy gap");$finish;end
    initial begin
        writes=0;$readmemh("samples.mem",samples);$readmemh("features.mem",ff);$readmemh("hidden.mem",hh);
        $readmemh("logits.mem",oo);$readmemh("class.mem",cc);
        for(k=0;k<1280;k=k+1)if((^samples[k])===1'bx)begin $display("TEST FAIL missing input");$finish;end
        for(k=0;k<80;k=k+1)if((^{ff[k],hh[k]})===1'bx)begin $display("TEST FAIL missing tensor");$finish;end
        for(k=0;k<40;k=k+1)if((^oo[k])===1'bx)begin $display("TEST FAIL missing logit");$finish;end
        for(k=0;k<20;k=k+1)if((^cc[k])===1'bx)begin $display("TEST FAIL missing class");$finish;end
        repeat(4)@(negedge clk);rst=0;
        for(c=0;c<20;c=c+1)begin
            for(k=0;k<64;k=k+1)mem[k]={16'd0,samples[c*64+k]};
            for(k=256;k<=266;k=k+1)mem[k]=32'hdeadbeef;
            writes=0;@(negedge clk);start=1;@(negedge clk);start=0;launched=1;
            wait(done);launched=0;@(negedge clk);
            if(writes!=11 || busy!==0 || ncycles!==18)begin $display("TEST FAIL completion contract");$finish;end
            for(k=0;k<4;k=k+1)if(mem[256+k]!=={24'd0,ff[c*4+k]} || mem[260+k]!=={24'd0,hh[c*4+k]})begin $display("TEST FAIL BRAM tensor");$finish;end
            if(mem[264]!=={{24{oo[c*2][7]}},oo[c*2]} || mem[265]!=={{24{oo[c*2+1][7]}},oo[c*2+1]} || mem[266]!=={31'd0,cc[c][0]})begin $display("TEST FAIL BRAM results");$finish;end
            for(k=0;k<64;k=k+1)if(mem[k][15:0]!==samples[c*64+k])begin $display("TEST FAIL input modified");$finish;end
        end
        @(negedge clk);start=1;@(negedge clk);start=0;repeat(40)@(negedge clk);rst=1;
        repeat(2)@(negedge clk);if(busy!==0 || en!==0)begin $display("TEST FAIL reset abort");$finish;end
        $display("TEST PASS tb_core 20 windows, BRAM ownership, continuous busy, reset abort");$finish;
    end
    initial begin #1000000;$display("TEST FAIL timeout tb_core");$finish;end
endmodule
