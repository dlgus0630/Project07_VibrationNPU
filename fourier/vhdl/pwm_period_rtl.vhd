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
   SIGNAL limited : unsigned(12 DOWNTO 0);
   SIGNAL scaled : unsigned(63 DOWNTO 0);

BEGIN

   -- duty(0..4096)를 한 주기의 high 클럭 수로 환산한다.
   duty_scale_comb_proc : PROCESS (ALL) IS
      VARIABLE requested : unsigned(12 DOWNTO 0);
      VARIABLE duty_product : unsigned(44 DOWNTO 0);
      VARIABLE extended_product : unsigned(63 DOWNTO 0);
   BEGIN
      requested := unsigned(duty);
      IF requested > 4096 THEN
         requested := to_unsigned(4096, 13);
      END IF;
      duty_product := requested * to_unsigned(PERIOD, 32);
      extended_product := resize(duty_product, 64);
      limited <= requested;
      scaled <= shift_right(extended_product, 12);
   END PROCESS duty_scale_comb_proc;

   -- disable/reset은 다음 주기를 기다리지 않고 출력을 차단한다.
   pwm_output_comb_proc : PROCESS (ALL) IS
   BEGIN
      pwm <= '0';
      IF enable = '1' AND rst = '0' THEN
         IF count < threshold THEN
            pwm <= '1';
         END IF;
      END IF;
   END PROCESS pwm_output_comb_proc;

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
