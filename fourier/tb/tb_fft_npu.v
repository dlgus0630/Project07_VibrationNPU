`timescale 1ns/1ps
module tb_fft_npu;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0,nstart=0;
    wire en,busy,done,nbusy,ndone,cls;wire [5:0] addr;
    reg signed [15:0] rd=0;
    wire [31:0] feat,hidden,ncycles;wire [15:0] logits;
    reg [15:0] samples[0:1279],rr[0:1279],ii[0:1279];
    reg [7:0] ff[0:79],hh[0:79],oo[0:39],cc[0:19];
    integer c,k;
    fft64_features fft(clk,rst,start,en,addr,rd,busy,done,feat);
    npu_2pe npu(clk,rst,nstart,feat,nbusy,ndone,hidden,logits,cls,ncycles);
    always @(posedge clk)if(en)rd<=samples[c*64+addr];
    initial begin
        $readmemh("samples.mem",samples);$readmemh("fft_re.mem",rr);$readmemh("fft_im.mem",ii);
        $readmemh("features.mem",ff);$readmemh("hidden.mem",hh);$readmemh("logits.mem",oo);$readmemh("class.mem",cc);
        for(k=0;k<1280;k=k+1)if((^{samples[k],rr[k],ii[k]})===1'bx)begin $display("TEST FAIL missing/unknown FFT vector");$finish;end
        for(k=0;k<80;k=k+1)if((^{ff[k],hh[k]})===1'bx)begin $display("TEST FAIL missing/unknown tensor");$finish;end
        for(k=0;k<40;k=k+1)if((^oo[k])===1'bx)begin $display("TEST FAIL missing logit");$finish;end
        for(k=0;k<20;k=k+1)if((^cc[k])===1'bx)begin $display("TEST FAIL missing class");$finish;end
        c=0;repeat(4)@(negedge clk);rst=0;
        for(c=0;c<20;c=c+1)begin
            @(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
            for(k=0;k<64;k=k+1)if(fft.re[k]!==rr[c*64+k] || fft.im[k]!==ii[c*64+k])begin
                $display("TEST FAIL FFT case %d bin %d got %d %d",c,k,$signed(fft.re[k]),$signed(fft.im[k]));$finish;end
            for(k=0;k<4;k=k+1)if(feat[k*8 +: 8]!==ff[c*4+k])begin $display("TEST FAIL feature");$finish;end
            nstart=1;@(negedge clk);nstart=0;wait(ndone);@(negedge clk);
            for(k=0;k<4;k=k+1)if(hidden[k*8 +: 8]!==hh[c*4+k])begin $display("TEST FAIL hidden");$finish;end
            if(logits!=={oo[c*2+1],oo[c*2]} || cls!==cc[c][0] || ncycles!==18)begin $display("TEST FAIL NPU output/cycles");$finish;end
        end
        $display("TEST PASS tb_fft_npu 20 cases all complex bins and layer tensors");$finish;
    end
    initial begin #1000000;$display("TEST FAIL timeout tb_fft_npu");$finish;end
endmodule
