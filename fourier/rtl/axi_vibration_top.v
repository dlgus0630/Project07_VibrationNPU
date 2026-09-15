// AXI4-Lite control peripheral. Separate AW/W latches tolerate either arrival order.
module axi_vibration_top #(
    parameter integer CLK_HZ=100000000
)(
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 ACLK CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI:M_BRAM, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input wire aclk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 ARESETN RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
    input wire aresetn,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR", X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    input wire [11:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *) input wire [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output reg [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output reg s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [11:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output reg [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output reg s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM CLK", X_INTERFACE_MODE="MASTER", X_INTERFACE_PARAMETER="MEM_SIZE 4096, MEM_WIDTH 32, MASTER_TYPE BRAM_CTRL" *) output wire m_bram_clk,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM RST" *) output wire m_bram_rst,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM EN" *) output wire m_bram_en,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM WE" *) output wire [3:0] m_bram_we,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM ADDR" *) output wire [31:0] m_bram_addr,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM DIN" *) output wire [31:0] m_bram_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:bram:1.0 M_BRAM DOUT" *) input wire [31:0] m_bram_rdata,
    output wire mpu_sclk,output wire mpu_mosi,input wire mpu_miso,output wire mpu_cs_n,
    output wire irq,
    // Classification stream out to the motor guard, latched-fault state back in.
    output wire class_valid,output wire class_id,
    input wire motor_fault_latched,input wire motor_warning,input wire motor_derated,
    input wire motor_watchdog_fault,input wire [1:0] motor_fault_cause,
    input wire [7:0] motor_fault_consec,input wire [15:0] motor_abnormal_count,
    output reg ps_heartbeat
);
    reg aw_hold,w_hold;reg [11:0] addr_hold;reg [31:0] data_hold;reg [3:0] strb_hold;
    reg start_pulse,sticky_done,sticky_error;
    wire busy,core_done,cls;wire [31:0] cycles,ncycles,feat,hidden;wire [15:0] logits;wire [9:0] word_addr;
    wire visible_busy=busy||start_pulse;
    assign s_axi_awready=aresetn && !aw_hold && !s_axi_bvalid;
    assign s_axi_wready=aresetn && !w_hold && !s_axi_bvalid;
    assign s_axi_arready=aresetn && !s_axi_rvalid;
    assign m_bram_clk=aclk;assign m_bram_rst=!aresetn;
    assign m_bram_addr={20'd0,word_addr,2'b00}; // BRAM controller mode uses BYTE addressing.
    assign irq=sticky_done;
    assign class_valid=core_done;
    assign class_id=cls;
    vibration_core core(aclk,!aresetn,start_pulse,busy,core_done,cycles,ncycles,feat,hidden,logits,cls,
        m_bram_en,m_bram_we,word_addr,m_bram_wdata,m_bram_rdata);
    reg spi_start,spi_rd,spi_two,spi_done_sticky;reg [6:0] spi_addr;reg [7:0] spi_wdata;
    wire spi_busy,spi_done;wire [7:0] spi_r8;wire [15:0] spi_r16;
    (* ASYNC_REG="TRUE" *) reg [1:0] miso_sync;
    always @(posedge aclk)if(!aresetn)miso_sync<=0;else miso_sync<={miso_sync[0],mpu_miso};
    mpu_reg_spi #(.CLK_HZ(CLK_HZ)) spi(aclk,!aresetn,spi_start,spi_rd,spi_two,spi_addr,spi_wdata,
        spi_r8,spi_r16,spi_busy,spi_done,mpu_sclk,mpu_mosi,miso_sync[1],mpu_cs_n);
    always @(posedge aclk)begin
        start_pulse<=0;spi_start<=0;ps_heartbeat<=0;
        if(!aresetn)begin
            aw_hold<=0;w_hold<=0;addr_hold<=0;data_hold<=0;strb_hold<=0;
            s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
            sticky_done<=0;sticky_error<=0;spi_rd<=0;spi_two<=0;spi_addr<=0;spi_wdata<=0;spi_done_sticky<=0;
            ps_heartbeat<=0;
        end else begin
            if(core_done)sticky_done<=1;
            if(spi_done)spi_done_sticky<=1;
            if(s_axi_bvalid && s_axi_bready)s_axi_bvalid<=0;
            if(s_axi_rvalid && s_axi_rready)s_axi_rvalid<=0;
            if(s_axi_awready && s_axi_awvalid)begin aw_hold<=1;addr_hold<=s_axi_awaddr;end
            if(s_axi_wready && s_axi_wvalid)begin w_hold<=1;data_hold<=s_axi_wdata;strb_hold<=s_axi_wstrb;end
            if(aw_hold && w_hold && !s_axi_bvalid)begin
                aw_hold<=0;w_hold<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
                case(addr_hold)
                12'h000:if(strb_hold[0])begin
                    if(data_hold[1])begin sticky_done<=0;sticky_error<=0;end
                    if(data_hold[0])begin
                        if(visible_busy)begin sticky_error<=1;s_axi_bresp<=2;end
                        else begin start_pulse<=1;sticky_done<=0;sticky_error<=0;end
                    end
                end
                12'h040:if(strb_hold==4'hf && data_hold[31])begin
                    if(spi_busy||spi_start)s_axi_bresp<=2;
                    else begin spi_rd<=data_hold[7];spi_two<=data_hold[8];spi_addr<=data_hold[6:0];
                        spi_wdata<=data_hold[23:16];spi_start<=1;spi_done_sticky<=0;end
                end else if(strb_hold!=0)s_axi_bresp<=2;
                12'h048:if(strb_hold[0] && data_hold[0])ps_heartbeat<=1;
                default:s_axi_bresp<=2;
                endcase
            end
            if(s_axi_arready && s_axi_arvalid)begin
                s_axi_rvalid<=1;s_axi_rresp<=0;
                case(s_axi_araddr)
                12'h000:s_axi_rdata<=0;
                12'h004:s_axi_rdata<={25'd0,motor_watchdog_fault,motor_derated,motor_warning,
                    motor_fault_latched,sticky_error,sticky_done,visible_busy};
                12'h008:s_axi_rdata<={31'd0,cls};
                12'h00c:s_axi_rdata<=cycles;
                12'h010:s_axi_rdata<=ncycles;
                12'h020:s_axi_rdata<={24'd0,feat[7:0]};
                12'h024:s_axi_rdata<={24'd0,feat[15:8]};
                12'h028:s_axi_rdata<={24'd0,feat[23:16]};
                12'h02c:s_axi_rdata<={24'd0,feat[31:24]};
                12'h030:s_axi_rdata<={{24{logits[7]}},logits[7:0]};
                12'h034:s_axi_rdata<={{24{logits[15]}},logits[15:8]};
                12'h044:s_axi_rdata<={14'd0,spi_done_sticky,(spi_busy||spi_start),(spi_two?spi_r16:{8'd0,spi_r8})};
                12'h048:s_axi_rdata<=0;
                12'h04c:s_axi_rdata<={motor_abnormal_count,4'd0,motor_fault_cause,
                    motor_derated,motor_warning,motor_fault_consec};
                default:begin s_axi_rdata<=0;s_axi_rresp<=2;end
                endcase
            end
        end
    end
endmodule
