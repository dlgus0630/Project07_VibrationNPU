// Duty updates only at period boundaries; enable=0 cuts the pin immediately.
module pwm_period #(parameter integer PERIOD=5000)(
    input wire clk,input wire rst,input wire enable,input wire [12:0] duty,
    output wire pwm,output reg [12:0] active_duty);
    reg [31:0] count;reg [31:0] threshold;
    wire [12:0] limited=(duty>4096)?13'd4096:duty;
    wire [63:0] scaled=(64'd1*limited*PERIOD)>>12;
    assign pwm=enable && !rst && (count<threshold);
    always @(posedge clk)begin
        if(rst || !enable)begin count<=0;threshold<=0;active_duty<=0;end
        else if(count==PERIOD-1)begin count<=0;threshold<=scaled[31:0];active_duty<=limited;end
        else count<=count+1'b1;
    end
endmodule
