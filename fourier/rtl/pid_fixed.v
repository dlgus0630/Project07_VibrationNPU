// Q12 per-unit PI, Ts=10 ms. All negative divisions round toward -infinity.
module pid_fixed(input wire clk,input wire rst,input wire start,
    input wire [12:0] reference,input wire [12:0] measured,
    output reg busy,output reg done,output reg [12:0] duty,
    output reg signed [31:0] integral,output reg signed [17:0] derivative);
    // The controller runs once per 10 ms.  Split the anti-windup arithmetic
    // across clock cycles so every registered path meets the 100 MHz board clock.
    //
    // PRODUCTS/PRODUCTS_HI split (added when closing timing on the watchdog-count
    // build): the original single-cycle PRODUCTS state computed
    // i_candidate = i64 + ((3932*e64)>>>16) -- a signed 64-bit add -- and then, in
    // that same cycle, compared the raw sum against +-4096 and registered the
    // clamped/unclamped result into `candidate`.  Post-route this had WNS=-0.345ns
    // to -0.56ns depending on strategy: 15 logic levels (13xCARRY4 + 2 LUT) from the
    // i_candidate1 DSP's registered multiply output through the 64-bit add and the
    // clamp compare into candidate_reg[24].  Four Vivado strategy/AggressiveExplore
    // attempts (Flow_PerfOptimized_high/RETIMING, Performance_ExtraTimingOpt, ...)
    // could not close it because the bottleneck is logic depth inside this
    // out-of-context `motor` boundary, not placement.
    //
    // Fix: split the 64-bit add into two 32-bit adds pipelined across two states.
    // PRODUCTS registers the low 32 bits of the sum plus the carry into bit 32
    // (i_sum_lo, a plain 33-bit unsigned add of the two operands' low words --
    // this is exact bit-sliced binary addition, not an approximation: the low
    // 32 bits of any two's-complement sum equal the unsigned sum of the low
    // 32-bit words, and bit 32 of that unsigned sum is exactly the carry into the
    // next word). PRODUCTS_HI then adds the two operands' high words plus that
    // carry-in (i_sum_hi), reassembles the exact original 64-bit i_candidate value,
    // and only then performs the +-4096 clamp compare into `candidate`. Both new
    // per-cycle logic depths are far short of the 13xCARRY4 original, and the extra
    // state costs one more 10 ns clock cycle out of the controller's 10 ms period
    // (1,000,000 cycles) -- functionally invisible. Downstream consumers
    // (fourier_motor_control.v) only ever poll the busy/done handshake, never a
    // fixed cycle count, so the added latency is safe by construction; verified by
    // re-running the full XSim regression (see HANDOFF.md for the run log).
    localparam IDLE=0,FILTER=1,PRODUCTS=2,PRODUCTS_HI=3,PROPOSE_ADD=4,PROPOSE_SUB=5,
        SELECT=6,OUTPUT_ADD=7,OUTPUT_SUB=8,CLAMP=9,FINISH=10;
    reg [3:0] state;
    reg signed [17:0] error;
    reg [12:0] y_hold,y_previous;
    reg signed [31:0] p_term,d_term,candidate;
    reg signed [31:0] proposed_sum,proposed_value,selected_i;
    reg signed [31:0] output_sum,output_value;
    reg [32:0] i_sum_lo;
    wire signed [63:0] e64={{46{error[17]}},error};
    wire signed [63:0] df64={{46{derivative[17]}},derivative};
    wire signed [63:0] i64={{32{integral[31]}},integral};
    wire signed [63:0] filter_value=(64'sd3*df64+$signed({1'b0,y_hold})-$signed({1'b0,y_previous}))>>>2;
    // Same multiply/shift as before; only the final add+compare is now pipelined.
    wire signed [63:0] shifted_i_term=(64'sd3932*e64)>>>16;
    wire [31:0] i_sum_hi=i64[63:32]+shifted_i_term[63:32]+i_sum_lo[32];
    wire signed [63:0] i_candidate_full={i_sum_hi,i_sum_lo[31:0]};
    wire reject_update=((proposed_value>4096)&&(error>0))||
        ((proposed_value<0)&&(error<0));
    wire signed [31:0] chosen_i=reject_update?integral:candidate;
    always @(posedge clk)begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;duty<=0;integral<=0;derivative<=0;
            error<=0;y_hold<=0;y_previous<=0;p_term<=0;d_term<=0;candidate<=0;
            i_sum_lo<=0;
            proposed_sum<=0;proposed_value<=0;selected_i<=0;
            output_sum<=0;output_value<=0;end
        else case(state)
        IDLE:if(start)begin
            error<=$signed({1'b0,reference})-$signed({1'b0,measured});
            y_hold<=measured;busy<=1;state<=FILTER;
        end
        FILTER:begin derivative<=filter_value[17:0];y_previous<=y_hold;state<=PRODUCTS;end
        PRODUCTS:begin
            p_term<=(64'sd58982*e64)>>>16;d_term<=0;
            i_sum_lo<={1'b0,i64[31:0]}+{1'b0,shifted_i_term[31:0]};
            state<=PRODUCTS_HI;
        end
        PRODUCTS_HI:begin
            if(i_candidate_full>4096)candidate<=4096;
            else if(i_candidate_full< -4096)candidate<=-4096;else candidate<=i_candidate_full[31:0];
            state<=PROPOSE_ADD;
        end
        PROPOSE_ADD:begin proposed_sum<=p_term+candidate;state<=PROPOSE_SUB;end
        PROPOSE_SUB:begin proposed_value<=proposed_sum-d_term;state<=SELECT;end
        SELECT:begin
            integral<=chosen_i[31:0];
            selected_i<=chosen_i;state<=OUTPUT_ADD;
        end
        OUTPUT_ADD:begin output_sum<=p_term+selected_i;state<=OUTPUT_SUB;end
        OUTPUT_SUB:begin output_value<=output_sum-d_term;state<=CLAMP;end
        CLAMP:begin
            if(output_value>4096)duty<=4096;
            else if(output_value<0)duty<=0;
            else duty<=output_value[12:0];
            state<=FINISH;
        end
        FINISH:begin busy<=0;done<=1;state<=IDLE;end
        default:begin state<=IDLE;busy<=0;duty<=0;end
        endcase
    end
endmodule
