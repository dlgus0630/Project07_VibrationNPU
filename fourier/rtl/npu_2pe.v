module npu_2pe(input wire clk,input wire rst,input wire start,
    input wire [31:0] features,output reg busy,output reg done,
    output reg [31:0] hidden,output reg [15:0] logits,
    output reg class_id,output reg [31:0] cycles);
    localparam IDLE=0,INIT=1,MAC=2,PACK=3;
    reg [1:0] state,group_id,index;
    reg [31:0] xbuf;
    reg signed [7:0] w0[0:11],w1[0:11];
    reg signed [31:0] bias[0:5];
    reg [7:0] shifts[0:1];
    initial begin
        $readmemh("w0.mem",w0);$readmemh("w1.mem",w1);
        $readmemh("bias.mem",bias);$readmemh("shift.mem",shifts);
    end
    wire [3:0] wa={group_id,index};
    wire signed [7:0] x=(group_id==2)?hidden[index*8 +: 8]:xbuf[index*8 +: 8];
    wire signed [31:0] a0,a1;
    mac_pe p0(clk,rst,state==INIT,state==MAC,x,w0[wa],bias[group_id*2],a0);
    mac_pe p1(clk,rst,state==INIT,state==MAC,x,w1[wa],bias[group_id*2+1],a1);
    function [7:0] quant;
        input signed [31:0] value;input [7:0] shift;input relu;
        reg signed [31:0] q;
        begin
            q=value>>>shift;
            if(q>127)quant=8'd127;
            else if(relu && q<0)quant=0;
            else if(q< -128)quant=8'h80;
            else quant=q[7:0];
        end
    endfunction
    wire signed [7:0] q0=quant(a0,shifts[(group_id==2)?1:0],group_id!=2);
    wire signed [7:0] q1=quant(a1,shifts[(group_id==2)?1:0],group_id!=2);
    always @(posedge clk) begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;hidden<=0;logits<=0;class_id<=0;
            cycles<=0;group_id<=0;index<=0;xbuf<=0;end
        else begin
            if(busy)cycles<=cycles+1;
            case(state)
            IDLE: if(start)begin xbuf<=features;hidden<=0;cycles<=0;busy<=1;group_id<=0;state<=INIT;end
            INIT: begin index<=0;state<=MAC;end
            MAC: if(index==3)state<=PACK;else index<=index+1'b1;
            PACK: if(group_id==2)begin
                logits<={q1,q0};class_id<=(q1>q0);busy<=0;done<=1;state<=IDLE;
            end else begin
                hidden[group_id*16 +: 16]<={q1,q0};group_id<=group_id+1'b1;state<=INIT;
            end
            default:begin state<=IDLE;busy<=0;end
            endcase
        end
    end
endmodule
