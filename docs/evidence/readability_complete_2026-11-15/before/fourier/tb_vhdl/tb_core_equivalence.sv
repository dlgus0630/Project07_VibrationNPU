`timescale 1ns/1ps
// Identical BRAM input and start pulses; compare every top-level output each cycle.
module tb_core_equivalence;
  reg clk=0; always #5 clk=~clk;
  reg rst=1,start=0,checking=0;
  wire busy_v,done_v,class_v,en_v,busy_r,done_r,class_r,en_r;
  wire [31:0] cycles_v,ncycles_v,features_v,hidden_v,wdata_v;
  wire [31:0] cycles_r,ncycles_r,features_r,hidden_r,wdata_r;
  wire [15:0] logits_v,logits_r;
  wire [3:0] we_v,we_r; wire [9:0] addr_v,addr_r;
  reg [31:0] rd=0,mem[0:1023];
  reg [15:0] samples[0:1279];
  integer c,k;
  vibration_core dut(clk,rst,start,busy_v,done_v,cycles_v,ncycles_v,features_v,hidden_v,logits_v,class_v,en_v,we_v,addr_v,wdata_v,rd);
  vibration_core_ref refdut(clk,rst,start,busy_r,done_r,cycles_r,ncycles_r,features_r,hidden_r,logits_r,class_r,en_r,we_r,addr_r,wdata_r,rd);
  always @(posedge clk) if(en_r) begin
    if(we_r==4'hf) mem[addr_r]<=wdata_r;
    else if(we_r==0) rd<=mem[addr_r];
  end
  always @(posedge clk) begin
    #2;
    if(checking && {busy_v,done_v,cycles_v,ncycles_v,features_v,hidden_v,logits_v,class_v,en_v,we_v,addr_v,wdata_v} !==
       {busy_r,done_r,cycles_r,ncycles_r,features_r,hidden_r,logits_r,class_r,en_r,we_r,addr_r,wdata_r})
      $fatal(1,"core output mismatch case=%0d t=%0t VHDL cycles=%d REF cycles=%d",c,$time,cycles_v,cycles_r);
  end
  initial begin
    $readmemh("samples.mem",samples);
    for(k=0;k<1280;k=k+1) if((^samples[k])===1'bx) $fatal(1,"missing input");
    repeat(4) @(negedge clk); rst=0; checking=1;
    for(c=0;c<20;c=c+1) begin
      for(k=0;k<64;k=k+1) mem[k]={16'd0,samples[c*64+k]};
      @(negedge clk); start=1; @(negedge clk); start=0;
      wait(done_r); @(negedge clk);
    end
    @(negedge clk); start=1; @(negedge clk); start=0; repeat(40) @(negedge clk);
    rst=1; repeat(3) @(negedge clk); rst=0; repeat(3) @(negedge clk);
    $display("TEST PASS tb_core_equivalence: 20 inputs, every output and cycle, reset abort"); $finish;
  end
  initial begin #1000000; $fatal(1,"core timeout"); end
endmodule
