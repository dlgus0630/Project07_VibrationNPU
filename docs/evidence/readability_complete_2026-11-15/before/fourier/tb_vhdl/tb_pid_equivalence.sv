`timescale 1ns/1ps
// Compare original RTL and VHDL every clock, including clipping and reset.
module tb_pid_equivalence;
  reg clk=0; always #5 clk=~clk;
  reg rst=1,start=0,anti=1;
  reg [12:0] reference=0,measured=0;
  reg signed [17:0] kp=18'sd58982,ki=18'sd3932;
  wire busy_v,done_v,busy_r,done_r;
  wire [12:0] duty_v,duty_r;
  wire signed [31:0] int_v,int_r;
  wire signed [17:0] deriv_v,deriv_r;
  integer n,seed=20261115;
  pid_fixed dut(clk,rst,start,reference,measured,kp,ki,anti,busy_v,done_v,duty_v,int_v,deriv_v);
  pid_fixed_ref refdut(clk,rst,start,reference,measured,kp,ki,anti,busy_r,done_r,duty_r,int_r,deriv_r);
  always @(negedge clk) begin
    if(!rst && {busy_v,done_v,duty_v,int_v,deriv_v} !== {busy_r,done_r,duty_r,int_r,deriv_r})
      $fatal(1,"PID mismatch t=%0t VHDL=%h reference=%h",$time,
        {busy_v,done_v,duty_v,int_v,deriv_v},{busy_r,done_r,duty_r,int_r,deriv_r});
  end
  initial begin
    repeat(4) @(negedge clk); rst=0;
    for(n=0;n<2000;n=n+1) begin
      @(negedge clk);
      reference=$random(seed); measured=$random(seed); anti=$random(seed);
      case(n%5)
        0: begin kp=18'sd58982; ki=18'sd3932; end
        1: begin kp=18'sd131071; ki=-18'sd131072; end
        2: begin kp=-18'sd131072; ki=18'sd131071; end
        default: begin kp=$random(seed); ki=$random(seed); end
      endcase
      start=1; @(negedge clk); start=0;
      repeat(13) @(negedge clk);
      if(n%107==0) begin rst=1; @(negedge clk); rst=0; end
    end
    $display("TEST PASS tb_pid_equivalence: 2000 transactions cycle-by-cycle"); $finish;
  end
  initial begin #1000000; $fatal(1,"PID timeout"); end
endmodule
