------------------------------------------------------------
-- AXI4-Lite 레지스터 블록
-- 역할 : AW/W 독립 수신, 쓰기 응답, 제어 레지스터, 읽기 응답
-- 근거 : DESIGN.md 주소/핸드셰이크 계약
-- 규칙 : 각 레지스터는 아래의 한 프로세스에서만 갱신한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_regs.ALL;

ENTITY axi_registers IS
   PORT (
      -- AXI4-Lite 입력/응답
      aclk          : IN    std_logic;
      aresetn       : IN    std_logic;
      s_axi_awaddr  : IN    std_logic_vector(11 DOWNTO 0);
      s_axi_awvalid : IN    std_logic;
      s_axi_awready : OUT   std_logic;
      s_axi_wdata   : IN    std_logic_vector(31 DOWNTO 0);
      s_axi_wstrb   : IN    std_logic_vector(3 DOWNTO 0);
      s_axi_wvalid  : IN    std_logic;
      s_axi_wready  : OUT   std_logic;
      s_axi_bresp   : OUT   std_logic_vector(1 DOWNTO 0);
      s_axi_bvalid  : OUT   std_logic;
      s_axi_bready  : IN    std_logic;
      s_axi_araddr  : IN    std_logic_vector(11 DOWNTO 0);
      s_axi_arvalid : IN    std_logic;
      s_axi_arready : OUT   std_logic;
      s_axi_rdata   : OUT   std_logic_vector(31 DOWNTO 0);
      s_axi_rresp   : OUT   std_logic_vector(1 DOWNTO 0);
      s_axi_rvalid  : OUT   std_logic;
      s_axi_rready  : IN    std_logic;

      -- FFT/NPU 코어 상태와 시작 명령
      core_busy   : IN    std_logic;
      core_done   : IN    std_logic;
      core_class  : IN    std_logic;
      core_cycles : IN    std_logic_vector(31 DOWNTO 0);
      npu_cycles  : IN    std_logic_vector(31 DOWNTO 0);
      features    : IN    std_logic_vector(31 DOWNTO 0);
      logits      : IN    std_logic_vector(15 DOWNTO 0);
      core_start  : OUT   std_logic;
      irq         : OUT   std_logic;

      -- SPI 엔진 명령/결과
      spi_busy     : IN    std_logic;
      spi_done     : IN    std_logic;
      spi_rdata    : IN    std_logic_vector(7 DOWNTO 0);
      spi_rdata16  : IN    std_logic_vector(15 DOWNTO 0);
      spi_start    : OUT   std_logic;
      spi_read     : OUT   std_logic;
      spi_read_two : OUT   std_logic;
      spi_address  : OUT   std_logic_vector(6 DOWNTO 0);
      spi_wdata    : OUT   std_logic_vector(7 DOWNTO 0);

      -- 모터/안전 관측값과 제어 레지스터
      motor_fault_latched    : IN    std_logic;
      motor_warning          : IN    std_logic;
      motor_derated          : IN    std_logic;
      motor_watchdog_fault   : IN    std_logic;
      motor_fault_cause      : IN    std_logic_vector(1 DOWNTO 0);
      motor_fault_consec     : IN    std_logic_vector(7 DOWNTO 0);
      motor_abnormal_count   : IN    std_logic_vector(15 DOWNTO 0);
      motor_speed_reference  : IN    std_logic_vector(12 DOWNTO 0);
      motor_measured_speed   : IN    std_logic_vector(12 DOWNTO 0);
      motor_requested_duty   : IN    std_logic_vector(12 DOWNTO 0);
      motor_pid_integral     : IN    std_logic_vector(31 DOWNTO 0);
      motor_armed_status     : IN    std_logic;
      motor_watchdog_count   : IN    std_logic_vector(31 DOWNTO 0);
      ps_heartbeat           : OUT   std_logic;
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
END ENTITY axi_registers;

ARCHITECTURE rtl OF axi_registers IS

   -- AW와 W가 다른 클럭에 도착해도 각각 보관한다.
   SIGNAL address_pending : std_logic;
   SIGNAL data_pending : std_logic;
   SIGNAL write_address : register_address;
   SIGNAL write_data : std_logic_vector(31 DOWNTO 0);
   SIGNAL write_strobes : std_logic_vector(3 DOWNTO 0);
   SIGNAL write_commit : std_logic;
   SIGNAL visible_busy : std_logic;
   SIGNAL sticky_done : std_logic;
   SIGNAL sticky_error : std_logic;
   SIGNAL spi_done_sticky : std_logic;

BEGIN

   s_axi_awready <= aresetn AND NOT address_pending AND NOT s_axi_bvalid;
   s_axi_wready  <= aresetn AND NOT data_pending AND NOT s_axi_bvalid;
   s_axi_arready <= aresetn AND NOT s_axi_rvalid;
   write_commit  <= address_pending AND data_pending AND NOT s_axi_bvalid;
   visible_busy  <= core_busy OR core_start;
   irq           <= sticky_done;

   --------------------------------------------------------
   -- 1. 쓰기 주소 보관 : address_pending, write_address
   --------------------------------------------------------
   write_address_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         IF (aresetn = '0') THEN
            address_pending <= '0';
            write_address   <= (OTHERS => '0');
         ELSE
            IF (s_axi_awready = '1' AND s_axi_awvalid = '1') THEN
               address_pending <= '1';
               write_address   <= s_axi_awaddr;
            END IF;
            IF (write_commit = '1') THEN
               address_pending <= '0';
            END IF;
         END IF;
      END IF;

   END PROCESS write_address_proc;

   --------------------------------------------------------
   -- 2. 쓰기 데이터 보관 : data_pending, data, byte strobe
   --------------------------------------------------------
   write_data_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         IF (aresetn = '0') THEN
            data_pending  <= '0';
            write_data    <= (OTHERS => '0');
            write_strobes <= (OTHERS => '0');
         ELSE
            IF (s_axi_wready = '1' AND s_axi_wvalid = '1') THEN
               data_pending  <= '1';
               write_data    <= s_axi_wdata;
               write_strobes <= s_axi_wstrb;
            END IF;
            IF (write_commit = '1') THEN
               data_pending <= '0';
            END IF;
         END IF;
      END IF;

   END PROCESS write_data_proc;

   --------------------------------------------------------
   -- 3. 쓰기 응답 : BREADY까지 BVALID/BRESP 유지
   --------------------------------------------------------
   write_response_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         IF (aresetn = '0') THEN
            s_axi_bvalid <= '0';
            s_axi_bresp  <= AXI_OKAY;
         ELSE
            IF (s_axi_bvalid = '1' AND s_axi_bready = '1') THEN
               s_axi_bvalid <= '0';
            END IF;
            IF (write_commit = '1') THEN
               s_axi_bvalid <= '1';
               s_axi_bresp  <= AXI_OKAY;

               CASE write_address IS

                  WHEN ADDR_CONTROL =>

                     IF (write_strobes(0) = '1' AND write_data(0) = '1' AND visible_busy = '1') THEN
                        s_axi_bresp <= AXI_SLVERR;
                     END IF;

                  WHEN ADDR_SPI_COMMAND =>

                     IF (write_strobes = x"F" AND write_data(31) = '1') THEN
                        IF (spi_busy = '1' OR spi_start = '1') THEN
                           s_axi_bresp <= AXI_SLVERR;
                        END IF;
                     ELSIF (write_strobes /= x"0") THEN
                        s_axi_bresp <= AXI_SLVERR;
                     END IF;

                  WHEN ADDR_HEARTBEAT | ADDR_CONTROL_2 | ADDR_OPEN_LOOP_DUTY |
                       ADDR_KP_GAIN | ADDR_KI_GAIN | ADDR_QUAD_POSITION =>

                     NULL;

                  WHEN OTHERS =>

                     s_axi_bresp <= AXI_SLVERR;

               END CASE;

            END IF;
         END IF;
      END IF;

   END PROCESS write_response_proc;

   --------------------------------------------------------
   -- 4. 제어 레지스터 쓰기와 1클럭 명령 펄스
   --------------------------------------------------------
   register_write_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         core_start          <= '0';
         spi_start           <= '0';
         ps_heartbeat        <= '0';
         quad_position_wr_en <= '0';

         IF (aresetn = '0') THEN
            spi_read               <= '0';
            spi_read_two           <= '0';
            spi_address            <= (OTHERS => '0');
            spi_wdata              <= (OTHERS => '0');
            open_loop_enable       <= '0';
            anti_windup_enable     <= '1';
            open_loop_duty         <= (OTHERS => '0');
            kp_gain                <= DEFAULT_KP;
            ki_gain                <= DEFAULT_KI;
            quad_position_wr_value <= (OTHERS => '0');
         ELSIF (write_commit = '1') THEN

            CASE write_address IS

               WHEN ADDR_CONTROL =>

                  IF (write_strobes(0) = '1' AND write_data(0) = '1' AND visible_busy = '0') THEN
                     core_start <= '1';
                  END IF;

               WHEN ADDR_SPI_COMMAND =>

                  IF (write_strobes = x"F" AND write_data(31) = '1' AND
                      spi_busy = '0' AND spi_start = '0') THEN
                     spi_read     <= write_data(7);
                     spi_read_two <= write_data(8);
                     spi_address  <= write_data(6 DOWNTO 0);
                     spi_wdata    <= write_data(23 DOWNTO 16);
                     spi_start    <= '1';
                  END IF;

               WHEN ADDR_HEARTBEAT =>

                  IF (write_strobes(0) = '1' AND write_data(0) = '1') THEN
                     ps_heartbeat <= '1';
                  END IF;

               WHEN ADDR_CONTROL_2 =>

                  IF (write_strobes(0) = '1') THEN
                     open_loop_enable   <= write_data(0);
                     anti_windup_enable <= write_data(1);
                  END IF;

               WHEN ADDR_OPEN_LOOP_DUTY =>

                  IF (write_strobes(0) = '1' OR write_strobes(1) = '1') THEN
                     open_loop_duty <= write_data(12 DOWNTO 0);
                  END IF;

               WHEN ADDR_KP_GAIN =>

                  IF (write_strobes = x"F") THEN
                     kp_gain <= write_data(17 DOWNTO 0);
                  END IF;

               WHEN ADDR_KI_GAIN =>

                  IF (write_strobes = x"F") THEN
                     ki_gain <= write_data(17 DOWNTO 0);
                  END IF;

               WHEN ADDR_QUAD_POSITION =>

                  IF (write_strobes = x"F") THEN
                     quad_position_wr_en    <= '1';
                     quad_position_wr_value <= write_data;
                  END IF;

               WHEN OTHERS =>

                  NULL;

            END CASE;

         END IF;
      END IF;

   END PROCESS register_write_proc;

   --------------------------------------------------------
   -- 5. 완료/오류 상태 보관
   -- 같은 클럭의 완료 이벤트보다 뒤에 오는 SW clear/start가 우선한다.
   --------------------------------------------------------
   status_latch_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         IF (aresetn = '0') THEN
            sticky_done     <= '0';
            sticky_error    <= '0';
            spi_done_sticky <= '0';
         ELSE
            IF (core_done = '1') THEN
               sticky_done <= '1';
            END IF;
            IF (spi_done = '1') THEN
               spi_done_sticky <= '1';
            END IF;
            IF (write_commit = '1') THEN
               IF (write_address = ADDR_CONTROL AND write_strobes(0) = '1') THEN
                  IF (write_data(1) = '1') THEN
                     sticky_done  <= '0';
                     sticky_error <= '0';
                  END IF;
                  IF (write_data(0) = '1') THEN
                     IF (visible_busy = '1') THEN
                        sticky_error <= '1';
                     ELSE
                        sticky_done  <= '0';
                        sticky_error <= '0';
                     END IF;
                  END IF;
               ELSIF (write_address = ADDR_SPI_COMMAND AND write_strobes = x"F" AND
                      write_data(31) = '1' AND spi_busy = '0' AND spi_start = '0') THEN
                  spi_done_sticky <= '0';
               END IF;
            END IF;
         END IF;
      END IF;

   END PROCESS status_latch_proc;

   --------------------------------------------------------
   -- 6. 레지스터 읽기 : AR 수신 시점의 값을 RREADY까지 유지
   --------------------------------------------------------
   register_read_proc : PROCESS (aclk) IS
   BEGIN

      IF rising_edge(aclk) THEN
         IF (aresetn = '0') THEN
            s_axi_rvalid <= '0';
            s_axi_rresp  <= AXI_OKAY;
            s_axi_rdata  <= (OTHERS => '0');
         ELSE
            IF (s_axi_rvalid = '1' AND s_axi_rready = '1') THEN
               s_axi_rvalid <= '0';
            END IF;
            IF (s_axi_arready = '1' AND s_axi_arvalid = '1') THEN
               s_axi_rvalid <= '1';
               s_axi_rresp  <= AXI_OKAY;

               CASE s_axi_araddr IS

                  WHEN ADDR_CONTROL | ADDR_HEARTBEAT =>

                     s_axi_rdata <= (OTHERS => '0');

                  WHEN ADDR_STATUS =>

                     s_axi_rdata <=
                     (
                        31 DOWNTO 7 => '0'
                     ) & motor_watchdog_fault &
                        motor_derated & motor_warning & motor_fault_latched & sticky_error & sticky_done & visible_busy;

                  WHEN ADDR_CLASS =>

                     s_axi_rdata <= (31 DOWNTO 1 => '0') & core_class;

                  WHEN ADDR_TOTAL_CYCLES =>

                     s_axi_rdata <= core_cycles;

                  WHEN ADDR_NPU_CYCLES =>

                     s_axi_rdata <= npu_cycles;

                  WHEN ADDR_FEATURE_0 =>

                     s_axi_rdata <= x"000000" & features(7 DOWNTO 0);

                  WHEN ADDR_FEATURE_1 =>

                     s_axi_rdata <= x"000000" & features(15 DOWNTO 8);

                  WHEN ADDR_FEATURE_2 =>

                     s_axi_rdata <= x"000000" & features(23 DOWNTO 16);

                  WHEN ADDR_FEATURE_3 =>

                     s_axi_rdata <= x"000000" & features(31 DOWNTO 24);

                  WHEN ADDR_LOGIT_0 =>

                     s_axi_rdata <= std_logic_vector(resize(signed(logits(7 DOWNTO 0)), 32));

                  WHEN ADDR_LOGIT_1 =>

                     s_axi_rdata <= std_logic_vector(resize(signed(logits(15 DOWNTO 8)), 32));

                  WHEN ADDR_SPI_STATUS =>

                     IF (spi_read_two = '1') THEN
                        s_axi_rdata <= (31 DOWNTO 18 => '0') & spi_done_sticky & (spi_busy OR spi_start) & spi_rdata16;
                     ELSE
                        s_axi_rdata <=
                        (
                           31 DOWNTO 18 => '0'
                        ) & spi_done_sticky &
                           (spi_busy OR spi_start
                           ) & x"00" & spi_rdata;
                     END IF;

                  WHEN ADDR_SAFETY =>

                     s_axi_rdata <= motor_abnormal_count & x"0" & motor_fault_cause &
                                    motor_derated & motor_warning & motor_fault_consec;

                  WHEN ADDR_SPEED_TARGET =>

                     s_axi_rdata <= (31 DOWNTO 13 => '0') & motor_speed_reference;

                  WHEN ADDR_SPEED_MEASURED =>

                     s_axi_rdata <= (31 DOWNTO 13 => '0') & motor_measured_speed;

                  WHEN ADDR_MOTOR_DUTY =>

                     s_axi_rdata <= (31 DOWNTO 13 => '0') & motor_requested_duty;

                  WHEN ADDR_PID_INTEGRAL =>

                     s_axi_rdata <= motor_pid_integral;

                  WHEN ADDR_MOTOR_ARMED =>

                     s_axi_rdata <= (31 DOWNTO 1 => '0') & motor_armed_status;

                  WHEN ADDR_WATCHDOG_COUNT =>

                     s_axi_rdata <= motor_watchdog_count;

                  WHEN ADDR_CONTROL_2 =>

                     s_axi_rdata <= (31 DOWNTO 2 => '0') & anti_windup_enable & open_loop_enable;

                  WHEN ADDR_OPEN_LOOP_DUTY =>

                     s_axi_rdata <= (31 DOWNTO 13 => '0') & open_loop_duty;

                  WHEN ADDR_KP_GAIN =>

                     s_axi_rdata <= std_logic_vector(resize(signed(kp_gain), 32));

                  WHEN ADDR_KI_GAIN =>

                     s_axi_rdata <= std_logic_vector(resize(signed(ki_gain), 32));

                  WHEN ADDR_QUAD_STATUS =>

                     s_axi_rdata <=
                     (
                        31 DOWNTO 4 => '0'
                     ) & quad_overflow_fault &
                        quad_timeout_fault & quad_illegal_fault & quad_direction;

                  WHEN ADDR_QUAD_POSITION =>

                     s_axi_rdata <= quad_position;

                  WHEN ADDR_QUAD_ILLEGAL =>

                     s_axi_rdata <= x"0000" & quad_illegal_count;

                  WHEN OTHERS =>

                     s_axi_rdata <= (OTHERS => '0');
                     s_axi_rresp <= AXI_SLVERR;

               END CASE;

            END IF;
         END IF;
      END IF;

   END PROCESS register_read_proc;

END ARCHITECTURE rtl;
