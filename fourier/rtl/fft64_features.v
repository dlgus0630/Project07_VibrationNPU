// 64-point radix-2 DIT FFT. Each butterfly shifts /2: final result is FFT(x)/64.
// Work arrays are small registers/distributed memory. Input storage is external BRAM.
module fft64_features(input wire clk,input wire rst,input wire start,
    output wire sample_en,output wire [5:0] sample_addr,input wire signed [15:0] sample_data,
    output reg busy,output reg done,output reg [31:0] features);
    localparam IDLE=0,LREQ=1,LWAIT=2,LSTORE=3,READ=4,MULT=5,WRITE=6,FACC=7,FINISH=8;
    reg [3:0] state;
    reg signed [15:0] re[0:63],im[0:63],twre[0:31],twim[0:31];
    reg [5:0] load_index,base,j,k;
    reg [2:0] stage;
    wire [6:0] span=7'd1<<stage;
    wire [5:0] half=span[6:1];
    wire [5:0] ia=base+j,ib=base+j+half;
    wire [5:0] ti=j<<(6-stage);
    reg signed [15:0] ar,ai,br,bi,wr,wi;
    wire signed [31:0] pr=br*wr,pi=bi*wi,qr=br*wi,qi=bi*wr;
    wire signed [32:0] real_product={pr[31],pr}-{pi[31],pi};
    wire signed [32:0] imag_product={qr[31],qr}+{qi[31],qi};
    reg signed [32:0] tr,tim;
    wire signed [33:0] ar_ext={{18{ar[15]}},ar},ai_ext={{18{ai[15]}},ai};
    wire signed [33:0] tr_ext={tr[32],tr},tim_ext={tim[32],tim};
    reg [31:0] sums[0:3];
    wire signed [16:0] rv={re[k][15],re[k]},iv={im[k][15],im[k]};
    wire [16:0] ra=rv[16]?-rv:rv,ma=iv[16]?-iv:iv;
    wire [17:0] mag={1'b0,ra}+{1'b0,ma};
    wire [1:0] band=(k<=6)?0:(k<=12)?1:(k<=20)?2:3;
    assign sample_en=(state==LREQ);
    assign sample_addr=load_index;
    initial begin $readmemh("tw_re.mem",twre);$readmemh("tw_im.mem",twim);end
    function [5:0] reverse6;
        input [5:0] n;
        begin reverse6={n[0],n[1],n[2],n[3],n[4],n[5]};end
    endfunction
    function [15:0] sat16_half;
        input signed [33:0] v;reg signed [33:0] q;
        begin q=v>>>1;
            if(q>32767)sat16_half=16'h7fff;
            else if(q< -32768)sat16_half=16'h8000;
            else sat16_half=q[15:0];end
    endfunction
    function [7:0] feature_q;
        input [31:0] v;
        begin if((v>>5)>127)feature_q=127;else feature_q=v[12:5];end
    endfunction
    always @(posedge clk) begin
        done<=0;
        if(rst)begin state<=IDLE;busy<=0;done<=0;features<=0;load_index<=0;stage<=1;
            base<=0;j<=0;k<=1;ar<=0;ai<=0;br<=0;bi<=0;wr<=0;wi<=0;tr<=0;tim<=0;
            sums[0]<=0;sums[1]<=0;sums[2]<=0;sums[3]<=0;end
        else case(state)
        IDLE:if(start)begin busy<=1;load_index<=0;state<=LREQ;end
        LREQ:state<=LWAIT;
        LWAIT:state<=LSTORE;
        LSTORE:begin
            re[reverse6(load_index)]<=sample_data;im[reverse6(load_index)]<=0;
            if(load_index==63)begin stage<=1;base<=0;j<=0;state<=READ;end
            else begin load_index<=load_index+1'b1;state<=LREQ;end
        end
        READ:begin ar<=re[ia];ai<=im[ia];br<=re[ib];bi<=im[ib];wr<=twre[ti];wi<=twim[ti];state<=MULT;end
        MULT:begin tr<=real_product>>>15;tim<=imag_product>>>15;state<=WRITE;end
        WRITE:begin
            re[ia]<=sat16_half(ar_ext+tr_ext);im[ia]<=sat16_half(ai_ext+tim_ext);
            re[ib]<=sat16_half(ar_ext-tr_ext);im[ib]<=sat16_half(ai_ext-tim_ext);
            if(j==half-1)begin
                j<=0;
                if({1'b0,base}+span>=64)begin
                    base<=0;
                    if(stage==6)begin k<=1;sums[0]<=0;sums[1]<=0;sums[2]<=0;sums[3]<=0;state<=FACC;end
                    else begin stage<=stage+1'b1;state<=READ;end
                end else begin base<=base+span;state<=READ;end
            end else begin j<=j+1'b1;state<=READ;end
        end
        FACC:begin sums[band]<=sums[band]+mag;if(k==31)state<=FINISH;else k<=k+1'b1;end
        FINISH:begin features<={feature_q(sums[3]),feature_q(sums[2]),feature_q(sums[1]),feature_q(sums[0])};
            busy<=0;done<=1;state<=IDLE;end
        default:begin busy<=0;state<=IDLE;end
        endcase
    end
endmodule
