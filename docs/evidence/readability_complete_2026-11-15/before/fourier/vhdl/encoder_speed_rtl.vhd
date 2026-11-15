------------------------------------------------------------
-- 인코더 속도 추정 : 저속은 펄스 간 주기, 고속은 창 내 펄스 수 사용
-- 구조 : 입력 동기화 → 두 방식의 추정 → tick 스냅샷 → 속도 출력
-- 근거 : DESIGN.md의 하이브리드 속도 추정 계약
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY encoder_speed_hybrid IS
   GENERIC (
      CLK_HZ               : integer := 100000000;
      SAMPLE_HZ            : integer := 100;
      COUNTS_FULL_SCALE    : integer := 18;
      HIGH_COUNT_THRESHOLD : integer := 14;
      LOW_COUNT_THRESHOLD  : integer := 10;
      TIMEOUT_MS           : integer := 100
   );
   PORT (
      clk         : IN    std_logic;
      rst         : IN    std_logic;
      sample_tick : IN    std_logic;
      encoder_a   : IN    std_logic;
      speed       : OUT   std_logic_vector(12 DOWNTO 0);
      pulse       : OUT   std_logic;
      speed_valid : OUT   std_logic
   );
END ENTITY encoder_speed_hybrid;

ARCHITECTURE rtl OF encoder_speed_hybrid IS

   CONSTANT RECIP_Q12                       : integer               :=
      (16777216 + COUNTS_FULL_SCALE / 2) / COUNTS_FULL_SCALE;
   CONSTANT SPEED_PRODUCT                   : unsigned(63 DOWNTO 0) :=
                                                                       to_unsigned(4096, 32) * to_unsigned(CLK_HZ, 32);
   CONSTANT SPEED_NUM_64                    : unsigned(63 DOWNTO 0) :=
                                                                       SPEED_PRODUCT / to_unsigned(COUNTS_FULL_SCALE * SAMPLE_HZ, 64);
   CONSTANT TIMEOUT_CLOCKS                  : integer               := (CLK_HZ / 1000) * TIMEOUT_MS;
   SIGNAL   sync_reg                        : std_logic_vector(1 DOWNTO 0);
   SIGNAL   previous                        : std_logic;
   SIGNAL   have_edge                       : std_logic;
   SIGNAL   period_valid                    : std_logic;
   SIGNAL   high_speed_mode                 : std_logic;
   SIGNAL   window_count                    : unsigned(31 DOWNTO 0);
   SIGNAL   period_count                    : unsigned(31 DOWNTO 0);
   SIGNAL   period_divisor                  : unsigned(31 DOWNTO 0);
   SIGNAL   period_speed                    : unsigned(12 DOWNTO 0);
   SIGNAL   divider_start                   : std_logic;
   SIGNAL   divider_busy                    : std_logic;
   SIGNAL   divider_done                    : std_logic;
   SIGNAL   divider_quotient                : std_logic_vector(31 DOWNTO 0);
   SIGNAL   window_product_reg              : unsigned(33 DOWNTO 0);
   SIGNAL   window_total, window_total_snap : unsigned(32 DOWNTO 0);
   SIGNAL   period_valid_snap               : std_logic;
   SIGNAL   period_timeout_snap             : std_logic;
   SIGNAL   high_speed_mode_snap            : std_logic;
   SIGNAL   period_speed_snap               : unsigned(12 DOWNTO 0);
   SIGNAL   speed_calc_pending              : std_logic;
   SIGNAL   bounded_count                   : unsigned(12 DOWNTO 0);
   SIGNAL   window_speed_pipelined          : unsigned(12 DOWNTO 0);
   SIGNAL   reciprocal_speed                : unsigned(12 DOWNTO 0);
   SIGNAL   window_product                  : unsigned(33 DOWNTO 0);
   ATTRIBUTE async_reg : string;
   ATTRIBUTE async_reg OF sync_reg : signal IS "TRUE";

BEGIN

   pulse                  <= sync_reg(1) AND not previous;
   window_total           <= ('0' & window_count) + to_unsigned(1, 33) WHEN pulse = '1' ELSE
                             '0' & window_count;
   bounded_count          <= to_unsigned(COUNTS_FULL_SCALE, 13) WHEN window_total >= COUNTS_FULL_SCALE ELSE
                             window_total(12 DOWNTO 0);
   window_product         <= resize(bounded_count * to_unsigned(RECIP_Q12, 32), 34);
   window_speed_pipelined <= to_unsigned(4096, 13) WHEN window_total_snap >= COUNTS_FULL_SCALE ELSE
                             window_product_reg(24 DOWNTO 12);
   reciprocal_speed       <= to_unsigned(4096, 13) WHEN unsigned(divider_quotient) >= 4096 ELSE
                             unsigned(divider_quotient(12 DOWNTO 0));

   U_DIVIDER : ENTITY work.unsigned_divider(rtl)
      PORT MAP (
         clk      => clk,
         rst      => rst,
         start    => divider_start,
         dividend => std_logic_vector(SPEED_NUM_64(31 DOWNTO 0)),
         divisor  => std_logic_vector(period_divisor),
         busy     => divider_busy,
         done     => divider_done,
         quotient => divider_quotient
      );

   --------------------------------------------------------
   -- 입력 동기화와 상승 에지 검출용 이전 값
   --------------------------------------------------------
   encoder_sync_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            sync_reg <= (OTHERS => '0');
            previous <= '0';
         ELSE
            sync_reg <= sync_reg(0) & encoder_a;
            previous <= sync_reg(1);
         END IF;
      END IF;

   END PROCESS encoder_sync_proc;

   -- 직전 상승 에지 이후의 클럭 수. 새 펄스가 증가보다 우선한다.
   period_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            period_count <= (OTHERS => '0');
            have_edge    <= '0';
         ELSE
            IF (have_edge = '1' AND period_count /= x"FFFFFFFF") THEN
               period_count <= period_count + 1;
            END IF;
            IF (pulse = '1') THEN
               period_count <= (OTHERS => '0');
               have_edge    <= '1';
            END IF;
         END IF;
      END IF;

   END PROCESS period_count_proc;

   -- 샘플 창의 펄스 수. tick과 같은 클럭의 펄스는 window_total에 포함된다.
   window_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            window_count <= (OTHERS => '0');
         ELSE
            IF (pulse = '1' AND window_count /= x"FFFFFFFF") THEN
               window_count <= window_count + 1;
            END IF;
            IF (sample_tick = '1') THEN
               window_count <= (OTHERS => '0');
            END IF;
         END IF;
      END IF;

   END PROCESS window_count_proc;

   -- 첫 펄스 이후부터 주기 역수 나눗셈을 요청한다.
   divider_request_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         divider_start <= '0';
         IF (rst = '1') THEN
            period_divisor <= to_unsigned(1, 32);
         ELSIF (pulse = '1' AND have_edge = '1' AND divider_busy = '0') THEN
            period_divisor <= period_count + 1;
            divider_start  <= '1';
         END IF;
      END IF;

   END PROCESS divider_request_proc;

   --------------------------------------------------------
   -- 저속 역수 추정값의 1/4 필터와 timeout 처리
   --------------------------------------------------------
   period_speed_proc : PROCESS (clk) IS

      VARIABLE delta : unsigned(31 DOWNTO 0);

   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            period_valid <= '0';
            period_speed <= (OTHERS => '0');
         ELSE
            IF (divider_done = '1') THEN
               IF (period_valid = '0') THEN
                  period_speed <= reciprocal_speed;
               ELSIF (reciprocal_speed >= period_speed) THEN
                  delta        := shift_right(resize(reciprocal_speed, 32) - resize(period_speed, 32) + 2, 2);
                  period_speed <= period_speed + resize(delta, 13);
               ELSE
                  delta        := shift_right(resize(period_speed, 32) - resize(reciprocal_speed, 32) + 2, 2);
                  period_speed <= period_speed - resize(delta, 13);
               END IF;
               period_valid <= '1';
            END IF;
            IF (have_edge = '1' AND period_count >= TIMEOUT_CLOCKS - 1) THEN
               period_valid <= '0';
               period_speed <= (OTHERS => '0');
            END IF;
         END IF;
      END IF;

   END PROCESS period_speed_proc;

   --------------------------------------------------------
   -- 단계 1 : tick 시점의 곱셈값과 선택 조건을 동시에 저장
   --------------------------------------------------------
   speed_snapshot_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            window_product_reg   <= (OTHERS => '0');
            window_total_snap    <= (OTHERS => '0');
            period_valid_snap    <= '0';
            period_timeout_snap  <= '0';
            high_speed_mode_snap <= '0';
            period_speed_snap    <= (OTHERS => '0');
            speed_calc_pending   <= '0';
         ELSE
            IF (sample_tick = '1') THEN
               window_total_snap    <= window_total;
               period_valid_snap    <= period_valid;
               period_timeout_snap  <= bit_if(period_count >= TIMEOUT_CLOCKS - 1);
               high_speed_mode_snap <= high_speed_mode;
               period_speed_snap    <= period_speed;
               window_product_reg   <= window_product;
               speed_calc_pending   <= '1';
            END IF;
            IF (speed_calc_pending = '1') THEN
               speed_calc_pending <= '0';
            END IF;
         END IF;
      END IF;

   END PROCESS speed_snapshot_proc;

   --------------------------------------------------------
   -- 단계 2 : 저장한 조건으로 속도 선택, 같은 클럭에 valid 출력
   --------------------------------------------------------
   speed_output_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         speed_valid <= '0';
         IF (rst = '1') THEN
            speed           <= (OTHERS => '0');
            high_speed_mode <= '0';
         ELSIF (speed_calc_pending = '1') THEN
            IF (period_valid_snap = '0' OR period_timeout_snap = '1') THEN
               speed           <= (OTHERS => '0');
               high_speed_mode <= '0';
            ELSIF (window_total_snap >= HIGH_COUNT_THRESHOLD) THEN
               speed           <= std_logic_vector(window_speed_pipelined);
               high_speed_mode <= '1';
            ELSIF (window_total_snap <= LOW_COUNT_THRESHOLD) THEN
               speed           <= std_logic_vector(period_speed_snap);
               high_speed_mode <= '0';
            ELSIF (high_speed_mode_snap = '1') THEN
               speed <= std_logic_vector(window_speed_pipelined);
            ELSE
               speed <= std_logic_vector(period_speed_snap);
            END IF;
            speed_valid <= '1';
         END IF;
      END IF;

   END PROCESS speed_output_proc;

END ARCHITECTURE rtl;
