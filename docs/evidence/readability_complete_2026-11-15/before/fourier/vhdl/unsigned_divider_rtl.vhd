------------------------------------------------------------
-- unsigned 정수 나눗셈 : 한 클럭에 한 비트씩 quotient 계산
-- start 때 피연산자를 저장하며 busy/done으로 완료를 알린다.
-- 근거 : encoder_speed_hybrid의 주기 역수 추정 경로
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY unsigned_divider IS
   GENERIC (
      WIDTH : integer := 32
   );
   PORT (
      clk      : IN    std_logic;
      rst      : IN    std_logic;
      start    : IN    std_logic;
      dividend : IN    std_logic_vector(WIDTH - 1 DOWNTO 0);
      divisor  : IN    std_logic_vector(WIDTH - 1 DOWNTO 0);
      busy     : OUT   std_logic;
      done     : OUT   std_logic;
      quotient : OUT   std_logic_vector(WIDTH - 1 DOWNTO 0)
   );
END ENTITY unsigned_divider;

ARCHITECTURE rtl OF unsigned_divider IS

   SIGNAL dividend_shift    : unsigned(WIDTH - 1 DOWNTO 0);
   SIGNAL divisor_hold      : unsigned(WIDTH - 1 DOWNTO 0);
   SIGNAL quotient_work     : unsigned(WIDTH - 1 DOWNTO 0);
   SIGNAL remainder_reg     : unsigned(WIDTH DOWNTO 0);
   SIGNAL shifted_remainder : unsigned(WIDTH DOWNTO 0);
   SIGNAL next_remainder    : unsigned(WIDTH DOWNTO 0);
   SIGNAL next_quotient     : unsigned(WIDTH - 1 DOWNTO 0);
   SIGNAL count             : unsigned(5 DOWNTO 0);
   SIGNAL subtract_bit      : std_logic;

BEGIN

   shifted_remainder <= remainder_reg(WIDTH - 1 DOWNTO 0) & dividend_shift(WIDTH - 1);
   subtract_bit      <= bit_if(shifted_remainder >= ('0' & divisor_hold));
   next_remainder    <= shifted_remainder - ('0' & divisor_hold) WHEN subtract_bit = '1' ELSE
                        shifted_remainder;
   next_quotient     <= quotient_work(WIDTH - 2 DOWNTO 0) & subtract_bit;

   divide_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy           <= '0';
            done           <= '0';
            quotient       <= (OTHERS => '0');
            dividend_shift <= (OTHERS => '0');
            divisor_hold   <= (OTHERS => '0');
            quotient_work  <= (OTHERS => '0');
            remainder_reg  <= (OTHERS => '0');
            count          <= (OTHERS => '0');
         ELSIF (start = '1' AND busy = '0') THEN
            IF (unsigned(divisor) = 0) THEN
               quotient <= (OTHERS => '1');
               done     <= '1';
            ELSE
               busy           <= '1';
               dividend_shift <= unsigned(dividend);
               divisor_hold   <= unsigned(divisor);
               quotient_work  <= (OTHERS => '0');
               remainder_reg  <= (OTHERS => '0');
               count          <= (OTHERS => '0');
            END IF;
         ELSIF (busy = '1') THEN
            dividend_shift <= dividend_shift(WIDTH - 2 DOWNTO 0) & '0';
            remainder_reg  <= next_remainder;
            quotient_work  <= next_quotient;
            IF (count = WIDTH - 1) THEN
               quotient <= std_logic_vector(next_quotient);
               busy     <= '0';
               done     <= '1';
            ELSE
               count <= count + 1;
            END IF;
         END IF;
      END IF;

   END PROCESS divide_proc;

END ARCHITECTURE rtl;
