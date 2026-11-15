------------------------------------------------------------
-- 진동 가속기 최상위 구조 : AXI 레지스터, FFT/NPU 코어, SPI 연결
-- U_REGS가 제어/상태를, U_CORE가 BRAM 데이터 처리를 담당한다.
-- 주소 정의는 vibration_regs.vhd에 모아 둔다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY axi_vibration_impl IS
   GENERIC (
      CLK_HZ : integer := 100000000
   );
   PORT (
      aclk                   : IN    std_logic;
      aresetn                : IN    std_logic;
      s_axi_awaddr           : IN    std_logic_vector(11 DOWNTO 0);
      s_axi_awprot           : IN    std_logic_vector(2 DOWNTO 0);
      s_axi_awvalid          : IN    std_logic;
      s_axi_awready          : OUT   std_logic;
      s_axi_wdata            : IN    std_logic_vector(31 DOWNTO 0);
      s_axi_wstrb            : IN    std_logic_vector(3 DOWNTO 0);
      s_axi_wvalid           : IN    std_logic;
      s_axi_wready           : OUT   std_logic;
      s_axi_bresp            : OUT   std_logic_vector(1 DOWNTO 0);
      s_axi_bvalid           : OUT   std_logic;
      s_axi_bready           : IN    std_logic;
      s_axi_araddr           : IN    std_logic_vector(11 DOWNTO 0);
      s_axi_arprot           : IN    std_logic_vector(2 DOWNTO 0);
      s_axi_arvalid          : IN    std_logic;
      s_axi_arready          : OUT   std_logic;
      s_axi_rdata            : OUT   std_logic_vector(31 DOWNTO 0);
      s_axi_rresp            : OUT   std_logic_vector(1 DOWNTO 0);
      s_axi_rvalid           : OUT   std_logic;
      s_axi_rready           : IN    std_logic;
      m_bram_clk             : OUT   std_logic;
      m_bram_rst             : OUT   std_logic;
      m_bram_en              : OUT   std_logic;
      m_bram_we              : OUT   std_logic_vector(3 DOWNTO 0);
      m_bram_addr            : OUT   std_logic_vector(31 DOWNTO 0);
      m_bram_wdata           : OUT   std_logic_vector(31 DOWNTO 0);
      m_bram_rdata           : IN    std_logic_vector(31 DOWNTO 0);
      mpu_sclk               : OUT   std_logic;
      mpu_mosi               : OUT   std_logic;
      mpu_miso               : IN    std_logic;
      mpu_cs_n               : OUT   std_logic;
      irq                    : OUT   std_logic;
      class_valid            : OUT   std_logic;
      class_id               : OUT   std_logic;
      motor_fault_latched    : IN    std_logic;
      motor_warning          : IN    std_logic;
      motor_derated          : IN    std_logic;
      motor_watchdog_fault   : IN    std_logic;
      motor_fault_cause      : IN    std_logic_vector(1 DOWNTO 0);
      motor_fault_consec     : IN    std_logic_vector(7 DOWNTO 0);
      motor_abnormal_count   : IN    std_logic_vector(15 DOWNTO 0);
      ps_heartbeat           : OUT   std_logic;
      motor_speed_reference  : IN    std_logic_vector(12 DOWNTO 0);
      motor_measured_speed   : IN    std_logic_vector(12 DOWNTO 0);
      motor_requested_duty   : IN    std_logic_vector(12 DOWNTO 0);
      motor_pid_integral     : IN    std_logic_vector(31 DOWNTO 0);
      motor_armed_status     : IN    std_logic;
      motor_watchdog_count   : IN    std_logic_vector(31 DOWNTO 0);
      open_loop_enable       : OUT   std_logic;
      anti_windup_enable     : OUT   std_logic;
      open_loop_duty         : OUT   std_logic_vector(12 DOWNTO 0);
      kp_gain                : OUT   std_logic_vector(17 DOWNTO 0);
      ki_gain                : OUT   std_logic_vector(17 DOWNTO 0);
      quad_direction         : IN    std_logic;
      quad_position          : IN    std_logic_vector(31 DOWNTO 0);
      quad_illegal_fault     : IN    std_logic;
      quad_illegal_count     : IN    std_logic_vector(15 DOWNTO 0);
      quad_timeout_fault     : IN    std_logic;
      quad_overflow_fault    : IN    std_logic;
      quad_position_wr_en    : OUT   std_logic;
      quad_position_wr_value : OUT   std_logic_vector(31 DOWNTO 0)
   );
   ATTRIBUTE x_interface_info : string;
   ATTRIBUTE x_interface_parameter : string;
   ATTRIBUTE x_interface_mode : string;
   ATTRIBUTE x_interface_info OF aclk : signal IS "xilinx.com:signal:clock:1.0 ACLK CLK";
   ATTRIBUTE x_interface_parameter OF aclk : signal IS
      "ASSOCIATED_BUSIF S_AXI:M_BRAM, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000";
   ATTRIBUTE x_interface_info OF aresetn : signal IS "xilinx.com:signal:reset:1.0 ARESETN RST";
   ATTRIBUTE x_interface_parameter OF aresetn : signal IS "POLARITY ACTIVE_LOW";
   ATTRIBUTE x_interface_info OF s_axi_awaddr : signal IS "xilinx.com:interface:aximm:1.0 S_AXI AWADDR";
   ATTRIBUTE x_interface_parameter OF s_axi_awaddr : signal IS "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12";
   ATTRIBUTE x_interface_info OF s_axi_awprot : signal IS "xilinx.com:interface:aximm:1.0 S_AXI AWPROT";
   ATTRIBUTE x_interface_info OF s_axi_awvalid : signal IS "xilinx.com:interface:aximm:1.0 S_AXI AWVALID";
   ATTRIBUTE x_interface_info OF s_axi_awready : signal IS "xilinx.com:interface:aximm:1.0 S_AXI AWREADY";
   ATTRIBUTE x_interface_info OF s_axi_wdata : signal IS "xilinx.com:interface:aximm:1.0 S_AXI WDATA";
   ATTRIBUTE x_interface_info OF s_axi_wstrb : signal IS "xilinx.com:interface:aximm:1.0 S_AXI WSTRB";
   ATTRIBUTE x_interface_info OF s_axi_wvalid : signal IS "xilinx.com:interface:aximm:1.0 S_AXI WVALID";
   ATTRIBUTE x_interface_info OF s_axi_wready : signal IS "xilinx.com:interface:aximm:1.0 S_AXI WREADY";
   ATTRIBUTE x_interface_info OF s_axi_bresp : signal IS "xilinx.com:interface:aximm:1.0 S_AXI BRESP";
   ATTRIBUTE x_interface_info OF s_axi_bvalid : signal IS "xilinx.com:interface:aximm:1.0 S_AXI BVALID";
   ATTRIBUTE x_interface_info OF s_axi_bready : signal IS "xilinx.com:interface:aximm:1.0 S_AXI BREADY";
   ATTRIBUTE x_interface_info OF s_axi_araddr : signal IS "xilinx.com:interface:aximm:1.0 S_AXI ARADDR";
   ATTRIBUTE x_interface_info OF s_axi_arprot : signal IS "xilinx.com:interface:aximm:1.0 S_AXI ARPROT";
   ATTRIBUTE x_interface_info OF s_axi_arvalid : signal IS "xilinx.com:interface:aximm:1.0 S_AXI ARVALID";
   ATTRIBUTE x_interface_info OF s_axi_arready : signal IS "xilinx.com:interface:aximm:1.0 S_AXI ARREADY";
   ATTRIBUTE x_interface_info OF s_axi_rdata : signal IS "xilinx.com:interface:aximm:1.0 S_AXI RDATA";
   ATTRIBUTE x_interface_info OF s_axi_rresp : signal IS "xilinx.com:interface:aximm:1.0 S_AXI RRESP";
   ATTRIBUTE x_interface_info OF s_axi_rvalid : signal IS "xilinx.com:interface:aximm:1.0 S_AXI RVALID";
   ATTRIBUTE x_interface_info OF s_axi_rready : signal IS "xilinx.com:interface:aximm:1.0 S_AXI RREADY";
   ATTRIBUTE x_interface_info OF m_bram_clk : signal IS "xilinx.com:interface:bram:1.0 M_BRAM CLK";
   ATTRIBUTE x_interface_mode OF m_bram_clk : signal IS "MASTER";
   ATTRIBUTE x_interface_parameter OF m_bram_clk : signal IS "MEM_SIZE 4096, MEM_WIDTH 32, MASTER_TYPE BRAM_CTRL";
   ATTRIBUTE x_interface_info OF m_bram_rst : signal IS "xilinx.com:interface:bram:1.0 M_BRAM RST";
   ATTRIBUTE x_interface_info OF m_bram_en : signal IS "xilinx.com:interface:bram:1.0 M_BRAM EN";
   ATTRIBUTE x_interface_info OF m_bram_we : signal IS "xilinx.com:interface:bram:1.0 M_BRAM WE";
   ATTRIBUTE x_interface_info OF m_bram_addr : signal IS "xilinx.com:interface:bram:1.0 M_BRAM ADDR";
   ATTRIBUTE x_interface_info OF m_bram_wdata : signal IS "xilinx.com:interface:bram:1.0 M_BRAM DIN";
   ATTRIBUTE x_interface_info OF m_bram_rdata : signal IS "xilinx.com:interface:bram:1.0 M_BRAM DOUT";
END ENTITY axi_vibration_impl;

------------------------------------------------------------
-- 구조 연결 : 레지스터 블록 + 가속기 코어 + SPI + MISO 동기화
-- 이 architecture는 하위 모듈과 외부 포트의 연결만 담당한다.
------------------------------------------------------------

ARCHITECTURE structural OF axi_vibration_impl IS

   SIGNAL rst : std_logic;

   -- FFT/NPU 코어 연결
   SIGNAL core_start : std_logic;
   SIGNAL core_busy : std_logic;
   SIGNAL core_done : std_logic;
   SIGNAL core_class : std_logic;
   SIGNAL total_cycles : std_logic_vector(31 DOWNTO 0);
   SIGNAL npu_cycles : std_logic_vector(31 DOWNTO 0);
   SIGNAL features : std_logic_vector(31 DOWNTO 0);
   SIGNAL hidden : std_logic_vector(31 DOWNTO 0);
   SIGNAL logits : std_logic_vector(15 DOWNTO 0);
   SIGNAL bram_word_address : std_logic_vector(9 DOWNTO 0);

   -- SPI 레지스터/엔진 연결
   SIGNAL spi_start : std_logic;
   SIGNAL spi_read : std_logic;
   SIGNAL spi_read_two : std_logic;
   SIGNAL spi_address : std_logic_vector(6 DOWNTO 0);
   SIGNAL spi_write_data : std_logic_vector(7 DOWNTO 0);
   SIGNAL spi_read_data : std_logic_vector(7 DOWNTO 0);
   SIGNAL spi_read_data16 : std_logic_vector(15 DOWNTO 0);
   SIGNAL spi_busy : std_logic;
   SIGNAL spi_done : std_logic;
   SIGNAL miso_synchronized : std_logic;

BEGIN

   -- 신호 극성/주소 단위만 연결한다. BRAM 외부 주소는 byte 단위다.
   rst         <= NOT aresetn;
   m_bram_clk  <= aclk;
   m_bram_rst  <= rst;
   m_bram_addr <= x"00000" & bram_word_address & "00";
   class_valid <= core_done;
   class_id    <= core_class;

   --------------------------------------------------------
   -- U_REGS : AXI 통신과 레지스터 갱신
   --------------------------------------------------------
   U_REGS : ENTITY work.axi_registers(rtl)
      PORT MAP (
         aclk          => aclk,
         aresetn       => aresetn,
         s_axi_awaddr  => s_axi_awaddr,
         s_axi_awvalid => s_axi_awvalid,
         s_axi_awready => s_axi_awready,
         s_axi_wdata   => s_axi_wdata,
         s_axi_wstrb   => s_axi_wstrb,
         s_axi_wvalid  => s_axi_wvalid,
         s_axi_wready  => s_axi_wready,
         s_axi_bresp   => s_axi_bresp,
         s_axi_bvalid  => s_axi_bvalid,
         s_axi_bready  => s_axi_bready,
         s_axi_araddr  => s_axi_araddr,
         s_axi_arvalid => s_axi_arvalid,
         s_axi_arready => s_axi_arready,
         s_axi_rdata   => s_axi_rdata,
         s_axi_rresp   => s_axi_rresp,
         s_axi_rvalid  => s_axi_rvalid,
         s_axi_rready  => s_axi_rready,

         core_busy   => core_busy,
         core_done   => core_done,
         core_class  => core_class,
         core_cycles => total_cycles,
         npu_cycles  => npu_cycles,
         features    => features,
         logits      => logits,
         core_start  => core_start,
         irq         => irq,

         spi_busy     => spi_busy,
         spi_done     => spi_done,
         spi_rdata    => spi_read_data,
         spi_rdata16  => spi_read_data16,
         spi_start    => spi_start,
         spi_read     => spi_read,
         spi_read_two => spi_read_two,
         spi_address  => spi_address,
         spi_wdata    => spi_write_data,

         motor_fault_latched    => motor_fault_latched,
         motor_warning          => motor_warning,
         motor_derated          => motor_derated,
         motor_watchdog_fault   => motor_watchdog_fault,
         motor_fault_cause      => motor_fault_cause,
         motor_fault_consec     => motor_fault_consec,
         motor_abnormal_count   => motor_abnormal_count,
         motor_speed_reference  => motor_speed_reference,
         motor_measured_speed   => motor_measured_speed,
         motor_requested_duty   => motor_requested_duty,
         motor_pid_integral     => motor_pid_integral,
         motor_armed_status     => motor_armed_status,
         motor_watchdog_count   => motor_watchdog_count,
         ps_heartbeat           => ps_heartbeat,
         open_loop_enable       => open_loop_enable,
         anti_windup_enable     => anti_windup_enable,
         open_loop_duty         => open_loop_duty,
         kp_gain                => kp_gain,
         ki_gain                => ki_gain,
         quad_direction         => quad_direction,
         quad_position          => quad_position,
         quad_illegal_fault     => quad_illegal_fault,
         quad_illegal_count     => quad_illegal_count,
         quad_timeout_fault     => quad_timeout_fault,
         quad_overflow_fault    => quad_overflow_fault,
         quad_position_wr_en    => quad_position_wr_en,
         quad_position_wr_value => quad_position_wr_value
      );

   --------------------------------------------------------
   -- U_CORE : FFT → NPU → BRAM 결과 저장
   --------------------------------------------------------
   U_CORE : ENTITY work.vibration_core(rtl)
      PORT MAP (
         clk        => aclk,
         rst        => rst,
         start      => core_start,
         busy       => core_busy,
         done       => core_done,
         cycles     => total_cycles,
         npu_cycles => npu_cycles,
         features   => features,
         hidden     => hidden,
         logits     => logits,
         class_id   => core_class,
         bram_en    => m_bram_en,
         bram_we    => m_bram_we,
         bram_addr  => bram_word_address,
         bram_wdata => m_bram_wdata,
         bram_rdata => m_bram_rdata
      );

   --------------------------------------------------------
   -- U_MISO_SYNC : 센서 MISO를 AXI 클럭에 동기화
   --------------------------------------------------------
   U_MISO_SYNC : ENTITY work.input_sync(rtl)
      PORT MAP (
         clk      => aclk,
         rst      => rst,
         async_in => mpu_miso,
         sync_out => miso_synchronized
      );

   --------------------------------------------------------
   -- U_SPI : SPI mode-0 송수신 엔진
   --------------------------------------------------------
   U_SPI : ENTITY work.mpu_reg_spi(rtl)
      GENERIC MAP (
         clk_hz => CLK_HZ
      )
      PORT MAP (
         clk      => aclk,
         rst      => rst,
         start    => spi_start,
         rd       => spi_read,
         read_two => spi_read_two,
         addr     => spi_address,
         wdata    => spi_write_data,
         rdata    => spi_read_data,
         rdata16  => spi_read_data16,
         busy     => spi_busy,
         done     => spi_done,
         sclk     => mpu_sclk,
         mosi     => mpu_mosi,
         miso     => miso_synchronized,
         cs_n     => mpu_cs_n
      );

END ARCHITECTURE structural;
