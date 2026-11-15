------------------------------------------------------------
-- 고정소수점 PI 제어기 : 이름은 기존 pid_fixed 인터페이스 유지
-- 순서 : 입력 저장 → 측정값 필터 → P/I 계산 → 적분 선택 → duty 제한
-- 수치 : 게인 Q16, 적분 -4096..4096, duty 0..4096, D항은 기존처럼 0
   -- *_comb_proc는 조합 계산, 클럭 프로세스는 상태별 레지스터 저장 담당
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY pid_fixed IS
   PORT (
      clk                : IN    std_logic;
      rst                : IN    std_logic;
      start              : IN    std_logic;
      reference          : IN    std_logic_vector(12 DOWNTO 0);
      measured           : IN    std_logic_vector(12 DOWNTO 0);
      kp_gain            : IN    std_logic_vector(17 DOWNTO 0);
      ki_gain            : IN    std_logic_vector(17 DOWNTO 0);
      anti_windup_enable : IN    std_logic;
      busy               : OUT   std_logic;
      done               : OUT   std_logic;
      duty               : OUT   std_logic_vector(12 DOWNTO 0);
      integral           : OUT   std_logic_vector(31 DOWNTO 0);
      derivative         : OUT   std_logic_vector(17 DOWNTO 0)
   );
END ENTITY pid_fixed;

ARCHITECTURE rtl OF pid_fixed IS

   CONSTANT IDLE                       : integer := 0;
   CONSTANT FILTER                     : integer := 1;
   CONSTANT PRODUCTS                   : integer := 2;
   CONSTANT PRODUCTS_HI                : integer := 3;
   CONSTANT PROPOSE_ADD                : integer := 4;
   CONSTANT PROPOSE_SUB                : integer := 5;
   CONSTANT SELECT_STATE               : integer := 6;
   CONSTANT OUTPUT_ADD                 : integer := 7;
   CONSTANT OUTPUT_SUB                 : integer := 8;
   CONSTANT CLAMP                      : integer := 9;
   CONSTANT FINISH                     : integer := 10;
   CONSTANT GAIN_FRACTION_BITS : natural := 16;

   -- 상태와 이번 제어 주기에 사용할 입력
   SIGNAL state          : integer RANGE 0 TO 15;
   SIGNAL next_state     : integer RANGE 0 TO 15;
   SIGNAL error_reg      : signed(17 DOWNTO 0);
   SIGNAL y_hold         : unsigned(12 DOWNTO 0);
   SIGNAL y_previous     : unsigned(12 DOWNTO 0);

   -- 조합 계산 결과 : 아래 *_comb_proc에서 계산, 클럭 지연 없음
   SIGNAL proportional_scaled     : signed(35 DOWNTO 0);
   SIGNAL integral_step           : signed(35 DOWNTO 0);
   SIGNAL integral_low_sum        : unsigned(32 DOWNTO 0);
   SIGNAL integral_candidate_full : signed(63 DOWNTO 0);
   SIGNAL filter_value            : signed(63 DOWNTO 0);
   SIGNAL chosen_integral         : signed(31 DOWNTO 0);

   -- 클럭에 저장되는 계산 단계별 레지스터
   SIGNAL p_term             : signed(31 DOWNTO 0);
   SIGNAL d_term             : signed(31 DOWNTO 0);
   SIGNAL integral_low_reg   : unsigned(32 DOWNTO 0); -- bit 32는 다음 단계 carry
   SIGNAL integral_candidate : signed(31 DOWNTO 0);
   SIGNAL proposed_sum       : signed(31 DOWNTO 0);
   SIGNAL proposed_value     : signed(31 DOWNTO 0);
   SIGNAL selected_i         : signed(31 DOWNTO 0);
   SIGNAL output_sum         : signed(31 DOWNTO 0);
   SIGNAL output_value       : signed(31 DOWNTO 0);

BEGIN

   --------------------------------------------------------
   -- 조합 계산 1 : P항 = Kp × 오차
   -- 게인의 소수부가 16비트이므로 곱셈 후 산술 우측 이동한다.
   -- 음수의 우측 이동도 원본과 동일하게 처리한다.
   --------------------------------------------------------
   proportional_term_comb_proc : PROCESS (ALL) IS
      VARIABLE gain_value : signed(17 DOWNTO 0);
      VARIABLE product    : signed(35 DOWNTO 0);
   BEGIN
      gain_value := signed(kp_gain);
      product    := gain_value * error_reg;

      proportional_scaled <= shift_right(product, GAIN_FRACTION_BITS);
   END PROCESS proportional_term_comb_proc;

   --------------------------------------------------------
   -- 조합 계산 2 : 이번 주기의 적분 증가량 = (Ki × Ts) × 오차
   -- ki_gain에는 샘플 주기 Ts가 이미 반영되어 있다.
   --------------------------------------------------------
   integral_step_comb_proc : PROCESS (ALL) IS
      VARIABLE gain_value : signed(17 DOWNTO 0);
      VARIABLE product    : signed(35 DOWNTO 0);
   BEGIN
      gain_value := signed(ki_gain);
      product    := gain_value * error_reg;

      integral_step <= shift_right(product, GAIN_FRACTION_BITS);
   END PROCESS integral_step_comb_proc;

   --------------------------------------------------------
   -- 조합 계산 3 : 이전 적분값 + 이번 적분 증가량
   -- PRODUCTS    : 하위 합 32비트와 carry를 integral_low_reg에 저장
   -- PRODUCTS_HI : 그 carry를 상위 합에 더하고 64비트 후보를 결합
   -- 기존의 두 클럭 계산을 유지하기 위해 하위 합 레지스터를 사용한다.
   --------------------------------------------------------
   integral_sum_comb_proc : PROCESS (ALL) IS
      VARIABLE previous_integral : signed(63 DOWNTO 0);
      VARIABLE increment         : signed(63 DOWNTO 0);
      VARIABLE previous_low      : unsigned(32 DOWNTO 0);
      VARIABLE increment_low     : unsigned(32 DOWNTO 0);
      VARIABLE previous_high     : unsigned(31 DOWNTO 0);
      VARIABLE increment_high    : unsigned(31 DOWNTO 0);
      VARIABLE carry_from_low    : unsigned(31 DOWNTO 0);
      VARIABLE high_word_sum     : unsigned(31 DOWNTO 0);
   BEGIN
      -- signed 확장 : 음수의 부호를 유지하며 64비트로 넓힌다.
      previous_integral := resize(signed(integral), 64);
      increment         := resize(integral_step, 64);

      -- 하위 워드는 unsigned로 더해야 bit 32의 carry를 얻을 수 있다.
      previous_low     := '0' & unsigned(previous_integral(31 DOWNTO 0));
      increment_low    := '0' & unsigned(increment(31 DOWNTO 0));
      integral_low_sum <= previous_low + increment_low;

      -- 이전 클럭에 저장한 하위 합의 carry를 상위 워드에 더한다.
      previous_high     := unsigned(previous_integral(63 DOWNTO 32));
      increment_high    := unsigned(increment(63 DOWNTO 32));
      carry_from_low    := (OTHERS => '0');
      carry_from_low(0) := integral_low_reg(32);

      high_word_sum := previous_high + increment_high;
      high_word_sum := high_word_sum + carry_from_low;

      integral_candidate_full <= signed(high_word_sum & integral_low_reg(31 DOWNTO 0));
   END PROCESS integral_sum_comb_proc;

   --------------------------------------------------------
   -- 조합 계산 4 : 측정값 변화의 저역 통과 필터
   -- 새 필터값 = (3 × 이전 필터값 + 현재 측정값 - 이전 측정값) / 4
   -- derivative는 진단 출력이며 아래 제어 계산의 d_term은 0을 유지한다.
   --------------------------------------------------------
   measurement_filter_comb_proc : PROCESS (ALL) IS
      VARIABLE previous_filter      : signed(17 DOWNTO 0);
      VARIABLE weighted_history     : signed(20 DOWNTO 0);
      VARIABLE current_measurement  : signed(13 DOWNTO 0);
      VARIABLE previous_measurement : signed(13 DOWNTO 0);
      VARIABLE measurement_change   : signed(63 DOWNTO 0);
      VARIABLE filter_sum           : signed(63 DOWNTO 0);
   BEGIN
      previous_filter  := signed(derivative);
      weighted_history := previous_filter * to_signed(3, 3);

      -- 측정값은 unsigned이므로 앞에 0을 붙인 뒤 signed로 해석한다.
      current_measurement  := signed('0' & y_hold);
      previous_measurement := signed('0' & y_previous);
      measurement_change   := resize(current_measurement, 64) - resize(previous_measurement, 64);

      filter_sum   := resize(weighted_history, 64) + measurement_change;
      filter_value <= shift_right(filter_sum, 2);
   END PROCESS measurement_filter_comb_proc;

   --------------------------------------------------------
   -- 조합 계산 5 : anti-windup 적분 선택
   -- 출력 제한을 더 벗어나게 만드는 적분 갱신은 거절한다.
   -- 기본은 새 적분 후보, 거절하는 경우에만 이전 적분값을 선택한다.
   --------------------------------------------------------
   anti_windup_select_comb_proc : PROCESS (ALL) IS
   BEGIN
      chosen_integral <= integral_candidate;

      IF anti_windup_enable = '1' THEN
         IF proposed_value > 4096 THEN
            -- 최대 출력 초과 + 양의 오차 : 더 증가시키지 않는다.
            IF error_reg > 0 THEN
               chosen_integral <= signed(integral);
            END IF;
         ELSIF proposed_value < 0 THEN
            -- 최소 출력 미만 + 음의 오차 : 더 감소시키지 않는다.
            IF error_reg < 0 THEN
               chosen_integral <= signed(integral);
            END IF;
         END IF;
      END IF;
   END PROCESS anti_windup_select_comb_proc;

   --------------------------------------------------------
   -- 상태 레지스터 / 다음 상태
   --------------------------------------------------------
   clocked_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            state <= IDLE;
         ELSE
            state <= next_state;
         END IF;
      END IF;

   END PROCESS clocked_proc;

   nextstate_proc : PROCESS (ALL) IS
   BEGIN

      next_state <= state;

      CASE state IS

         WHEN IDLE =>

            IF (start = '1') THEN
               next_state <= FILTER;
            END IF;

         WHEN FILTER =>

            next_state <= PRODUCTS;

         WHEN PRODUCTS =>

            next_state <= PRODUCTS_HI;

         WHEN PRODUCTS_HI =>

            next_state <= PROPOSE_ADD;

         WHEN PROPOSE_ADD =>

            next_state <= PROPOSE_SUB;

         WHEN PROPOSE_SUB =>

            next_state <= SELECT_STATE;

         WHEN SELECT_STATE =>

            next_state <= OUTPUT_ADD;

         WHEN OUTPUT_ADD =>

            next_state <= OUTPUT_SUB;

         WHEN OUTPUT_SUB =>

            next_state <= CLAMP;

         WHEN CLAMP =>

            next_state <= FINISH;

         WHEN FINISH =>

            next_state <= IDLE;

         WHEN OTHERS =>

            next_state <= IDLE;

      END CASE;

   END PROCESS nextstate_proc;

   -- start 수락 시 오차와 측정값을 저장한다.
   sample_input_proc : PROCESS (clk) IS
      VARIABLE reference_value : signed(13 DOWNTO 0);
      VARIABLE measured_value  : signed(13 DOWNTO 0);
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            error_reg <= (OTHERS => '0');
            y_hold    <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            -- reference/measured의 최상위 비트가 부호로 해석되지 않게 0을 붙인다.
            reference_value := signed('0' & reference);
            measured_value  := signed('0' & measured);
            error_reg <= resize(reference_value, 18) - resize(measured_value, 18);
            y_hold    <= unsigned(measured);
         END IF;
      END IF;

   END PROCESS sample_input_proc;

   -- 측정값 변화의 1/4 필터. 진단 출력은 유지하며 D 제어항은 0이다.
   derivative_filter_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            derivative <= (OTHERS => '0');
            y_previous <= (OTHERS => '0');
         ELSIF (state = FILTER) THEN
            derivative <= std_logic_vector(filter_value(17 DOWNTO 0));
            y_previous <= y_hold;
         END IF;
      END IF;

   END PROCESS derivative_filter_proc;

   --------------------------------------------------------
   -- 곱셈 결과와 적분 덧셈의 하위 32비트/carry
   --------------------------------------------------------
   multiply_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            p_term           <= (OTHERS => '0');
            d_term           <= (OTHERS => '0');
            integral_low_reg <= (OTHERS => '0');
         ELSIF (state = PRODUCTS) THEN
            p_term           <= proportional_scaled(31 DOWNTO 0);
            d_term           <= (OTHERS => '0');
            integral_low_reg <= integral_low_sum;
         END IF;
      END IF;

   END PROCESS multiply_proc;

   -- 적분 덧셈의 상위 비트를 결합하고 후보를 ±4096으로 제한한다.
   integral_candidate_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            integral_candidate <= (OTHERS => '0');
         ELSIF (state = PRODUCTS_HI) THEN
            IF (integral_candidate_full > 4096) THEN
               integral_candidate <= to_signed(4096, 32);
            ELSIF (integral_candidate_full < -4096) THEN
               integral_candidate <= to_signed(-4096, 32);
            ELSE
               integral_candidate <= integral_candidate_full(31 DOWNTO 0);
            END IF;
         END IF;
      END IF;

   END PROCESS integral_candidate_proc;

   -- 새 적분 후보를 적용한 출력으로 anti-windup 조건을 계산한다.
   proposed_output_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            proposed_sum   <= (OTHERS => '0');
            proposed_value <= (OTHERS => '0');
         ELSIF (state = PROPOSE_ADD) THEN
            proposed_sum <= p_term + integral_candidate;
         ELSIF (state = PROPOSE_SUB) THEN
            proposed_value <= proposed_sum - d_term;
         END IF;
      END IF;

   END PROCESS proposed_output_proc;

   --------------------------------------------------------
   -- Anti-windup 적용 : 포화를 더 키우는 적분 갱신은 거절
   --------------------------------------------------------
   integral_update_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            integral   <= (OTHERS => '0');
            selected_i <= (OTHERS => '0');
         ELSIF (state = SELECT_STATE) THEN
            integral   <= std_logic_vector(chosen_integral);
            selected_i <= chosen_integral;
         END IF;
      END IF;

   END PROCESS integral_update_proc;

   -- 선택한 적분값으로 최종 P+I-D를 두 단계에 걸쳐 계산한다.
   output_pipeline_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            output_sum   <= (OTHERS => '0');
            output_value <= (OTHERS => '0');
         ELSIF (state = OUTPUT_ADD) THEN
            output_sum <= p_term + selected_i;
         ELSIF (state = OUTPUT_SUB) THEN
            output_value <= output_sum - d_term;
         END IF;
      END IF;

   END PROCESS output_pipeline_proc;

   -- CLAMP에서 duty, FINISH에서 busy/done을 갱신한다.
   duty_output_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy <= '0';
            duty <= (OTHERS => '0');
         ELSE

            CASE state IS

               WHEN IDLE =>

                  IF (start = '1') THEN
                     busy <= '1';
                  END IF;

               WHEN CLAMP =>

                  IF (output_value > 4096) THEN
                     duty <= std_logic_vector(to_unsigned(4096, 13));
                  ELSIF (output_value < 0) THEN
                     duty <= (OTHERS => '0');
                  ELSE
                     duty <= std_logic_vector(output_value(12 DOWNTO 0));
                  END IF;

               WHEN FINISH =>

                  busy <= '0';
                  done <= '1';

               WHEN FILTER | PRODUCTS | PRODUCTS_HI | PROPOSE_ADD | PROPOSE_SUB |
                    SELECT_STATE | OUTPUT_ADD | OUTPUT_SUB =>

                  NULL;

               WHEN OTHERS =>

                  busy <= '0';
                  duty <= (OTHERS => '0');

            END CASE;

         END IF;
      END IF;

   END PROCESS duty_output_proc;

END ARCHITECTURE rtl;
