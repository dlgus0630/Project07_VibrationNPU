//------------------------------------------------------------
// TB: tb_axi
// TC1: AW/W 순서, strobe와 backpressure
// TC2: busy 거절, sticky 상태, SPI
// TC3: 게인·모터·직교 인코더 레지스터
// 읽기: 이름 기반 포트 → *_proc 블록 → stim_proc/timeout_proc
// _v: VHDL 출력, _r: 원본 Verilog 출력 (비교 TB)
//------------------------------------------------------------
`timescale 1ns/1ps
module tb_axi;
    reg clk = 0;
    reg resetn = 0;
    reg [11:0] awaddr = 0;
    reg [11:0] araddr = 0;
    reg awvalid = 0;
    reg wvalid = 0;
    reg bready = 0;
    reg arvalid = 0;
    reg rready = 0;
    reg [31:0] wdata = 0;
    reg [3:0] strb = 0;
    wire awready;
    wire wready;
    wire bvalid;
    wire arready;
    wire rvalid;
    wire [1:0] bresp;
    wire [1:0] rresp;
    wire [31:0] rdata;
    wire bc;
    wire br;
    wire be;
    wire [3:0] bwe;
    wire [31:0] ba;
    wire [31:0] bwd;
    reg [31:0] brd = 0;
    wire sclk;
    wire mosi;
    wire cs;
    wire irq;
    wire cv;
    wire ci;
    wire heartbeat;
    reg [31:0] mem[0:1023];
    reg [15:0] samples[0:1279];
    integer element_index;
    integer heartbeat_seen = 0;
    reg [31:0] readback_value;
    wire open_loop_enable_probe;
    wire anti_windup_enable_probe;
    wire [12:0] open_loop_duty_probe;
    wire signed [17:0] kp_gain_probe;
    wire signed [17:0] ki_gain_probe;
    wire quad_position_wr_en_probe;
    wire signed [31:0] quad_position_wr_value_probe;
    axi_vibration_top dut(
        .aclk(clk),
        .aresetn(resetn),
        .s_axi_awaddr(awaddr),
        .s_axi_awprot(3'd0),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(strb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arprot(3'd0),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .m_bram_clk(bc),
        .m_bram_rst(br),
        .m_bram_en(be),
        .m_bram_we(bwe),
        .m_bram_addr(ba),
        .m_bram_wdata(bwd),
        .m_bram_rdata(brd),
        .mpu_sclk(sclk),
        .mpu_mosi(mosi),
        .mpu_miso(1'b0),
        .mpu_cs_n(cs),
        .irq(irq),
        .class_valid(cv),
        .class_id(ci),
        .motor_fault_latched(1'b0),
        .motor_warning(1'b1),
        .motor_derated(1'b1),
        .motor_watchdog_fault(1'b1),
        .motor_fault_cause(2'b10),
        .motor_fault_consec(8'h02),
        .motor_abnormal_count(16'h1234),
        .ps_heartbeat(heartbeat),
        .motor_speed_reference(13'd0),
        .motor_measured_speed(13'd0),
        .motor_requested_duty(13'd0),
        .motor_pid_integral(32'sd0),
        .motor_armed_status(1'b0),
        .motor_watchdog_count(32'd0),
        .open_loop_enable(open_loop_enable_probe),
        .anti_windup_enable(anti_windup_enable_probe),
        .open_loop_duty(open_loop_duty_probe),
        .kp_gain(kp_gain_probe),
        .ki_gain(ki_gain_probe),
        .quad_direction(1'b1),
        .quad_position(32'sd12345),
        .quad_illegal_fault(1'b1),
        .quad_illegal_count(16'd7),
        .quad_timeout_fault(1'b1),
        .quad_overflow_fault(1'b1),
        .quad_position_wr_en(quad_position_wr_en_probe),
        .quad_position_wr_value(quad_position_wr_value_probe)
    );

    // 클럭 생성 : 다른 자극과 독립적으로 동작한다.

    always begin : clock_gen_proc
        #5 clk = ~ clk;
    end

    always begin : bram_model_proc
        @(posedge clk) if(be) begin
            if(bwe == 4'hf) begin
                mem[ba[11:2]] <= bwd;
            end
            else brd <= mem[ba[11:2]];
        end
    end

    always begin : heartbeat_check_proc
        @(posedge clk) if(heartbeat) begin
            heartbeat_seen <= heartbeat_seen + 1;
        end
    end

    task send_write_address;
        input [11:0] a;
        begin
            @(negedge clk);
            awaddr = a;
            awvalid = 1;
            @(posedge clk);
            while(! awready) begin
                @(posedge clk);
            end
            @(negedge clk);
            awvalid = 0;
        end
    endtask

    task send_write_data;
        input [31:0] d;
        input [3:0] st;
        begin
            @(negedge clk);
            wdata = d;
            strb = st;
            wvalid = 1;
            @(posedge clk);
            while(! wready) begin
                @(posedge clk);
            end
            @(negedge clk);
            wvalid = 0;
        end
    endtask

    task axi_write_and_check;
        input [11:0] a;
        input [31:0] d;
        input [3:0] st;
        input reversed;
        input [1:0] expected;
        begin
            if(reversed) begin
                send_write_data(d, st);
                repeat(3) begin
                    @(negedge clk);
                end
                send_write_address(a);
            end
            else begin
                send_write_address(a);
                repeat(2) begin
                    @(negedge clk);
                end
                send_write_data(d, st);
            end
            wait(bvalid);
            repeat(3) begin
                @(negedge clk);
                if(! bvalid || bresp !== expected) begin
                    $display("TEST FAIL AXI B");
                    $finish;
                end
            end
            bready = 1;
            @(negedge clk);
            bready = 0;
        end
    endtask

    task axi_read_and_check;
        input [11:0] a;
        input [1:0] expected;
        output [31:0] result;
        begin
            @(negedge clk);
            araddr = a;
            arvalid = 1;
            @(posedge clk);
            while(! arready) begin
                @(posedge clk);
            end
            @(negedge clk);
            arvalid = 0;
            wait(rvalid);
            result = rdata;
            repeat(3) begin
                @(negedge clk);
                if(! rvalid || rdata !== result || rresp !== expected) begin
                    $display("TEST FAIL AXI R");
                    $finish;
                end
            end
            rready = 1;
            @(negedge clk);
            rready = 0;
        end
    endtask

    initial begin : stim_proc
        $readmemh("samples.mem", samples);
        for(element_index = 0; element_index < 64; element_index = element_index + 1) begin
            mem[element_index] = {16'd0, samples[element_index]};
        end
        for(element_index = 0; element_index < 64; element_index = element_index + 1) begin
            if((^ samples[element_index]) === 1'bx) begin
                $display("TEST FAIL missing AXI input");
                $finish;
            end
        end
        repeat(4) begin
            @(negedge clk);
        end
        resetn = 1;
        axi_write_and_check(0, 1, 0, 0, 0);
        axi_read_and_check(4, 0, readback_value);
        if(readback_value[2:0] !== 0) begin
            $display("TEST FAIL zero WSTRB");
            $finish;
        end
        axi_write_and_check(12'h003, 1, 15, 1, 2);
        axi_read_and_check(12'h002, 2, readback_value);
        axi_write_and_check(0, 1, 1, 1, 0);
        axi_write_and_check(0, 1, 15, 0, 2);
        axi_read_and_check(4, 0, readback_value);
        if(readback_value[2:0] !== 3'b101) begin
            $display("TEST FAIL busy start reject");
            $finish;
        end
        wait(irq);
        axi_read_and_check(4, 0, readback_value);
        if(readback_value[2:0] !== 3'b110) begin
            $display("TEST FAIL sticky status");
            $finish;
        end
        axi_read_and_check(12'h020, 0, readback_value);
        if(readback_value !== mem[256]) begin
            $display("TEST FAIL AXI feature");
            $finish;
        end
        axi_read_and_check(12'h030, 0, readback_value);
        if(readback_value !== mem[264]) begin
            $display("TEST FAIL AXI signed logit");
            $finish;
        end
        axi_write_and_check(0, 2, 1, 1, 0);
        axi_read_and_check(4, 0, readback_value);
        if(readback_value[2:0] !== 0 || irq !== 0) begin
            $display("TEST FAIL clear");
            $finish;
        end
        axi_write_and_check(12'h040, 32'h800000f5, 15, 0, 0);
        axi_write_and_check(12'h040, 32'h800000f5, 15, 1, 2);
        readback_value = 0;
        while(! readback_value[17]) begin
            axi_read_and_check(12'h044, 0, readback_value);
        end
        if(readback_value[16:0] !== 0) begin
            $display("TEST FAIL SPI status");
            $finish;
        end
        axi_write_and_check(12'h048, 1, 1, 0, 0);
        repeat(3) begin
            @(negedge clk);
        end
        if(heartbeat_seen != 1) begin
            $display("TEST FAIL AXI heartbeat");
            $finish;
        end
        axi_read_and_check(12'h04c, 0, readback_value);
        if(readback_value !== 32'h12340b02) begin
            $display("TEST FAIL AXI safety telemetry");
            $finish;
        end
        // PI tuning / open-loop registers: reset defaults reproduce the original
        // fixed gains, then confirm writes take effect and read back exactly.
        axi_read_and_check(12'h070, 0, readback_value);
        if(readback_value !== 32'sd58982) begin
            $display("TEST FAIL kp_gain reset default");
            $finish;
        end
        axi_read_and_check(12'h074, 0, readback_value);
        if(readback_value !== 32'sd3932) begin
            $display("TEST FAIL ki_gain reset default");
            $finish;
        end
        axi_read_and_check(12'h068, 0, readback_value);
        if(readback_value !== 32'h2) begin
            $display("TEST FAIL control2 reset default");
            $finish;
        end
        axi_write_and_check(12'h070, 32'sd12345, 15, 0, 0);
        axi_read_and_check(12'h070, 0, readback_value);
        if(readback_value !== 32'sd12345 || kp_gain_probe !== 18'sd12345) begin
            $display("TEST FAIL kp_gain write");
            $finish;
        end
        axi_write_and_check(12'h074, - 32'sd500, 15, 0, 0);
        axi_read_and_check(12'h074, 0, readback_value);
        if(readback_value !== - 32'sd500 || ki_gain_probe !== - 18'sd500) begin
            $display("TEST FAIL ki_gain write");
            $finish;
        end
        axi_write_and_check(12'h06c, 13'd2500, 15, 0, 0);
        axi_read_and_check(12'h06c, 0, readback_value);
        if(readback_value !== 32'd2500 || open_loop_duty_probe !== 13'd2500) begin
            $display("TEST FAIL open_loop_duty write");
            $finish;
        end
        axi_write_and_check(12'h068, 32'h1, 15, 0, 0);
        axi_read_and_check(12'h068, 0, readback_value);
        if(readback_value !== 32'h1 || open_loop_enable_probe !== 1 || anti_windup_enable_probe !== 0) begin
            $display("TEST FAIL control2 write (open_loop on, anti-windup off)");
            $finish;
        end
        // Encoder channel-B direction/fault status is read-only, tied to fixed
        // probe values above; just confirm the register map echoes them.
        axi_read_and_check(12'h078, 0, readback_value);
        if(readback_value !== 32'hf) begin
            $display("TEST FAIL quad status");
            $finish;
        end
        axi_read_and_check(12'h07c, 0, readback_value);
        if(readback_value !== 32'sd12345) begin
            $display("TEST FAIL quad position");
            $finish;
        end
        axi_read_and_check(12'h080, 0, readback_value);
        if(readback_value !== 32'd7) begin
            $display("TEST FAIL quad illegal count");
            $finish;
        end
        // 0x07c is read-write: a write pulses quad_position_wr_en for one
        // cycle (encoder_quadrature.v's homing/overflow-test preset) and
        // latches the value; by the time the B response settles the pulse
        // must already have cleared.
        axi_write_and_check(12'h07c, 32'sd2147483646, 15, 0, 0);
        if(quad_position_wr_value_probe !== 32'sd2147483646) begin
            $display("TEST FAIL quad position write value");
            $finish;
        end
        if(quad_position_wr_en_probe !== 0) begin
            $display("TEST FAIL quad position write pulse did not clear");
            $finish;
        end
        $display("TEST PASS tb_axi AW/W skew, backpressure, byte strobes, busy reject, SPI status, PI tuning regs, quad status");
        $finish;
    end

    initial begin : timeout_proc
        #2000000;
        $display("TEST FAIL timeout tb_axi");
        $finish;
    end
endmodule
