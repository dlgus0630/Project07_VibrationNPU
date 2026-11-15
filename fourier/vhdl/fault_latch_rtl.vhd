------------------------------------------------------------
-- 연속 이상 분류 latch : 유효한 분류 결과만 카운트
-- 정상 결과는 연속 횟수를 0으로, clear는 latch를 해제한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY fault_latch IS
   GENERIC (
      CONSEC : integer := 3
   );
   PORT (
      clk          : IN    std_logic;
      rst          : IN    std_logic;
      class_valid  : IN    std_logic;
      class_id     : IN    std_logic;
      clear        : IN    std_logic;
      latched      : OUT   std_logic;
      consec_count : OUT   std_logic_vector(7 DOWNTO 0)
   );
END ENTITY fault_latch;

ARCHITECTURE rtl OF fault_latch IS

BEGIN

   fault_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR clear = '1') THEN
            latched      <= '0';
            consec_count <= (OTHERS => '0');
         ELSIF (class_valid = '1') THEN
            IF (class_id = '1') THEN
               IF (unsigned(consec_count) < CONSEC) THEN
                  consec_count <= std_logic_vector(unsigned(consec_count) + 1);
               END IF;
               IF (unsigned(consec_count) >= CONSEC - 1) THEN
                  latched <= '1';
               END IF;
            ELSE
               consec_count <= (OTHERS => '0');
            END IF;
         END IF;
      END IF;

   END PROCESS fault_count_proc;

END ARCHITECTURE rtl;
