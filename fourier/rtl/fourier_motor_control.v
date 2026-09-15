// Independent motor drive for vibration experiments; no PID or AXI.
// SW0 arms after OFF -> ON. SW2..1 select 0/25/50/75% duty. BTN0 stops.
// SW3 injects a controlled 32 Hz torque ripple by alternating 25/75% duty.
module fourier_motor_control #(
    parameter integer CLK_HZ=100000000,
    parameter integer FAULT_HZ=32,
    parameter integer FAULT_CONSEC=3,
    parameter integer WATCHDOG_CYCLES=CLK_HZ/2
)(input wire clk,input wire reset_n,input wire stop_button,input wire [3:0] sw,
    output wire motor_pwm,output wire motor_in1,output wire motor_in2,
    output wire motor_armed,
    input wire class_valid,input wire class_id,input wire ps_heartbeat,
    output wire motor_fault,output wire motor_warning,output wire motor_derated,
    output wire motor_watchdog_fault,output wire [1:0] motor_fault_cause,
    output wire [7:0] motor_fault_consec,output wire [15:0] motor_abnormal_count);
    wire rst;
    reset_sync resetter(clk,!reset_n||stop_button,rst);
    (* ASYNC_REG="TRUE" *) reg [3:0] sw_meta,sw_sync;
    reg [2:0] warmup;
    reg seen_off,armed;
    reg [31:0] fault_count;
    reg fault_phase;
    localparam integer FAULT_HALF_CYCLES=CLK_HZ/(2*FAULT_HZ);
    wire fault_latched;
    // SW0 low is the operator release.  The supervisor also owns a heartbeat
    // watchdog, so loss of the Cortex-A9 application forces the same latched stop.
    safety_supervisor #(.TRIP_CONSEC(FAULT_CONSEC),.DERATE_CONSEC(2),
        .WATCHDOG_CYCLES(WATCHDOG_CYCLES)) safety_unit(
        clk,rst,!sw_sync[0],armed,class_valid,class_id,ps_heartbeat,
        motor_warning,motor_derated,fault_latched,motor_watchdog_fault,
        motor_fault_cause,motor_fault_consec,motor_abnormal_count);
    wire enabled=armed && !rst && reset_n && !stop_button && !fault_latched;
    wire fault_inject=sw_sync[3];
    wire [12:0] selected_duty={1'b0,sw_sync[2:1],10'd0};
    wire [12:0] requested_duty=fault_inject ? (fault_phase ? 13'd3072 : 13'd1024) : selected_duty;
    // A second consecutive abnormal window caps the drive at 25%.  A third one
    // takes enabled low through fault_latched and therefore forces PWM to zero.
    wire [12:0] duty=(motor_derated && requested_duty>13'd1024) ? 13'd1024 : requested_duty;
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
