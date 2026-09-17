// Quadrature direction and reliability check from encoder channels A and B.
// encoder_speed_hybrid already estimates speed magnitude from channel A alone;
// this module adds direction and three independent fault signals that a
// magnitude-only estimator cannot provide: an illegal (two-bit) Gray-code
// jump, a stall while the motor is being driven, and position-counter
// overflow. It is purely observational -- nothing here feeds back into the
// PI loop or the safety supervisor; faults are exposed on AXI for the host
// to read.
module encoder_quadrature #(
    parameter integer CLK_HZ=100000000,
    parameter integer TIMEOUT_MS=200
)(input wire clk,input wire rst,input wire clear,
    input wire enabled,input wire [12:0] duty,
    input wire encoder_a,input wire encoder_b,
    output reg direction,
    output reg signed [31:0] position,
    output reg illegal_transition_fault,output reg [15:0] illegal_transition_count,
    output reg timeout_fault,
    output reg overflow_fault);
    localparam integer TIMEOUT_CLOCKS=(CLK_HZ/1000)*TIMEOUT_MS;
    (* ASYNC_REG="TRUE" *) reg [1:0] a_sync,b_sync;
    reg [1:0] state;
    reg [31:0] timeout_count;
    wire [1:0] state_now={a_sync[1],b_sync[1]};
    wire moved=(state_now!=state);
    // Valid single-step Gray sequence: 00 -> 01 -> 11 -> 10 -> 00 is forward,
    // the reverse walk is backward. Any other change (00<->11 or 01<->10) is
    // a two-bit jump: physically impossible for real quadrature signals
    // sampled at 100 MHz against a mechanical encoder, so it means a missed
    // edge (aliasing/glitch) or a wiring fault.
    reg valid_forward,valid_backward;
    always @(*)begin
        valid_forward=0;valid_backward=0;
        // Which Gray-code walk direction is "forward" is an arbitrary choice
        // until it's checked against the real motor: on this board's C1/C2
        // wiring (measured 2026-09-16 with the motor driven closed-loop at a
        // known positive duty), the 00->10->11->01->00 walk is the one that
        // actually happens, so that's the branch mapped to valid_forward here.
        case({state,state_now})
        {2'b00,2'b10},{2'b10,2'b11},{2'b11,2'b01},{2'b01,2'b00}:valid_forward=1;
        {2'b00,2'b01},{2'b01,2'b11},{2'b11,2'b10},{2'b10,2'b00}:valid_backward=1;
        default:;
        endcase
    end
    wire signed [31:0] position_fwd=position+32'sd1;
    wire signed [31:0] position_bwd=position-32'sd1;
    wire overflow_fwd=(position[31]==1'b0)&&(position_fwd[31]==1'b1);
    wire overflow_bwd=(position[31]==1'b1)&&(position_bwd[31]==1'b0);
    always @(posedge clk)begin
        if(rst)begin
            a_sync<=0;b_sync<=0;state<=0;direction<=0;position<=0;
            illegal_transition_fault<=0;illegal_transition_count<=0;
            timeout_fault<=0;overflow_fault<=0;timeout_count<=0;
        end else begin
            a_sync<={a_sync[0],encoder_a};b_sync<={b_sync[0],encoder_b};
            if(clear)begin
                illegal_transition_fault<=0;timeout_fault<=0;overflow_fault<=0;
            end
            if(moved)begin
                state<=state_now;timeout_count<=0;
                if(valid_forward)begin
                    direction<=0;position<=position_fwd;
                    if(overflow_fwd)overflow_fault<=1;
                end else if(valid_backward)begin
                    direction<=1;position<=position_bwd;
                    if(overflow_bwd)overflow_fault<=1;
                end else begin
                    illegal_transition_fault<=1;
                    if(illegal_transition_count!=16'hffff)
                        illegal_transition_count<=illegal_transition_count+1'b1;
                end
            end else if(enabled && duty!=0)begin
                if(timeout_count>=TIMEOUT_CLOCKS-1)timeout_fault<=1;
                else timeout_count<=timeout_count+1'b1;
            end else timeout_count<=0;
        end
    end
endmodule
