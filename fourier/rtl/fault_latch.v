// Latches a fault after CONSEC consecutive abnormal classifications.
// Real measurements showed isolated false positives but never two in a row,
// so three consecutive abnormal windows is the trip condition.
module fault_latch #(parameter integer CONSEC=3)(
    input wire clk,input wire rst,
    input wire class_valid,   // one-cycle pulse: a new classification is ready
    input wire class_id,      // 1 = abnormal
    input wire clear,         // level; clears both the latch and the counter
    output reg latched,output reg [7:0] consec_count);
    always @(posedge clk)begin
        if(rst || clear)begin latched<=0;consec_count<=0;end
        else if(class_valid)begin
            if(class_id)begin
                // Count saturates at CONSEC so a long abnormal run cannot wrap.
                if(consec_count<CONSEC)consec_count<=consec_count+1'b1;
                if(consec_count>=CONSEC-1)latched<=1;
            end
            // A normal window only breaks the run; the latch itself survives
            // until clear (or rst) releases it.
            else consec_count<=0;
        end
    end
endmodule
