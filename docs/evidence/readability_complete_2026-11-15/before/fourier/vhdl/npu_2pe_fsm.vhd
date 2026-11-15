------------------------------------------------------------
-- 2-PE INT8 NPU : 4입력 → 4은닉 ReLU → 2출력
-- 연산 순서 : IDLE → INIT → MAC(4회) → PACK
-- 3개 출력 쌍을 처리하며 기존 NPU의 18클럭 계약을 유지한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY npu_2pe IS
   PORT (
      clk      : IN    std_logic;
      rst      : IN    std_logic;
      start    : IN    std_logic;
      features : IN    std_logic_vector(31 DOWNTO 0);
      busy     : OUT   std_logic;
      done     : OUT   std_logic;
      hidden   : OUT   std_logic_vector(31 DOWNTO 0);
      logits   : OUT   std_logic_vector(15 DOWNTO 0);
      class_id : OUT   std_logic;
      cycles   : OUT   std_logic_vector(31 DOWNTO 0)
   );
END ENTITY npu_2pe;

ARCHITECTURE rtl OF npu_2pe IS

   CONSTANT IDLE                 : integer := 0;
   CONSTANT INIT                 : integer := 1;
   CONSTANT MAC                  : integer := 2;
   CONSTANT PACK                 : integer := 3;
   SIGNAL   state,    next_state : integer RANGE 0 TO 3;

   -- group 0/1 : 은닉층 두 쌍, group 2 : 출력층 한 쌍
   SIGNAL   group_id, index_reg : unsigned(1 DOWNTO 0);
   SIGNAL   input_features      : std_logic_vector(31 DOWNTO 0);
   CONSTANT WEIGHT_PE0          : signed8_array(0 TO 11)  := load8("w0.mem", 12);
   CONSTANT WEIGHT_PE1          : signed8_array(0 TO 11)  := load8("w1.mem", 12);
   CONSTANT BIASES              : signed32_array(0 TO 5)  := load32("bias.mem", 6);
   CONSTANT LAYER_SHIFTS        : unsigned8_array(0 TO 1) := load_shifts("shift.mem");

   SIGNAL input_value            : std_logic_vector(7 DOWNTO 0);
   SIGNAL weight0                : std_logic_vector(7 DOWNTO 0);
   SIGNAL weight1                : std_logic_vector(7 DOWNTO 0);
   SIGNAL accumulator0           : std_logic_vector(31 DOWNTO 0);
   SIGNAL accumulator1           : std_logic_vector(31 DOWNTO 0);
   SIGNAL bias0                  : std_logic_vector(31 DOWNTO 0);
   SIGNAL bias1                  : std_logic_vector(31 DOWNTO 0);
   SIGNAL quantized0, quantized1 : signed(7 DOWNTO 0);
   SIGNAL clear_mac,  enable_mac : std_logic;

   FUNCTION quantize (
      value : std_logic_vector(31 DOWNTO 0);
      amount : unsigned(7 DOWNTO 0);
      apply_relu : boolean
   ) RETURN word8 IS

      VARIABLE scaled_value : signed(31 DOWNTO 0);

   BEGIN

      scaled_value := shift_right(signed(value), to_integer(amount));

      IF (scaled_value > 127) THEN
         RETURN to_signed(127, 8);
      ELSIF (apply_relu AND scaled_value < 0) THEN
         RETURN to_signed(0, 8);
      ELSIF (scaled_value < -128) THEN
         RETURN to_signed(-128, 8);
      ELSE
         RETURN scaled_value(7 DOWNTO 0);
      END IF;

   END FUNCTION quantize;

BEGIN

   clear_mac  <= bit_if(state = INIT);
   enable_mac <= bit_if(state = MAC);

   U_PE0 : ENTITY work.mac_pe(rtl)
      PORT MAP (
         clk    => clk,
         rst    => rst,
         clear  => clear_mac,
         enable => enable_mac,
         x      => input_value,
         weight => weight0,
         bias   => bias0,
         acc    => accumulator0
      );

   U_PE1 : ENTITY work.mac_pe(rtl)
      PORT MAP (
         clk    => clk,
         rst    => rst,
         clear  => clear_mac,
         enable => enable_mac,
         x      => input_value,
         weight => weight1,
         bias   => bias1,
         acc    => accumulator1
      );

   --------------------------------------------------------
   -- 조합 경로 : 입력/가중치/bias 선택과 출력 양자화
   --------------------------------------------------------
   operand_select_proc : PROCESS (ALL) IS

      VARIABLE selected_group, selected_input : natural;

   BEGIN

      selected_group := to_integer(group_id);
      selected_input := to_integer(index_reg);

      IF (selected_group = 2) THEN
         input_value <= hidden(selected_input * 8 + 7 DOWNTO selected_input * 8);
      ELSE
         input_value <= input_features(selected_input * 8 + 7 DOWNTO selected_input * 8);
      END IF;

      weight0 <= (OTHERS => 'X');
      weight1 <= (OTHERS => 'X');
      bias0   <= (OTHERS => 'X');
      bias1   <= (OTHERS => 'X');

      IF (selected_group < 3) THEN
         weight0 <= std_logic_vector(weight_pe0(selected_group * 4 + selected_input));
         weight1 <= std_logic_vector(weight_pe1(selected_group * 4 + selected_input));
         bias0   <= std_logic_vector(biases(selected_group * 2));
         bias1   <= std_logic_vector(biases(selected_group * 2 + 1));
      END IF;

      IF (selected_group = 2) THEN
         quantized0 <= quantize(accumulator0, layer_shifts(1), false);
         quantized1 <= quantize(accumulator1, layer_shifts(1), false);
      ELSE
         quantized0 <= quantize(accumulator0, layer_shifts(0), true);
         quantized1 <= quantize(accumulator1, layer_shifts(0), true);
      END IF;

   END PROCESS operand_select_proc;

   -- FSM의 현재 상태만 저장한다.
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

   -- 네 입력의 MAC과 세 출력 쌍의 반복 순서만 결정한다.
   nextstate_proc : PROCESS (ALL) IS
   BEGIN

      next_state <= state;

      CASE state IS

         WHEN IDLE =>

            IF (start = '1') THEN
               next_state <= INIT;
            END IF;

         WHEN INIT =>

            next_state <= MAC;

         WHEN MAC =>

            IF (index_reg = 3) THEN
               next_state <= PACK;
            END IF;

         WHEN PACK =>

            IF (group_id = 2) THEN
               next_state <= IDLE;
            ELSE
               next_state <= INIT;
            END IF;

         WHEN OTHERS =>

            next_state <= IDLE;

      END CASE;

   END PROCESS nextstate_proc;

   -- start를 수락할 때만 입력 특징을 저장한다.
   input_latch_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            input_features <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            input_features <= features;
         END IF;
      END IF;

   END PROCESS input_latch_proc;

   --------------------------------------------------------
   -- MAC 반복 순번과 두 뉴런 단위의 출력 그룹
   --------------------------------------------------------
   mac_index_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            group_id  <= (OTHERS => '0');
            index_reg <= (OTHERS => '0');
         ELSE

            CASE state IS

               WHEN IDLE =>

                  IF (start = '1') THEN
                     group_id <= (OTHERS => '0');
                  END IF;

               WHEN INIT =>

                  index_reg <= (OTHERS => '0');

               WHEN MAC =>

                  IF (index_reg /= 3) THEN
                     index_reg <= index_reg + 1;
                  END IF;

               WHEN PACK =>

                  IF (group_id /= 2) THEN
                     group_id <= group_id + 1;
                  END IF;

               WHEN OTHERS =>

                  NULL;

            END CASE;

         END IF;
      END IF;

   END PROCESS mac_index_proc;

   -- 은닉층 두 뉴런씩 ReLU/양자화한 값을 저장한다.
   hidden_result_proc : PROCESS (clk) IS

      VARIABLE output_offset : natural;

   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            hidden <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            hidden <= (OTHERS => '0');
         ELSIF (state = PACK AND group_id /= 2) THEN
            output_offset                                   := to_integer(group_id) * 16;
            hidden(output_offset + 15 DOWNTO output_offset) <= std_logic_vector(quantized1) & std_logic_vector(quantized0);
         END IF;
      END IF;

   END PROCESS hidden_result_proc;

   -- 출력층 두 logit과 대소 비교 결과인 class를 저장한다.
   logit_result_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            logits   <= (OTHERS => '0');
            class_id <= '0';
         ELSIF (state = PACK AND group_id = 2) THEN
            logits   <= std_logic_vector(quantized1) & std_logic_vector(quantized0);
            class_id <= bit_if(quantized1 > quantized0);
         END IF;
      END IF;

   END PROCESS logit_result_proc;

   -- 마지막 PACK에서 done을 한 클럭 발생시키고 busy를 내린다.
   handshake_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy <= '0';
         ELSIF (state = IDLE AND start = '1') THEN
            busy <= '1';
         ELSIF (state = PACK AND group_id = 2) THEN
            busy <= '0';
            done <= '1';
         END IF;
      END IF;

   END PROCESS handshake_proc;

   -- 처리 중 클럭 수를 세어 기존 cycles=18 계약을 보존한다.
   cycle_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            cycles <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            cycles <= (OTHERS => '0');
         ELSIF (busy = '1') THEN
            cycles <= std_logic_vector(unsigned(cycles) + 1);
         END IF;
      END IF;

   END PROCESS cycle_count_proc;

END ARCHITECTURE rtl;
