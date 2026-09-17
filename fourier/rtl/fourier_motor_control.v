// Independent motor drive for vibration experiments; closed-loop speed by default.
// SW0 arms after OFF -> ON. SW2..1 select 0/25/50/75% of full-scale speed. BTN0 stops.
// SW3 injects a controlled 32 Hz torque ripple by alternating 25/75% duty.
// AXI (via axi_vibration_top) can override the PI gains, disable anti-windup, or
// drive an open-loop duty directly for system identification -- see kp_gain/
// ki_gain/anti_windup_enable/open_loop_enable/open_loop_duty above.
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
    output wire [7:0] motor_fault_consec,output wire [15:0] motor_abnormal_count,
    input wire encoder_a,input wire encoder_b,
    output wire quad_direction,output wire signed [31:0] quad_position,
    output wire quad_illegal_fault,output wire [15:0] quad_illegal_count,
    output wire quad_timeout_fault,output wire quad_overflow_fault,
    output wire [12:0] motor_speed_reference,
    output wire [12:0] motor_measured_speed,
    output wire [12:0] motor_requested_duty,
    output wire signed [31:0] motor_pid_integral,
    output wire [31:0] motor_watchdog_count,
    // Runtime PI tuning and an open-loop duty override for system identification;
    // driven from AXI, default-wired at reset to match the original fixed tuning.
    input wire signed [17:0] kp_gain,input wire signed [17:0] ki_gain,
    input wire anti_windup_enable,
    input wire open_loop_enable,input wire [12:0] open_loop_duty);
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
        motor_fault_cause,motor_fault_consec,motor_abnormal_count,motor_watchdog_count);
    wire enabled=armed && !rst && reset_n && !stop_button && !fault_latched;
    wire fault_inject=sw_sync[3];
    // Same 2-bit encoding the fixed-duty build used, now read as a PI speed target.
    wire [12:0] speed_reference={1'b0,sw_sync[2:1],10'd0};
    wire measured_encoder_pulse;
    wire [12:0] measured_speed;
    reg sample_tick;
    reg [31:0] tick_count;
    always @(posedge clk)begin
        sample_tick<=0;
        if(rst)tick_count<=0;
        else if(tick_count==CLK_HZ/100-1)begin tick_count<=0;sample_tick<=1;end
        else tick_count<=tick_count+1'b1;
    end
    wire speed_valid;
    encoder_speed_hybrid #(.CLK_HZ(CLK_HZ)) encoder(
        clk,rst,sample_tick,encoder_a,measured_speed,measured_encoder_pulse,speed_valid);
    wire pid_busy,pid_done;
    wire [12:0] pid_duty;
    wire signed [31:0] pid_integral;
    wire signed [17:0] pid_derivative;
    reg pid_start;
    wire controller_reset=rst||!enabled;
    // Gate on speed_valid, not sample_tick directly: the encoder's sample_tick ->
    // speed pipeline (added when closing timing on the watchdog-count build) now
    // takes one extra clock past sample_tick before `measured_speed` holds its new
    // value, so triggering the PID straight off sample_tick would feed it a
    // one-sample-stale reading. speed_valid pulses the same cycle measured_speed
    // is actually current, preserving the original same-cycle guarantee.
    always @(posedge clk)begin
        pid_start<=0;
        if(speed_valid && enabled && !pid_busy)pid_start<=1;
    end
    pid_fixed controller(clk,controller_reset,pid_start,speed_reference,measured_speed,
        kp_gain,ki_gain,anti_windup_enable,
        pid_busy,pid_done,pid_duty,pid_integral,pid_derivative);
    // Open-loop override (system identification) wins over everything else; SW3
    // otherwise overrides the loop output so the ripple injection stays a known
    // excitation.
    wire [12:0] requested_duty=open_loop_enable ? open_loop_duty :
        (fault_inject ? (fault_phase ? 13'd3072 : 13'd1024) : pid_duty);
    // A second consecutive abnormal window caps the drive at 25%.  A third one
    // takes enabled low through fault_latched and therefore forces PWM to zero.
    wire [12:0] duty=(motor_derated && requested_duty>13'd1024) ? 13'd1024 : requested_duty;
    // Direction and reliability check from the second channel; purely
    // observational, does not feed the PI loop or the safety supervisor. Placed
    // after `duty` is declared above so this positional instantiation doesn't
    // implicitly (and wrongly, 1-bit) declare it first.
    encoder_quadrature #(.CLK_HZ(CLK_HZ)) quadrature(
        clk,rst,!sw_sync[0],enabled,duty,encoder_a,encoder_b,
        quad_direction,quad_position,quad_illegal_fault,quad_illegal_count,
        quad_timeout_fault,quad_overflow_fault);
    wire [12:0] active_duty;
    pwm_period #(.PERIOD(CLK_HZ/20000)) pwm_unit(clk,rst,enabled,duty,motor_pwm,active_duty);
    assign motor_in1=enabled;
    assign motor_in2=1'b0;
    assign motor_armed=enabled;
    assign motor_fault=fault_latched;
    assign motor_speed_reference=speed_reference;
    assign motor_measured_speed=measured_speed;
    assign motor_requested_duty=duty;
    assign motor_pid_integral=pid_integral;
    // quad_* outputs are already top-level ports driven directly by the
    // quadrature instance above (no motor_ prefix; there is no naming clash
    // with the vibration classifier's own motor_* status signals).
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
