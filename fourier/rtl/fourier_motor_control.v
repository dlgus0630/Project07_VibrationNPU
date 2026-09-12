// Independent fixed-duty motor drive for vibration experiments; no PID or AXI.
// SW0 arms after OFF -> ON. SW2..1 select 0/25/50/75% duty. BTN0 stops.
module fourier_motor_control #(
    parameter integer CLK_HZ=100000000
)(input wire clk,input wire reset_n,input wire stop_button,input wire [2:0] sw,
    output wire motor_pwm,output wire motor_in1,output wire motor_in2,
    output wire motor_armed);
    wire rst;
    reset_sync resetter(clk,!reset_n||stop_button,rst);
    (* ASYNC_REG="TRUE" *) reg [2:0] sw_meta,sw_sync;
    reg [2:0] warmup;
    reg seen_off,armed;
    wire enabled=armed && !rst && reset_n && !stop_button;
    wire [12:0] duty={1'b0,sw_sync[2:1],10'd0};
    wire [12:0] active_duty;
    pwm_period #(.PERIOD(CLK_HZ/20000)) pwm_unit(clk,rst,enabled,duty,motor_pwm,active_duty);
    assign motor_in1=enabled;
    assign motor_in2=1'b0;
    assign motor_armed=enabled;
    always @(posedge clk)begin
        if(rst)begin sw_meta<=0;sw_sync<=0;warmup<=0;seen_off<=0;armed<=0;end
        else begin
            sw_meta<=sw;sw_sync<=sw_meta;
            if(warmup<4)warmup<=warmup+1'b1;
            else if(!sw_sync[0])begin seen_off<=1;armed<=0;end
            else if(seen_off)armed<=1;
        end
    end
endmodule
