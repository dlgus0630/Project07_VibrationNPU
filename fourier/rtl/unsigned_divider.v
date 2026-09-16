// Iterative unsigned divider: one quotient bit per clock, no combinational / operator.
module unsigned_divider #(parameter integer WIDTH=32)(
    input wire clk,input wire rst,input wire start,
    input wire [WIDTH-1:0] dividend,input wire [WIDTH-1:0] divisor,
    output reg busy,output reg done,output reg [WIDTH-1:0] quotient);
    reg [WIDTH-1:0] dividend_shift,divisor_hold,quotient_work;
    reg [WIDTH:0] remainder;
    reg [5:0] count;
    wire [WIDTH:0] shifted_remainder={remainder[WIDTH-1:0],dividend_shift[WIDTH-1]};
    wire subtract=shifted_remainder>={1'b0,divisor_hold};
    wire [WIDTH:0] next_remainder=subtract?
        shifted_remainder-{1'b0,divisor_hold}:shifted_remainder;
    wire [WIDTH-1:0] next_quotient={quotient_work[WIDTH-2:0],subtract};

    always @(posedge clk)begin
        done<=0;
        if(rst)begin
            busy<=0;done<=0;quotient<=0;dividend_shift<=0;divisor_hold<=0;
            quotient_work<=0;remainder<=0;count<=0;
        end else if(start && !busy)begin
            if(divisor==0)begin quotient<={WIDTH{1'b1}};done<=1;end
            else begin
                busy<=1;dividend_shift<=dividend;divisor_hold<=divisor;
                quotient_work<=0;remainder<=0;count<=0;
            end
        end else if(busy)begin
            dividend_shift<={dividend_shift[WIDTH-2:0],1'b0};
            remainder<=next_remainder;quotient_work<=next_quotient;
            if(count==WIDTH-1)begin quotient<=next_quotient;busy<=0;done<=1;end
            else count<=count+1'b1;
        end
    end
endmodule
