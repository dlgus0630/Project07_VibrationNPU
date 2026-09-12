// One signed INT8 MAC per enabled clock. clear has priority and loads INT32 bias.
module mac_pe(input wire clk,input wire rst,input wire clear,input wire enable,
    input wire signed [7:0] x,input wire signed [7:0] weight,
    input wire signed [31:0] bias,output reg signed [31:0] acc);
    wire signed [15:0] product=x*weight;
    always @(posedge clk) begin
        if(rst) acc<=0;
        else if(clear) acc<=bias;
        else if(enable) acc<=acc+{{16{product[15]}},product};
    end
endmodule
