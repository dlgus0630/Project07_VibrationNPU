------------------------------------------------------------
-- 안전 감시 : 연속 이상 분류와 PS heartbeat watchdog
-- 출력 : warning → derate → fault latch, 원인 비트와 진단 카운터
-- 근거 : DESIGN.md의 연속 분류/heartbeat 안전 상태 계약
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY safety_supervisor IS
   GENERIC (
      TRIP_CONSEC     : integer := 3;
      DERATE_CONSEC   : integer := 2;
      WATCHDOG_CYCLES : integer := 50000000
   );
   PORT (
      clk                : IN    std_logic;
      rst                : IN    std_logic;
      clear              : IN    std_logic;
      armed              : IN    std_logic;
      class_valid        : IN    std_logic;
      class_id           : IN    std_logic;
      heartbeat          : IN    std_logic;
      warning            : OUT   std_logic;
      derated            : OUT   std_logic;
      latched            : OUT   std_logic;
      watchdog_fault     : OUT   std_logic;
      fault_cause        : OUT   std_logic_vector(1 DOWNTO 0);
      consec_count       : OUT   std_logic_vector(7 DOWNTO 0);
      abnormal_count     : OUT   std_logic_vector(15 DOWNTO 0);
      watchdog_count_out : OUT   std_logic_vector(31 DOWNTO 0)
   );
END ENTITY safety_supervisor;

ARCHITECTURE rtl OF safety_supervisor IS

   SIGNAL watchdog_count : unsigned(31 DOWNTO 0);

BEGIN

   warning            <= '1' WHEN latched = '0' AND unsigned(consec_count) >= 1 ELSE
                         '0';
   derated            <= '1' WHEN latched = '0' AND unsigned(consec_count) >= DERATE_CONSEC ELSE
                         '0';
   watchdog_fault     <= fault_cause(1);
   watchdog_count_out <= std_logic_vector(watchdog_count);
   --------------------------------------------------------
   -- 연속 이상 횟수와 누적 이상 횟수
   -- clear는 연속 횟수만 지우고 누적 횟수는 유지한다.
   --------------------------------------------------------
   -- 연속 이상 횟수와 전체 이상 횟수. 정상 분류는 연속 횟수만 지운다.
   classification_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            consec_count   <= (OTHERS => '0');
            abnormal_count <= (OTHERS => '0');
         ELSIF (clear = '1') THEN
            consec_count <= (OTHERS => '0');
         ELSIF (class_valid = '1') THEN
            IF (class_id = '1') THEN
               IF (unsigned(abnormal_count) /= 65535) THEN
                  abnormal_count <= std_logic_vector(unsigned(abnormal_count) + 1);
               END IF;
               IF (unsigned(consec_count) < TRIP_CONSEC) THEN
                  consec_count <= std_logic_vector(unsigned(consec_count) + 1);
               END IF;
            ELSE
               consec_count <= (OTHERS => '0');
            END IF;
         END IF;
      END IF;

   END PROCESS classification_count_proc;

   -- armed 동안 heartbeat가 없었던 클럭 수를 센다.
   watchdog_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR clear = '1') THEN
            watchdog_count <= (OTHERS => '0');
         ELSIF (armed = '0' OR heartbeat = '1') THEN
            watchdog_count <= (OTHERS => '0');
         ELSIF (latched = '0' AND watchdog_count < WATCHDOG_CYCLES - 1) THEN
            watchdog_count <= watchdog_count + 1;
         END IF;
      END IF;

   END PROCESS watchdog_count_proc;

   --------------------------------------------------------
   -- 정지 latch와 원인 : 분류기/워치독이 같은 클럭에 각각 기록 가능
   --------------------------------------------------------
   -- clear 이후 새 fault 판정을 적용해 동시 발생 우선순위를 보존한다.
   fault_latch_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR clear = '1') THEN
            latched     <= '0';
            fault_cause <= (OTHERS => '0');
         ELSE
            IF (class_valid = '1' AND class_id = '1' AND unsigned(consec_count) >= TRIP_CONSEC - 1) THEN
               latched        <= '1';
               fault_cause(0) <= '1';
            END IF;
            IF (armed = '1' AND heartbeat = '0' AND latched = '0' AND watchdog_count >= WATCHDOG_CYCLES - 1) THEN
               latched        <= '1';
               fault_cause(1) <= '1';
            END IF;
         END IF;
      END IF;

   END PROCESS fault_latch_proc;

END ARCHITECTURE rtl;
