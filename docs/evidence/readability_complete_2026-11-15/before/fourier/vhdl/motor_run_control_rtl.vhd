------------------------------------------------------------
-- 모터 운전 명령 생성
-- 역할 : 스위치 동기화, OFF→ON arm, 100 Hz tick, PI 시작,
--        토크 리플 주입과 25% 출력 제한
-- 실제 PI 연산/안전 판정/PWM 생성은 각각의 하위 모듈이 담당한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY motor_run_control IS
   GENERIC (
      CLK_HZ   : integer := 100000000;
      FAULT_HZ : integer := 32
   );
   PORT (
      clk              : IN    std_logic;
      rst              : IN    std_logic;
      reset_n          : IN    std_logic;
      stop_button      : IN    std_logic;
      sw               : IN    std_logic_vector(3 DOWNTO 0);
      fault_latched    : IN    std_logic;
      derated          : IN    std_logic;
      speed_valid      : IN    std_logic;
      pid_busy         : IN    std_logic;
      pid_duty         : IN    std_logic_vector(12 DOWNTO 0);
      open_loop_enable : IN    std_logic;
      open_loop_duty   : IN    std_logic_vector(12 DOWNTO 0);
      armed            : OUT   std_logic;
      enabled          : OUT   std_logic;
      clear_fault      : OUT   std_logic;
      sample_tick      : OUT   std_logic;
      pid_start        : OUT   std_logic;
      speed_reference  : OUT   std_logic_vector(12 DOWNTO 0);
      duty             : OUT   std_logic_vector(12 DOWNTO 0)
   );
END ENTITY motor_run_control;

ARCHITECTURE rtl OF motor_run_control IS

   CONSTANT FAULT_HALF_CYCLES       : integer := CLK_HZ / (2 * FAULT_HZ);
   SIGNAL   sw_meta,     sw_sync    : std_logic_vector(3 DOWNTO 0);
   SIGNAL   warmup_count            : unsigned(2 DOWNTO 0);
   SIGNAL   seen_off                : std_logic;
   SIGNAL   fault_count, tick_count : unsigned(31 DOWNTO 0);
   SIGNAL   fault_phase             : std_logic;
   SIGNAL   requested_duty          : std_logic_vector(12 DOWNTO 0);
   ATTRIBUTE async_reg : string;
   ATTRIBUTE async_reg OF sw_meta, sw_sync : signal IS "TRUE";

BEGIN

   clear_fault     <= NOT sw_sync(0);
   enabled         <= armed AND NOT rst AND reset_n AND NOT stop_button AND NOT fault_latched;
   speed_reference <= '0' & sw_sync(2 DOWNTO 1) & "0000000000";

   switch_sync_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            sw_meta <= (OTHERS => '0');
            sw_sync <= (OTHERS => '0');
         ELSE
            sw_meta <= sw;
            sw_sync <= sw_meta;
         END IF;
      END IF;

   END PROCESS switch_sync_proc;

   --------------------------------------------------------
   -- arm 조건 : 시작 대기 4클럭 → SW0 OFF 확인 → SW0 ON
   --------------------------------------------------------
   arm_control_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            warmup_count <= (OTHERS => '0');
            seen_off     <= '0';
            armed        <= '0';
         ELSIF (warmup_count < 4) THEN
            warmup_count <= warmup_count + 1;
         ELSIF (sw_sync(0) = '0') THEN
            seen_off <= '1';
            armed    <= '0';
         ELSIF (seen_off = '1') THEN
            armed <= '1';
         END IF;
      END IF;

   END PROCESS arm_control_proc;

   sample_tick_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         sample_tick <= '0';
         IF (rst = '1') THEN
            tick_count <= (OTHERS => '0');
         ELSIF (tick_count = CLK_HZ / 100 - 1) THEN
            tick_count  <= (OTHERS => '0');
            sample_tick <= '1';
         ELSE
            tick_count <= tick_count + 1;
         END IF;
      END IF;

   END PROCESS sample_tick_proc;

   -- 속도 갱신이 끝난 뒤 PI를 시작한다. tick에 바로 시작하지 않는다.
   pid_start_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         pid_start <= '0';
         IF (speed_valid = '1' AND enabled = '1' AND pid_busy = '0') THEN
            pid_start <= '1';
         END IF;
      END IF;

   END PROCESS pid_start_proc;

   fault_injection_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            fault_count <= (OTHERS => '0');
            fault_phase <= '0';
         ELSIF (enabled = '0' OR sw_sync(3) = '0') THEN
            fault_count <= (OTHERS => '0');
            fault_phase <= '0';
         ELSIF (fault_count = FAULT_HALF_CYCLES - 1) THEN
            fault_count <= (OTHERS => '0');
            fault_phase <= NOT fault_phase;
         ELSE
            fault_count <= fault_count + 1;
         END IF;
      END IF;

   END PROCESS fault_injection_proc;

   --------------------------------------------------------
   -- 출력 선택 우선순위 : open-loop → SW3 리플 → PI
   -- 선택한 값에 안전 supervisor의 derating을 적용한다.
   --------------------------------------------------------
   drive_select_proc : PROCESS (ALL) IS
   BEGIN

      IF (open_loop_enable = '1') THEN
         requested_duty <= open_loop_duty;
      ELSIF (sw_sync(3) = '1') THEN
         IF (fault_phase = '1') THEN
            requested_duty <= std_logic_vector(to_unsigned(3072, 13));
         ELSE
            requested_duty <= std_logic_vector(to_unsigned(1024, 13));
         END IF;
      ELSE
         requested_duty <= pid_duty;
      END IF;

      IF (derated = '1' AND unsigned(requested_duty) > 1024) THEN
         duty <= std_logic_vector(to_unsigned(1024, 13));
      ELSE
         duty <= requested_duty;
      END IF;

   END PROCESS drive_select_proc;

END ARCHITECTURE rtl;
