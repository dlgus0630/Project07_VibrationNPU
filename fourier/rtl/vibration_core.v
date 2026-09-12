// Owns BRAM port B from START until the final result write. PS owns port A.
module vibration_core(input wire clk,input wire rst,input wire start,
    output reg busy,output reg done,output reg [31:0] cycles,
    output wire [31:0] npu_cycles,output reg [31:0] features,
    output reg [31:0] hidden,output reg [15:0] logits,output reg class_id,
    output wire bram_en,output wire [3:0] bram_we,output wire [9:0] bram_addr,
    output reg [31:0] bram_wdata,input wire [31:0] bram_rdata);
    localparam IDLE=0,FSTART=1,FWAIT=2,NSTART=3,NWAIT=4,STORE=5;
    reg [2:0] state;reg [3:0] out_index;
    wire fen,fdone,fbusy,ndone,nbusy;wire [5:0] faddr;
    wire [31:0] feat,nhidden;wire [15:0] nlogits;wire nclass;
    fft64_features fft(clk,rst,state==FSTART,fen,faddr,bram_rdata[15:0],fbusy,fdone,feat);
    npu_2pe npu(clk,rst,state==NSTART,features,nbusy,ndone,nhidden,nlogits,nclass,npu_cycles);
    assign bram_en=(state==STORE)||fen;
    assign bram_we=(state==STORE)?4'hf:4'h0;
    assign bram_addr=(state==STORE)?10'd256+out_index:{4'd0,faddr};
    always @(*)begin
        bram_wdata=0;
        if(out_index<4)bram_wdata={24'd0,features[out_index*8 +: 8]};
        else if(out_index<8)bram_wdata={24'd0,hidden[(out_index-4)*8 +: 8]};
        else if(out_index==8)bram_wdata={{24{logits[7]}},logits[7:0]};
        else if(out_index==9)bram_wdata={{24{logits[15]}},logits[15:8]};
        else bram_wdata={31'd0,class_id};
    end
    always @(posedge clk)begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;cycles<=0;features<=0;hidden<=0;logits<=0;class_id<=0;out_index<=0;end
        else begin
            if(busy)cycles<=cycles+1;
            case(state)
            IDLE:if(start)begin busy<=1;cycles<=0;state<=FSTART;end
            FSTART:state<=FWAIT;
            FWAIT:if(fdone)begin features<=feat;state<=NSTART;end
            NSTART:state<=NWAIT;
            NWAIT:if(ndone)begin hidden<=nhidden;logits<=nlogits;class_id<=nclass;out_index<=0;state<=STORE;end
            STORE:if(out_index==10)begin busy<=0;done<=1;state<=IDLE;end else out_index<=out_index+1'b1;
            default:begin state<=IDLE;busy<=0;end
            endcase
        end
    end
endmodule
