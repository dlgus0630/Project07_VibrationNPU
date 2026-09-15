// PL-owned safety policy for the integrated vibration/motor system.
// One abnormal result raises warning, two consecutive results derate PWM,
// and three consecutive results latch the motor off.  A missing PS heartbeat
// independently latches the output off, so software cannot defeat the stop.
module safety_supervisor #(
    parameter integer TRIP_CONSEC=3,
    parameter integer DERATE_CONSEC=2,
    parameter integer WATCHDOG_CYCLES=50000000
)(
    input wire clk,input wire rst,input wire clear,input wire armed,
    input wire class_valid,input wire class_id,input wire heartbeat,
    output wire warning,output wire derated,output reg latched,
    output wire watchdog_fault,output reg [1:0] fault_cause,
    output reg [7:0] consec_count,output reg [15:0] abnormal_count);
    reg [31:0] watchdog_count;

    assign warning=!latched && (consec_count>=1);
    assign derated=!latched && (consec_count>=DERATE_CONSEC);
    assign watchdog_fault=fault_cause[1];

    always @(posedge clk)begin
        if(rst)begin
            latched<=0;fault_cause<=0;consec_count<=0;abnormal_count<=0;watchdog_count<=0;
        end else if(clear)begin
            // SW0 OFF releases the latch and run-length state.  Keep the lifetime
            // abnormal counter until reset so software can audit prior events.
            latched<=0;fault_cause<=0;consec_count<=0;watchdog_count<=0;
        end else begin
            if(class_valid)begin
                if(class_id)begin
                    if(abnormal_count!=16'hffff)abnormal_count<=abnormal_count+1'b1;
                    if(consec_count<TRIP_CONSEC)consec_count<=consec_count+1'b1;
                    if(consec_count>=TRIP_CONSEC-1)begin
                        latched<=1;fault_cause[0]<=1;
                    end
                end else consec_count<=0;
            end

            if(!armed)watchdog_count<=0;
            else if(heartbeat)watchdog_count<=0;
            else if(!latched)begin
                if(watchdog_count>=WATCHDOG_CYCLES-1)begin
                    watchdog_count<=watchdog_count;
                    latched<=1;fault_cause[1]<=1;
                end else watchdog_count<=watchdog_count+1'b1;
            end
        end
    end
endmodule
