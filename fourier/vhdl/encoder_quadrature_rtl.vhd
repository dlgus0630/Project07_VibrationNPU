------------------------------------------------------------
-- A/B 직교 인코더 : 방향, 위치와 상태 오류 감시
-- 구조 : 입력 동기화 → 위상 변화 판정 → 위치/방향 → 오류 latch
-- 위치 쓰기와 회전이 겹치면 원본과 동일하게 위치 쓰기가 우선한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY encoder_quadrature IS
   GENERIC (
      CLK_HZ     : integer := 100000000;
      TIMEOUT_MS : integer := 200
   );
   PORT (
      clk                      : IN    std_logic;
      rst                      : IN    std_logic;
      clear                    : IN    std_logic;
      enabled                  : IN    std_logic;
      duty                     : IN    std_logic_vector(12 DOWNTO 0);
      encoder_a                : IN    std_logic;
      encoder_b                : IN    std_logic;
      position_wr_en           : IN    std_logic;
      position_wr_value        : IN    std_logic_vector(31 DOWNTO 0);
      direction                : OUT   std_logic;
      position                 : OUT   std_logic_vector(31 DOWNTO 0);
      illegal_transition_fault : OUT   std_logic;
      illegal_transition_count : OUT   std_logic_vector(15 DOWNTO 0);
      timeout_fault            : OUT   std_logic;
      overflow_fault           : OUT   std_logic
   );
END ENTITY encoder_quadrature;

ARCHITECTURE rtl OF encoder_quadrature IS

   CONSTANT TIMEOUT_CLOCKS : integer := (CLK_HZ / 1000) * TIMEOUT_MS;
   SIGNAL a_sync : std_logic_vector(1 DOWNTO 0);
   SIGNAL b_sync : std_logic_vector(1 DOWNTO 0);
   SIGNAL state : std_logic_vector(1 DOWNTO 0);
   SIGNAL state_now : std_logic_vector(1 DOWNTO 0);
   SIGNAL timeout_count : unsigned(31 DOWNTO 0);
   SIGNAL moved : std_logic;
   SIGNAL valid_forward : std_logic;
   SIGNAL valid_backward : std_logic;
   SIGNAL overflow_fwd : std_logic;
   SIGNAL overflow_bwd : std_logic;
   SIGNAL position_fwd, position_bwd : signed(31 DOWNTO 0);
   ATTRIBUTE async_reg : string;
   ATTRIBUTE async_reg OF a_sync, b_sync : signal IS "TRUE";

BEGIN

   state_now      <= a_sync(1) & b_sync(1);
   moved          <= bit_if(state_now /= state);
   -- 이전 A/B 두 비트 + 현재 A/B 두 비트로 방향을 판정한다.
   phase_decode_comb_proc : PROCESS (ALL) IS
      VARIABLE transition : std_logic_vector(3 DOWNTO 0);
   BEGIN
      transition := state & state_now;
      valid_forward <= '0';
      valid_backward <= '0';
      CASE transition IS
         WHEN "0010" | "1011" | "1101" | "0100" =>
            valid_forward <= '1';
         WHEN "0001" | "0111" | "1110" | "1000" =>
            valid_backward <= '1';
         WHEN OTHERS =>
            NULL;
      END CASE;
   END PROCESS phase_decode_comb_proc;
   position_fwd   <= signed(position) + 1;
   position_bwd   <= signed(position) - 1;
   overflow_fwd   <= NOT position(31) AND position_fwd(31);
   overflow_bwd   <= position(31) AND NOT position_bwd(31);

   -- A/B 입력은 각각 두 플립플롭을 통과한다.
   encoder_sync_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            a_sync <= (OTHERS => '0');
            b_sync <= (OTHERS => '0');
         ELSE
            a_sync <= a_sync(0) & encoder_a;
            b_sync <= b_sync(0) & encoder_b;
         END IF;
      END IF;

   END PROCESS encoder_sync_proc;

   -- 다음 클럭에서 비교할 이전 A/B 위상만 저장한다.
   phase_tracking_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            state <= (OTHERS => '0');
         ELSIF (moved = '1') THEN
            state <= state_now;
         END IF;
      END IF;

   END PROCESS phase_tracking_proc;

   -- 구동 중 펄스가 없는 시간을 센다. 새 이동이 있으면 0으로 돌린다.
   timeout_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR moved = '1') THEN
            timeout_count <= (OTHERS => '0');
         ELSIF (enabled = '1' AND unsigned(duty) /= 0) THEN
            IF (timeout_count < TIMEOUT_CLOCKS - 1) THEN
               timeout_count <= timeout_count + 1;
            END IF;
         ELSE
            timeout_count <= (OTHERS => '0');
         END IF;
      END IF;

   END PROCESS timeout_count_proc;

   -- 유효한 정방향/역방향 전이에서만 방향을 갱신한다.
   direction_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            direction <= '0';
         ELSIF (moved = '1') THEN
            IF (valid_forward = '1') THEN
               direction <= '0';
            ELSIF (valid_backward = '1') THEN
               direction <= '1';
            END IF;
         END IF;
      END IF;

   END PROCESS direction_proc;

   --------------------------------------------------------
   -- 위치 preset이 같은 클럭의 이동보다 우선한다.
   --------------------------------------------------------
   -- position의 유일한 기록 프로세스 : 초기화, SW 쓰기, ±1 이동.
   position_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            position <= (OTHERS => '0');
         ELSIF (position_wr_en = '1') THEN
            position <= position_wr_value;
         ELSIF (moved = '1' AND valid_forward = '1') THEN
            position <= std_logic_vector(position_fwd);
         ELSIF (moved = '1' AND valid_backward = '1') THEN
            position <= std_logic_vector(position_bwd);
         END IF;
      END IF;

   END PROCESS position_proc;

   --------------------------------------------------------
   -- 신뢰성 관측 : illegal jump, 구동 중 timeout, 위치 overflow
   -- clear와 새 오류가 겹치면 새 오류가 우선한다.
   --------------------------------------------------------
   -- 불법 위상, 무펄스 timeout, 위치 overflow의 상태와 횟수를 기록한다.
   fault_status_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            illegal_transition_fault <= '0';
            illegal_transition_count <= (OTHERS => '0');
            timeout_fault            <= '0';
            overflow_fault           <= '0';
         ELSE
            IF (clear = '1') THEN
               illegal_transition_fault <= '0';
               timeout_fault            <= '0';
               overflow_fault           <= '0';
            END IF;
            IF (moved = '1') THEN
               IF (valid_forward = '1') THEN
                  IF (overflow_fwd = '1') THEN
                     overflow_fault <= '1';
                  END IF;
               ELSIF (valid_backward = '1') THEN
                  IF (overflow_bwd = '1') THEN
                     overflow_fault <= '1';
                  END IF;
               ELSE
                  illegal_transition_fault <= '1';
                  IF (unsigned(illegal_transition_count) /= 65535) THEN
                     illegal_transition_count <= std_logic_vector(unsigned(illegal_transition_count) + 1);
                  END IF;
               END IF;
            ELSIF (enabled = '1' AND unsigned(duty) /= 0 AND timeout_count >= TIMEOUT_CLOCKS - 1) THEN
               timeout_fault <= '1';
            END IF;
         END IF;
      END IF;

   END PROCESS fault_status_proc;

END ARCHITECTURE rtl;
