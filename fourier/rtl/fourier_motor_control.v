// Independent motor drive for vibration experiments; no PID or AXI.
// SW0 arms after OFF -> ON. SW2..1 select 0/25/50/75% duty. BTN0 stops.
// SW3 injects a controlled 32 Hz torque ripple by alternating 25/75% duty.
module fourier_motor_control #(
    parameter integer CLK_HZ=100000000,
    parameter integer FAULT_HZ=32,
    parameter integer FAULT_CONSEC=3
)(input wire clk,input wire reset_n,input wire stop_button,input wire [3:0] sw,
    output wire motor_pwm,output wire motor_in1,output wire motor_in2,
    output wire motor_armed,
    input wire class_valid,input wire class_id,output wire motor_fault);
    wire rst;
    reset_sync resetter(clk,!reset_n||stop_button,rst);
    (* ASYNC_REG="TRUE" *) reg [3:0] sw_meta,sw_sync;
    reg [2:0] warmup;
    reg seen_off,armed;
    reg [31:0] fault_count;
    reg fault_phase;
    localparam integer FAULT_HALF_CYCLES=CLK_HZ/(2*FAULT_HZ);
    wire fault_latched;wire [7:0] fault_consec;
    // SW0 low is the only operator release for the latch. BTN0 (stop_button) feeds
    // reset_sync, so rst wipes the latch too; that is safe because re-arming after any
    // stop already requires an SW0 OFF -> ON cycle, so the motor cannot restart just
    // because the fault record was cleared.
    fault_latch #(.CONSEC(FAULT_CONSEC)) fault_unit(clk,rst,class_valid,class_id,!sw_sync[0],
        fault_latched,fault_consec);
    wire enabled=armed && !rst && reset_n && !stop_button && !fault_latched;
    wire fault_inject=sw_sync[3];
    wire [12:0] selected_duty={1'b0,sw_sync[2:1],10'd0};
    wire [12:0] duty=fault_inject ? (fault_phase ? 13'd3072 : 13'd1024) : selected_duty;
    wire [12:0] active_duty;
    pwm_period #(.PERIOD(CLK_HZ/20000)) pwm_unit(clk,rst,enabled,duty,motor_pwm,active_duty);
    assign motor_in1=enabled;
    assign motor_in2=1'b0;
    assign motor_armed=enabled;
    assign motor_fault=fault_latched;
    always @(posedge clk)begin
        if(rst)begin
            sw_meta<=0;sw_sync<=0;warmup<=0;seen_off<=0;armed<=0;
            fault_count<=0;fault_phase<=0;
        end
        else begin
            sw_meta<=sw;sw_sync<=sw_meta;
            if(warmup<4)warmup<=warmup+1'b1;
            else if(!sw_sync[0])begin seen_off<=1;armed<=0;end
            else if(seen_off)armed<=1;
            if(!enabled || !fault_inject)begin fault_count<=0;fault_phase<=0;end
            else if(fault_count==FAULT_HALF_CYCLES-1)begin
                fault_count<=0;fault_phase<=~fault_phase;
            end else fault_count<=fault_count+1'b1;
        end
    end
endmodule
