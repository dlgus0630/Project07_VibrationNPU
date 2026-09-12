// Asynchronous assertion, synchronous release, plus a short FPGA power-on reset.
// This is ordinary Verilog-2001; no SystemVerilog constructs are used.
module reset_sync(
    input  wire clk,
    input  wire async_reset,
    output wire sync_reset
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_pipe;

    initial reset_pipe = 2'b11;

    always @(posedge clk or posedge async_reset) begin
        if (async_reset)
            reset_pipe <= 2'b11;
        else
            reset_pipe <= {reset_pipe[0],1'b0};
    end

    assign sync_reset = reset_pipe[1];
endmodule
