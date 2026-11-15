`timescale 1ns/1ps
// Same external stimuli into the original Verilog and VHDL motor assemblies.
module tb_motor_equivalence;
  reg clk=0; always #5 clk=~clk;
  reg reset_n=0,stop_button=0;
  reg [3:0] sw=4'b0111;
  reg class_valid=0,class_id=0,heartbeat=1,encoder_a=0,encoder_b=0;
  reg quad_wr=0; reg signed [31:0] quad_value=0;
  reg signed [17:0] kp=18'sd58982,ki=18'sd3932;
  reg anti=1,open_enable=0; reg [12:0] open_duty=0;
  wire pwm_v,in1_v,in2_v,armed_v,fault_v,warn_v,derate_v,wd_v,dir_v,ill_v,to_v,ov_v;
  wire pwm_r,in1_r,in2_r,armed_r,fault_r,warn_r,derate_r,wd_r,dir_r,ill_r,to_r,ov_r;
  wire [1:0] cause_v,cause_r; wire [7:0] consec_v,consec_r;
  wire [15:0] abnormal_v,abnormal_r,ill_count_v,ill_count_r;
  wire [12:0] speed_ref_v,speed_ref_r,speed_v,speed_r,duty_v,duty_r;
  wire [31:0] position_v,position_r,integral_v,integral_r,wd_count_v,wd_count_r;
  reg encoder_run=0,checking=0;
  fourier_motor_control #(.CLK_HZ(100000),.FAULT_HZ(1000)) dut(
    clk,reset_n,stop_button,sw,pwm_v,in1_v,in2_v,armed_v,class_valid,class_id,heartbeat,
    fault_v,warn_v,derate_v,wd_v,cause_v,consec_v,abnormal_v,encoder_a,encoder_b,quad_wr,quad_value,
    dir_v,position_v,ill_v,ill_count_v,to_v,ov_v,speed_ref_v,speed_v,duty_v,integral_v,wd_count_v,
    kp,ki,anti,open_enable,open_duty);
  fourier_motor_control_ref #(.CLK_HZ(100000),.FAULT_HZ(1000)) refdut(
    clk,reset_n,stop_button,sw,pwm_r,in1_r,in2_r,armed_r,class_valid,class_id,heartbeat,
    fault_r,warn_r,derate_r,wd_r,cause_r,consec_r,abnormal_r,encoder_a,encoder_b,quad_wr,quad_value,
    dir_r,position_r,ill_r,ill_count_r,to_r,ov_r,speed_ref_r,speed_r,duty_r,integral_r,wd_count_r,
    kp,ki,anti,open_enable,open_duty);
  always begin repeat(50) @(negedge clk); if(encoder_run) encoder_a=~encoder_a; end
  always @(posedge clk) begin
    #2;
    if(checking && {pwm_v,in1_v,in2_v,armed_v,fault_v,warn_v,derate_v,wd_v,cause_v,consec_v,abnormal_v,
      dir_v,position_v,ill_v,ill_count_v,to_v,ov_v,speed_ref_v,speed_v,duty_v,integral_v,wd_count_v} !==
      {pwm_r,in1_r,in2_r,armed_r,fault_r,warn_r,derate_r,wd_r,cause_r,consec_r,abnormal_r,
      dir_r,position_r,ill_r,ill_count_r,to_r,ov_r,speed_ref_r,speed_r,duty_r,integral_r,wd_count_r}) begin
      $display("VHDL speed=%d duty=%d integral=%d armed=%b faults=%b%b%b%b count=%d",speed_v,duty_v,integral_v,armed_v,fault_v,warn_v,derate_v,wd_v,wd_count_v);
      $display("REF  speed=%d duty=%d integral=%d armed=%b faults=%b%b%b%b count=%d",speed_r,duty_r,integral_r,armed_r,fault_r,warn_r,derate_r,wd_r,wd_count_r);
      $fatal(1,"motor output mismatch at %0t",$time);
    end
  end
  task classify(input val);
    begin @(negedge clk); class_id=val; class_valid=1; @(negedge clk); class_valid=0; class_id=0; repeat(4) @(negedge clk); end
  endtask
  initial begin
    repeat(4) @(negedge clk); reset_n=1; repeat(20) @(negedge clk); checking=1;
    sw[0]=0; repeat(12) @(negedge clk); sw[0]=1; repeat(12) @(negedge clk);
    encoder_run=1; repeat(10000) @(negedge clk);
    if(!armed_v || speed_v==0 || duty_v==0) $fatal(1,"motor not producing closed-loop output");
    sw[3]=1; repeat(200) @(negedge clk); sw[3]=0; repeat(200) @(negedge clk);
    classify(1); classify(1); classify(1); repeat(20) @(negedge clk);
    if(!fault_v || armed_v) $fatal(1,"classifier latch missing");
    sw[0]=0; repeat(20) @(negedge clk); sw[0]=1; repeat(20) @(negedge clk);
    open_enable=1; open_duty=2500; repeat(500) @(negedge clk);
    quad_wr=1; quad_value=32'sh7ffffffe; @(negedge clk); quad_wr=0;
    repeat(500) @(negedge clk); open_enable=0; anti=0;
    heartbeat=0; repeat(50100) @(negedge clk);
    if(!wd_v || !fault_v || armed_v) $fatal(1,"watchdog latch missing");
    sw[0]=0; repeat(20) @(negedge clk); heartbeat=1; sw[0]=1; repeat(100) @(negedge clk);
    stop_button=1; repeat(10) @(negedge clk); stop_button=0; repeat(50) @(negedge clk);
    $display("TEST PASS tb_motor_equivalence: cycle-by-cycle motor/safety/telemetry"); $finish;
  end
  initial begin #1000000; $fatal(1,"motor timeout"); end
endmodule
