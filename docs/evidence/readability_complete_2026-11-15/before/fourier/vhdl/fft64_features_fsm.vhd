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

   CONSTANT IDLE              : integer := 0;
   CONSTANT LREQ              : integer := 1;
   CONSTANT LWAIT             : integer := 2;
   CONSTANT LSTORE            : integer := 3;
   CONSTANT READ_STATE        : integer := 4;
   CONSTANT MULT              : integer := 5;
   CONSTANT WRITE_STATE       : integer := 6;
   CONSTANT FACC              : integer := 7;
   CONSTANT FINISH            : integer := 8;
   SIGNAL   state, next_state : integer RANGE 0 TO 15;

   -- 작업 메모리. fft_memory_proc만 쓴다.
   SIGNAL   re,    im : signed16_array(0 TO 63);
   CONSTANT TWRE      : signed16_array(0 TO 31) := load16("tw_re.mem", 32);
   CONSTANT TWIM      : signed16_array(0 TO 31) := load16("tw_im.mem", 32);

   -- 입력 순번, butterfly 위치, 출력 bin
   SIGNAL load_index : unsigned(5 DOWNTO 0);
   SIGNAL base       : unsigned(5 DOWNTO 0);
   SIGNAL j          : unsigned(5 DOWNTO 0);
   SIGNAL k          : unsigned(5 DOWNTO 0);
   SIGNAL stage      : unsigned(2 DOWNTO 0);
   SIGNAL span       : unsigned(6 DOWNTO 0);
   SIGNAL half       : unsigned(5 DOWNTO 0);
   SIGNAL ia         : unsigned(5 DOWNTO 0);
   SIGNAL ib         : unsigned(5 DOWNTO 0);
   SIGNAL ti         : unsigned(5 DOWNTO 0);

   -- Butterfly 입력 A=ar+j*ai, B=br+j*bi, W=wr+j*wi
   SIGNAL ar           : signed(15 DOWNTO 0);
   SIGNAL ai           : signed(15 DOWNTO 0);
   SIGNAL br           : signed(15 DOWNTO 0);
   SIGNAL bi           : signed(15 DOWNTO 0);
   SIGNAL wr           : signed(15 DOWNTO 0);
   SIGNAL wi           : signed(15 DOWNTO 0);
   SIGNAL real_product : signed(32 DOWNTO 0);
   SIGNAL imag_product : signed(32 DOWNTO 0);
   SIGNAL tr           : signed(32 DOWNTO 0);
   SIGNAL tim          : signed(32 DOWNTO 0);
   SIGNAL sums         : unsigned32_array(0 TO 3);

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

   span        <= shift_left(to_unsigned(1, 7), to_integer(stage));
   half        <= span(6 DOWNTO 1);
   ia          <= base + j;
   ib          <= base + j + half;
   ti          <= shift_left(j, (6 - to_integer(stage)) MOD 8);
   sample_en   <= bit_if(state = LREQ);
   sample_addr <= std_logic_vector(load_index);

   --------------------------------------------------------
   -- 복소 곱 조합 연산 : B*W
   --------------------------------------------------------
   butterfly_math_proc : PROCESS (ALL) IS

      VARIABLE br_wr : signed(31 DOWNTO 0);
      VARIABLE bi_wi : signed(31 DOWNTO 0);
      VARIABLE br_wi : signed(31 DOWNTO 0);
      VARIABLE bi_wr : signed(31 DOWNTO 0);

   BEGIN

      br_wr        := br * wr;
      bi_wi        := bi * wi;
      br_wi        := br * wi;
      bi_wr        := bi * wr;
      real_product <= resize(br_wr, 33) - resize(bi_wi, 33);
      imag_product <= resize(br_wi, 33) + resize(bi_wr, 33);

   END PROCESS butterfly_math_proc;

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

            IF (j = half - 1 AND resize(base, 7) + span >= 64 AND stage = 6) THEN
               next_state <= FACC;
            ELSE
               next_state <= READ_STATE;
            END IF;

         WHEN FACC =>

            IF (k = 31) THEN
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
            stage <= to_unsigned(1, 3);
            base  <= (OTHERS => '0');
            j     <= (OTHERS => '0');
         ELSIF (state = LSTORE AND load_index = 63) THEN
            stage <= to_unsigned(1, 3);
            base  <= (OTHERS => '0');
            j     <= (OTHERS => '0');
         ELSIF (state = WRITE_STATE) THEN
            IF (j = half - 1) THEN
               j <= (OTHERS => '0');
               IF (resize(base, 7) + span >= 64) THEN
                  base <= (OTHERS => '0');
                  IF (stage /= 6) THEN
                     stage <= stage + 1;
                  END IF;
               ELSE
                  base <= base + resize(span, 6);
               END IF;
            ELSE
               j <= j + 1;
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
               re(reverse6(load_index)) <= signed(sample_data);
               im(reverse6(load_index)) <= (OTHERS => '0');
            ELSIF (state = WRITE_STATE) THEN
               re(to_integer(ia)) <= sat16_half(resize(ar, 34) + resize(tr, 34));
               im(to_integer(ia)) <= sat16_half(resize(ai, 34) + resize(tim, 34));
               re(to_integer(ib)) <= sat16_half(resize(ar, 34) - resize(tr, 34));
               im(to_integer(ib)) <= sat16_half(resize(ai, 34) - resize(tim, 34));
            END IF;
         END IF;
      END IF;

   END PROCESS fft_memory_proc;

   butterfly_reg_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            ar  <= (OTHERS => '0');
            ai  <= (OTHERS => '0');
            br  <= (OTHERS => '0');
            bi  <= (OTHERS => '0');
            wr  <= (OTHERS => '0');
            wi  <= (OTHERS => '0');
            tr  <= (OTHERS => '0');
            tim <= (OTHERS => '0');
         ELSIF (state = READ_STATE) THEN
            ar <= re(to_integer(ia));
            ai <= im(to_integer(ia));
            br <= re(to_integer(ib));
            bi <= im(to_integer(ib));
            wr <= twre(to_integer(ti));
            wi <= twim(to_integer(ti));
         ELSIF (state = MULT) THEN
            tr  <= shift_right(real_product, 15);
            tim <= shift_right(imag_product, 15);
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
            k    <= to_unsigned(1, 6);
            sums <= (OTHERS => (OTHERS => '0'));
         ELSIF (state = WRITE_STATE AND j = half - 1 AND resize(base, 7) + span >= 64 AND stage = 6) THEN
            k    <= to_unsigned(1, 6);
            sums <= (OTHERS => (OTHERS => '0'));
         ELSIF (state = FACC) THEN
            real_value := resize(re(to_integer(k)), 17);
            imag_value := resize(im(to_integer(k)), 17);
            magnitude  := resize(unsigned(abs(real_value)), 18) + resize(unsigned(abs(imag_value)), 18);
            IF (k <= 6) THEN
               band := 0;
            ELSIF (k <= 12) THEN
               band := 1;
            ELSIF (k <= 20) THEN
               band := 2;
            ELSE
               band := 3;
            END IF;
            sums(band) <= sums(band) + resize(magnitude, 32);
            IF (k /= 31) THEN
               k <= k + 1;
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

                  features <= feature_q(sums(3)) & feature_q(sums(2)) & feature_q(sums(1)) & feature_q(sums(0));
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
