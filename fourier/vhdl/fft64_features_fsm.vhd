------------------------------------------------------------
-- 64점 FFT와 4개 대역 특징 추출
-- 흐름 : bit-reverse 입력 → 6단 butterfly → 대역 누적 → 양자화
-- 수치 : twiddle Q1.15, 각 단 /2, 최종 FFT(x)/64
-- 근거 : DESIGN.md의 FFT 정수 연산 계약
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY fft64_features IS
   PORT (
      clk         : IN    std_logic;
      rst         : IN    std_logic;
      start       : IN    std_logic;
      sample_en   : OUT   std_logic;
      sample_addr : OUT   std_logic_vector(5 DOWNTO 0);
      sample_data : IN    std_logic_vector(15 DOWNTO 0);
      busy        : OUT   std_logic;
      done        : OUT   std_logic;
      features    : OUT   std_logic_vector(31 DOWNTO 0)
   );
END ENTITY fft64_features;

ARCHITECTURE rtl OF fft64_features IS

   CONSTANT IDLE : integer := 0;
   CONSTANT LREQ : integer := 1;
   CONSTANT LWAIT : integer := 2;
   CONSTANT LSTORE : integer := 3;
   CONSTANT READ_STATE : integer := 4;
   CONSTANT MULT : integer := 5;
   CONSTANT WRITE_STATE : integer := 6;
   CONSTANT FACC : integer := 7;
   CONSTANT FINISH : integer := 8;
   SIGNAL state, next_state : integer RANGE 0 TO 15;

   -- 작업 메모리. fft_memory_proc만 쓴다.
   SIGNAL fft_real,    fft_imag : signed16_array(0 TO 63);
   CONSTANT TWRE : signed16_array(0 TO 31) := load16("tw_re.mem", 32);
   CONSTANT TWIM : signed16_array(0 TO 31) := load16("tw_im.mem", 32);

   -- 입력 순번, butterfly 위치, 출력 bin
   SIGNAL load_index : unsigned(5 DOWNTO 0);
   SIGNAL group_base : unsigned(5 DOWNTO 0);
   SIGNAL pair_index : unsigned(5 DOWNTO 0);
   SIGNAL frequency_bin : unsigned(5 DOWNTO 0);
   SIGNAL fft_stage : unsigned(2 DOWNTO 0);
   SIGNAL group_span : unsigned(6 DOWNTO 0);
   SIGNAL half_span : unsigned(5 DOWNTO 0);
   SIGNAL upper_index : unsigned(5 DOWNTO 0);
   SIGNAL lower_index : unsigned(5 DOWNTO 0);
   SIGNAL twiddle_index : unsigned(5 DOWNTO 0);

   -- 위/아래 입력의 실수·허수, twiddle의 실수·허수를 각각 보관한다.
   SIGNAL upper_real : signed(15 DOWNTO 0);
   SIGNAL upper_imag : signed(15 DOWNTO 0);
   SIGNAL lower_real : signed(15 DOWNTO 0);
   SIGNAL lower_imag : signed(15 DOWNTO 0);
   SIGNAL twiddle_real_value : signed(15 DOWNTO 0);
   SIGNAL twiddle_imag_value : signed(15 DOWNTO 0);
   SIGNAL real_product : signed(32 DOWNTO 0);
   SIGNAL imag_product : signed(32 DOWNTO 0);
   SIGNAL rotated_real : signed(32 DOWNTO 0);
   SIGNAL rotated_imag : signed(32 DOWNTO 0);
   SIGNAL band_sums : unsigned32_array(0 TO 3);
   SIGNAL last_pair : boolean;
   SIGNAL last_group : boolean;
   SIGNAL last_stage : boolean;
   SIGNAL next_upper_real : signed(15 DOWNTO 0);
   SIGNAL next_upper_imag : signed(15 DOWNTO 0);
   SIGNAL next_lower_real : signed(15 DOWNTO 0);
   SIGNAL next_lower_imag : signed(15 DOWNTO 0);

   FUNCTION reverse6 (
      value : unsigned(5 DOWNTO 0)
   ) RETURN natural IS

      VARIABLE reversed_bits : unsigned(5 DOWNTO 0);

   BEGIN

      FOR n IN 0 TO 5 LOOP

         reversed_bits(n) := value(5 - n);

      END LOOP;

      RETURN to_integer(reversed_bits);

   END FUNCTION reverse6;

   FUNCTION sat16_half (
      value : signed(33 DOWNTO 0)
   ) RETURN word16 IS

      VARIABLE scaled_value : signed(33 DOWNTO 0);

   BEGIN

      scaled_value := shift_right(value, 1);

      IF (scaled_value > 32767) THEN
         RETURN to_signed(32767, 16);
      ELSIF (scaled_value < -32768) THEN
         RETURN to_signed(-32768, 16);
      ELSE
         RETURN scaled_value(15 DOWNTO 0);
      END IF;

   END FUNCTION sat16_half;

   FUNCTION feature_q (
      value : unsigned(31 DOWNTO 0)
   ) RETURN std_logic_vector IS
   BEGIN

      IF (shift_right(value, 5) > 127) THEN
         RETURN x"7F";
      ELSE
         RETURN std_logic_vector(value(12 DOWNTO 5));
      END IF;

   END FUNCTION feature_q;

BEGIN

   -- butterfly 주소와 반복 종료 조건. 원본의 stage/base/j 계산 순서를 유지한다.
   address_select_comb_proc : PROCESS (ALL) IS
      VARIABLE span_value : unsigned(6 DOWNTO 0);
      VARIABLE half_value : unsigned(5 DOWNTO 0);
      VARIABLE group_end : unsigned(6 DOWNTO 0);
      VARIABLE twiddle_shift : natural;
   BEGIN
      span_value := shift_left(to_unsigned(1, 7), to_integer(fft_stage));
      half_value := span_value(6 DOWNTO 1);
      group_end := resize(group_base, 7) + span_value;
      twiddle_shift := (6 - to_integer(fft_stage)) MOD 8;

      group_span <= span_value;
      half_span <= half_value;
      upper_index <= group_base + pair_index;
      lower_index <= group_base + pair_index + half_value;
      twiddle_index <= shift_left(pair_index, twiddle_shift);
      last_pair <= pair_index = half_value - 1;
      last_group <= group_end >= 64;
      last_stage <= fft_stage = 6;
   END PROCESS address_select_comb_proc;
   sample_en   <= bit_if(state = LREQ);
   sample_addr <= std_logic_vector(load_index);

   --------------------------------------------------------
   -- 복소 곱 조합 연산 : B*W
   --------------------------------------------------------
   butterfly_math_proc : PROCESS (ALL) IS

      VARIABLE real_times_real : signed(31 DOWNTO 0);
      VARIABLE imag_times_imag : signed(31 DOWNTO 0);
      VARIABLE real_times_imag : signed(31 DOWNTO 0);
      VARIABLE imag_times_real : signed(31 DOWNTO 0);

   BEGIN

      real_times_real := lower_real * twiddle_real_value;
      imag_times_imag := lower_imag * twiddle_imag_value;
      real_times_imag := lower_real * twiddle_imag_value;
      imag_times_real := lower_imag * twiddle_real_value;
      real_product <= resize(real_times_real, 33) - resize(imag_times_imag, 33);
      imag_product <= resize(real_times_imag, 33) + resize(imag_times_real, 33);

   END PROCESS butterfly_math_proc;

   -- A ± 회전한 B를 34비트로 계산한 뒤 /2·INT16 포화를 적용한다.
   butterfly_output_comb_proc : PROCESS (ALL) IS
      VARIABLE upper_real_full : signed(33 DOWNTO 0);
      VARIABLE upper_imag_full : signed(33 DOWNTO 0);
      VARIABLE rotated_real_full : signed(33 DOWNTO 0);
      VARIABLE rotated_imag_full : signed(33 DOWNTO 0);
      VARIABLE sum_real : signed(33 DOWNTO 0);
      VARIABLE sum_imag : signed(33 DOWNTO 0);
      VARIABLE difference_real : signed(33 DOWNTO 0);
      VARIABLE difference_imag : signed(33 DOWNTO 0);
   BEGIN
      upper_real_full := resize(upper_real, 34);
      upper_imag_full := resize(upper_imag, 34);
      rotated_real_full := resize(rotated_real, 34);
      rotated_imag_full := resize(rotated_imag, 34);
      sum_real := upper_real_full + rotated_real_full;
      sum_imag := upper_imag_full + rotated_imag_full;
      difference_real := upper_real_full - rotated_real_full;
      difference_imag := upper_imag_full - rotated_imag_full;

      next_upper_real <= sat16_half(sum_real);
      next_upper_imag <= sat16_half(sum_imag);
      next_lower_real <= sat16_half(difference_real);
      next_lower_imag <= sat16_half(difference_imag);
   END PROCESS butterfly_output_comb_proc;

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

   --------------------------------------------------------
   -- 다음 상태 결정 : 데이터 레지스터는 여기서 쓰지 않는다.
   --------------------------------------------------------
   nextstate_proc : PROCESS (ALL) IS
   BEGIN

      next_state <= state;

      CASE state IS

         WHEN IDLE =>

            IF (start = '1') THEN
               next_state <= LREQ;
            END IF;

         WHEN LREQ =>

            next_state <= LWAIT;

         WHEN LWAIT =>

            next_state <= LSTORE;

         WHEN LSTORE =>

            IF (load_index = 63) THEN
               next_state <= READ_STATE;
            ELSE
               next_state <= LREQ;
            END IF;

         WHEN READ_STATE =>

            next_state <= MULT;

         WHEN MULT =>

            next_state <= WRITE_STATE;

         WHEN WRITE_STATE =>

            IF last_pair AND last_group AND last_stage THEN
               next_state <= FACC;
            ELSE
               next_state <= READ_STATE;
            END IF;

         WHEN FACC =>

            IF (frequency_bin = 31) THEN
               next_state <= FINISH;
            END IF;

         WHEN FINISH =>

            next_state <= IDLE;

         WHEN OTHERS =>

            next_state <= IDLE;

      END CASE;

   END PROCESS nextstate_proc;

   load_index_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            load_index <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            load_index <= (OTHERS => '0');
         ELSIF (state = LSTORE AND load_index /= 63) THEN
            load_index <= load_index + 1;
         END IF;
      END IF;

   END PROCESS load_index_proc;

   --------------------------------------------------------
   -- Butterfly 주소/단수 갱신
   --------------------------------------------------------
   butterfly_index_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            fft_stage <= to_unsigned(1, 3);
            group_base  <= (OTHERS => '0');
            pair_index     <= (OTHERS => '0');
         ELSIF (state = LSTORE AND load_index = 63) THEN
            fft_stage <= to_unsigned(1, 3);
            group_base  <= (OTHERS => '0');
            pair_index     <= (OTHERS => '0');
         ELSIF (state = WRITE_STATE) THEN
            IF last_pair THEN
               pair_index <= (OTHERS => '0');
               IF last_group THEN
                  group_base <= (OTHERS => '0');
                  IF NOT last_stage THEN
                     fft_stage <= fft_stage + 1;
                  END IF;
               ELSE
                  group_base <= group_base + resize(group_span, 6);
               END IF;
            ELSE
               pair_index <= pair_index + 1;
            END IF;
         END IF;
      END IF;

   END PROCESS butterfly_index_proc;

   --------------------------------------------------------
   -- 작업 메모리 : 입력 로딩과 butterfly 저장을 한 writer로 유지
   -- 기존 회로와 같이 reset에서 메모리 전체를 지우지 않는다.
   --------------------------------------------------------
   fft_memory_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '0') THEN
            IF (state = LSTORE) THEN
               fft_real(reverse6(load_index)) <= signed(sample_data);
               fft_imag(reverse6(load_index)) <= (OTHERS => '0');
            ELSIF (state = WRITE_STATE) THEN
               fft_real(to_integer(upper_index)) <= next_upper_real;
               fft_imag(to_integer(upper_index)) <= next_upper_imag;
               fft_real(to_integer(lower_index)) <= next_lower_real;
               fft_imag(to_integer(lower_index)) <= next_lower_imag;
            END IF;
         END IF;
      END IF;

   END PROCESS fft_memory_proc;

   butterfly_reg_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            upper_real  <= (OTHERS => '0');
            upper_imag  <= (OTHERS => '0');
            lower_real  <= (OTHERS => '0');
            lower_imag  <= (OTHERS => '0');
            twiddle_real_value  <= (OTHERS => '0');
            twiddle_imag_value  <= (OTHERS => '0');
            rotated_real  <= (OTHERS => '0');
            rotated_imag <= (OTHERS => '0');
         ELSIF (state = READ_STATE) THEN
            upper_real <= fft_real(to_integer(upper_index));
            upper_imag <= fft_imag(to_integer(upper_index));
            lower_real <= fft_real(to_integer(lower_index));
            lower_imag <= fft_imag(to_integer(lower_index));
            twiddle_real_value <= twre(to_integer(twiddle_index));
            twiddle_imag_value <= twim(to_integer(twiddle_index));
         ELSIF (state = MULT) THEN
            rotated_real  <= shift_right(real_product, 15);
            rotated_imag <= shift_right(imag_product, 15);
         END IF;
      END IF;

   END PROCESS butterfly_reg_proc;

   --------------------------------------------------------
   -- 대역 누적 : bin 1..6 / 7..12 / 13..20 / 21..31
   --------------------------------------------------------
   band_sum_proc : PROCESS (clk) IS

      VARIABLE real_value, imag_value : signed(16 DOWNTO 0);
      VARIABLE magnitude              : unsigned(17 DOWNTO 0);
      VARIABLE band                   : natural RANGE 0 TO 3;

   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            frequency_bin    <= to_unsigned(1, 6);
            band_sums <= (OTHERS => (OTHERS => '0'));
         ELSIF state = WRITE_STATE AND last_pair AND last_group AND last_stage THEN
            frequency_bin    <= to_unsigned(1, 6);
            band_sums <= (OTHERS => (OTHERS => '0'));
         ELSIF (state = FACC) THEN
            real_value := resize(fft_real(to_integer(frequency_bin)), 17);
            imag_value := resize(fft_imag(to_integer(frequency_bin)), 17);
            magnitude  := resize(unsigned(abs(real_value)), 18) + resize(unsigned(abs(imag_value)), 18);
            IF (frequency_bin <= 6) THEN
               band := 0;
            ELSIF (frequency_bin <= 12) THEN
               band := 1;
            ELSIF (frequency_bin <= 20) THEN
               band := 2;
            ELSE
               band := 3;
            END IF;
            band_sums(band) <= band_sums(band) + resize(magnitude, 32);
            IF (frequency_bin /= 31) THEN
               frequency_bin <= frequency_bin + 1;
            END IF;
         END IF;
      END IF;

   END PROCESS band_sum_proc;

   feature_out_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy     <= '0';
            features <= (OTHERS => '0');
         ELSE

            CASE state IS

               WHEN IDLE =>

                  IF (start = '1') THEN
                     busy <= '1';
                  END IF;

               WHEN FINISH =>

                  features(7 DOWNTO 0) <= feature_q(band_sums(0));
                  features(15 DOWNTO 8) <= feature_q(band_sums(1));
                  features(23 DOWNTO 16) <= feature_q(band_sums(2));
                  features(31 DOWNTO 24) <= feature_q(band_sums(3));
                  busy     <= '0';
                  done     <= '1';

               WHEN LREQ | LWAIT | LSTORE | READ_STATE | MULT | WRITE_STATE | FACC =>

                  NULL;

               WHEN OTHERS =>

                  busy <= '0';

            END CASE;

         END IF;
      END IF;

   END PROCESS feature_out_proc;

END ARCHITECTURE rtl;
