`timescale 1ns/1ps
// Existing 20 Golden vectors, including all four arithmetic edge cases.
// The original Verilog test also checks internal complex bins; this mixed-
// language test checks the externally visible features and every NPU tensor.
module tb_fft_npu_vhdl;
  reg clk=0; always #5 clk=~clk;
  reg rst=1,start=0,nstart=0;
  wire en,busy,done,nbusy,ndone,cls;
  wire [5:0] addr;
  reg signed [15:0] rd=0;
  wire [31:0] feat,hidden,ncycles;
  wire [15:0] logits;
  reg [15:0] samples[0:1279];
  reg [7:0] ff[0:79],hh[0:79],oo[0:39],cc[0:19];
  integer c,k;
  fft64_features fft(clk,rst,start,en,addr,rd,busy,done,feat);
  npu_2pe npu(clk,rst,nstart,feat,nbusy,ndone,hidden,logits,cls,ncycles);
  always @(posedge clk) if(en) rd<=samples[c*64+addr];
  initial begin
    $readmemh("samples.mem",samples); $readmemh("features.mem",ff);
    $readmemh("hidden.mem",hh); $readmemh("logits.mem",oo); $readmemh("class.mem",cc);
    for(k=0;k<1280;k=k+1) if((^samples[k])===1'bx) $fatal(1,"missing input frame");
    c=0; repeat(4) @(negedge clk); rst=0;
    for(c=0;c<20;c=c+1) begin
      @(negedge clk); start=1; @(negedge clk); start=0; wait(done); @(negedge clk);
      for(k=0;k<4;k=k+1) if(feat[k*8 +: 8]!==ff[c*4+k])
        $fatal(1,"features case %0d channel %0d got %h expected %h",c,k,feat[k*8 +: 8],ff[c*4+k]);
      nstart=1; @(negedge clk); nstart=0; wait(ndone); @(negedge clk);
      for(k=0;k<4;k=k+1) if(hidden[k*8 +: 8]!==hh[c*4+k])
        $fatal(1,"hidden case %0d channel %0d got %h expected %h",c,k,hidden[k*8 +: 8],hh[c*4+k]);
      if(logits!=={oo[c*2+1],oo[c*2]} || cls!==cc[c][0] || ncycles!==18)
        $fatal(1,"output case %0d logits %h class %b cycles %0d",c,logits,cls,ncycles);
    end
    $display("TEST PASS tb_fft_npu_vhdl: 20 Golden feature/hidden/logit/class cases and NPU 18 cycles");
    $finish;
  end
  initial begin #1000000; $fatal(1,"timeout"); end
endmodule
