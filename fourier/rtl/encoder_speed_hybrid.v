// Hybrid encoder estimator: reciprocal pulse period at low speed and window count at high speed.
module encoder_speed_hybrid #(
    parameter integer CLK_HZ=100000000,
    parameter integer SAMPLE_HZ=100,
    parameter integer COUNTS_FULL_SCALE=18,
    parameter integer HIGH_COUNT_THRESHOLD=14,
    parameter integer LOW_COUNT_THRESHOLD=10,
    parameter integer TIMEOUT_MS=100
)(input wire clk,input wire rst,input wire sample_tick,input wire encoder_a,
    output reg [12:0] speed,output wire pulse,output reg speed_valid);
    // speed_valid/PIPELINE split (added when closing timing on the watchdog-count
    // build, same session as the PRODUCTS/PRODUCTS_HI split in pid_fixed.v): the
    // original single-cycle sample_tick block read the live `window_total`/`pulse`
    // combinational chain straight through the bounded_count mux, the DSP48E1
    // window_product multiply, the window_speed mux, and the four-way
    // HIGH/LOW_COUNT_THRESHOLD priority-mux into `speed` in one clock. Post-route
    // this was the worst path in the design (fourier_watchdog_timing5.rpt): WNS
    // -0.413ns, 13 logic levels (CARRY4=6 DSP48E1=1 LUT3=1 LUT4=1 LUT5=4), Data
    // Path Delay 10.275ns against the 10.000ns/100MHz requirement, from
    // sync_reg[1]/C through to speed_reg[12]/D.
    //
    // Fix: split into two pipeline stages, same technique as pid_fixed.v's
    // PRODUCTS/PRODUCTS_HI split. Stage 1 (still gated by `sample_tick` itself)
    // snapshots every live signal the decision needs (window_total_snap,
    // period_valid_snap, period_timeout_snap, high_speed_mode_snap,
    // period_speed_snap) and registers the DSP48E1 multiply's output into
    // window_product_reg -- this is exact bit-sliced registration, not an
    // approximation, since bounded_count/RECIP_Q12 are unchanged, only their
    // product is now captured a cycle earlier than it's consumed. Stage 2
    // (gated by `speed_calc_pending`, one cycle later) does the threshold
    // compares and the priority mux entirely off already-registered values and
    // writes `speed`. This halves the combinational depth per cycle and removes
    // the DSP48E1 multiply from the same path as the downstream compares/mux.
    //
    // This adds exactly one extra clock (10ns) of latency between `sample_tick`
    // and `speed` updating -- against this module's 100Hz/10ms sample period
    // (1,000,000 cycles at 100MHz) that is a 0.001% latency increase, functionally
    // invisible. The one real consumer risk was fourier_motor_control.v's
    // `pid_start`, which used to fire on the exact same edge `speed` updated
    // (both driven directly off `sample_tick`); that assumption no longer holds
    // with the extra stage, so a new `speed_valid` handshake output (pulses the
    // cycle `speed` actually holds its new value, mirroring the busy/done style
    // already used by pid_fixed.v and unsigned_divider) was added and
    // fourier_motor_control.v now gates `pid_start` on `speed_valid` instead of
    // `sample_tick` directly -- see the comment there. Verified bit-exact and
    // regression-clean via the full XSim run (see HANDOFF.md for the run log).
    (* ASYNC_REG="TRUE" *) reg [1:0] sync;
    reg previous,have_edge,period_valid,high_speed_mode;
    reg [31:0] window_count,period_count,period_divisor;
    reg [12:0] period_speed;
    reg divider_start;
    wire divider_busy,divider_done;
    wire [31:0] divider_quotient;
    reg [33:0] window_product_reg;
    reg [32:0] window_total_snap;
    reg period_valid_snap,period_timeout_snap,high_speed_mode_snap;
    reg [12:0] period_speed_snap;
    reg speed_calc_pending;

    assign pulse=sync[1]&&!previous;
    wire [32:0] window_total={1'b0,window_count}+pulse;
    localparam integer RECIP_Q12=(16777216+(COUNTS_FULL_SCALE/2))/COUNTS_FULL_SCALE;
    wire [12:0] bounded_count=(window_total>=COUNTS_FULL_SCALE)?
        COUNTS_FULL_SCALE:window_total[12:0];
    wire [33:0] window_product=bounded_count*RECIP_Q12;
    // Stage-2 speed estimate: built from the registered snapshot/product only,
    // never from the live window_total/window_product wires above (those are
    // only used to feed the stage-1 snapshot registers now).
    wire [12:0] window_speed_pipelined=(window_total_snap>=COUNTS_FULL_SCALE)?
        13'd4096:window_product_reg[24:12];

    localparam [63:0] SPEED_NUMERATOR_64=
        (64'd4096*CLK_HZ)/(COUNTS_FULL_SCALE*SAMPLE_HZ);
    localparam [31:0] SPEED_NUMERATOR=SPEED_NUMERATOR_64[31:0];
    localparam integer TIMEOUT_CLOCKS=(CLK_HZ/1000)*TIMEOUT_MS;
    wire [31:0] measured_period=period_count+1'b1;
    wire [12:0] reciprocal_speed=(divider_quotient>=4096)?
        13'd4096:divider_quotient[12:0];

    unsigned_divider divider(clk,rst,divider_start,SPEED_NUMERATOR,period_divisor,
        divider_busy,divider_done,divider_quotient);

    always @(posedge clk)begin
        divider_start<=0;
        speed_valid<=0;
        if(rst)begin
            sync<=0;previous<=0;have_edge<=0;period_valid<=0;high_speed_mode<=0;
            window_count<=0;period_count<=0;period_divisor<=1;period_speed<=0;speed<=0;
            divider_start<=0;
            window_product_reg<=0;window_total_snap<=0;period_valid_snap<=0;
            period_timeout_snap<=0;high_speed_mode_snap<=0;period_speed_snap<=0;
            speed_calc_pending<=0;speed_valid<=0;
        end else begin
            sync<={sync[0],encoder_a};previous<=sync[1];
            if(have_edge && period_count!=32'hffffffff)period_count<=period_count+1'b1;
            if(pulse)begin
                if(have_edge && !divider_busy)begin
                    period_divisor<=measured_period;divider_start<=1;
                end
                period_count<=0;have_edge<=1;
                if(window_count!=32'hffffffff)window_count<=window_count+1'b1;
            end
            if(divider_done)begin
                if(!period_valid)period_speed<=reciprocal_speed;
                else if(reciprocal_speed>=period_speed)
                    period_speed<=period_speed+((reciprocal_speed-period_speed+2)>>2);
                else period_speed<=period_speed-((period_speed-reciprocal_speed+2)>>2);
                period_valid<=1;
            end
            if(have_edge && period_count>=TIMEOUT_CLOCKS-1)begin
                period_valid<=0;period_speed<=0;
            end
            if(sample_tick)begin
                // Stage 1: unchanged window reset, plus register everything the
                // stage-2 decision needs (including the DSP48E1 multiply output)
                // exactly as it stood at this sample_tick -- so stage 2, one cycle
                // later, reproduces the identical decision the old single-cycle
                // logic would have made, just split across two registers.
                window_count<=0;
                window_total_snap<=window_total;
                period_valid_snap<=period_valid;
                period_timeout_snap<=(period_count>=TIMEOUT_CLOCKS-1);
                high_speed_mode_snap<=high_speed_mode;
                period_speed_snap<=period_speed;
                window_product_reg<=window_product;
                speed_calc_pending<=1;
            end
            if(speed_calc_pending)begin
                // Stage 2: threshold compare + priority mux, entirely off the
                // stage-1 snapshot/registered product -- no DSP multiply and no
                // live window_total/window_count in this cycle's path.
                if(!period_valid_snap || period_timeout_snap)begin
                    speed<=0;high_speed_mode<=0;
                end else if(window_total_snap>=HIGH_COUNT_THRESHOLD)begin
                    speed<=window_speed_pipelined;high_speed_mode<=1;
                end else if(window_total_snap<=LOW_COUNT_THRESHOLD)begin
                    speed<=period_speed_snap;high_speed_mode<=0;
                end else if(high_speed_mode_snap)begin
                    speed<=window_speed_pipelined;
                end else begin
                    speed<=period_speed_snap;
                end
                speed_valid<=1;
                speed_calc_pending<=0;
            end
        end
    end
endmodule
