------------------------------------------------------------
-- PWM 생성 : 주기 시작에서 duty를 적재하고 해당 주기 동안 유지
-- 기본 모터 설정 : 100 MHz / 5000 = 20 kHz, duty 범위 0..4096
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY pwm_period IS
   GENERIC (
      PERIOD : integer := 5000
   );
   PORT (
      clk         : IN    std_logic;
      rst         : IN    std_logic;
      enable      : IN    std_logic;
      duty        : IN    std_logic_vector(12 DOWNTO 0);
      pwm         : OUT   std_logic;
      active_duty : OUT   std_logic_vector(12 DOWNTO 0)
   );
END ENTITY pwm_period;

ARCHITECTURE rtl OF pwm_period IS

   SIGNAL count, threshold : unsigned(31 DOWNTO 0);
   SIGNAL limited          : unsigned(12 DOWNTO 0);
   SIGNAL scaled           : unsigned(63 DOWNTO 0);

BEGIN

   limited <= to_unsigned(4096, 13) WHEN unsigned(duty) > 4096 ELSE
              unsigned(duty);
   scaled  <= shift_right(resize(limited * to_unsigned(PERIOD, 32), 64), 12);
   pwm     <= '1' WHEN enable = '1' AND rst = '0' AND count < threshold ELSE
              '0';

   -- PWM 주기를 세며 주기 끝에서 0으로 돌아간다.
   period_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR enable = '0') THEN
            count <= (OTHERS => '0');
         ELSIF (count = PERIOD - 1) THEN
            count <= (OTHERS => '0');
         ELSE
            count <= count + 1;
         END IF;
      END IF;

   END PROCESS period_count_proc;

   -- Duty는 주기 경계에서만 반영한다. enable=0 출력 차단은 조합 경로다.
   -- 주기 도중 명령이 바뀌어도 현재 펄스 폭은 바뀌지 않게 한다.
   duty_latch_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR enable = '0') THEN
            threshold   <= (OTHERS => '0');
            active_duty <= (OTHERS => '0');
         ELSIF (count = PERIOD - 1) THEN
            threshold   <= scaled(31 DOWNTO 0);
            active_duty <= std_logic_vector(limited);
         END IF;
      END IF;

   END PROCESS duty_latch_proc;

END ARCHITECTURE rtl;
