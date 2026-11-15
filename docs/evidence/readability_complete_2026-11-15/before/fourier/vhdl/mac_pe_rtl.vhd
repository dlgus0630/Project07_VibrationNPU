------------------------------------------------------------
-- MAC PE : signed INT8 입력 × signed INT8 가중치 → INT32 누산
-- 우선순위 : rst > clear(bias 적재) > enable(누산) > 값 유지
-- INT32 범위를 넘으면 원본과 동일하게 하위 32비트만 남긴다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY mac_pe IS
   PORT (
      clk    : IN    std_logic;
      rst    : IN    std_logic;
      clear  : IN    std_logic;
      enable : IN    std_logic;
      x      : IN    std_logic_vector(7 DOWNTO 0);
      weight : IN    std_logic_vector(7 DOWNTO 0);
      bias   : IN    std_logic_vector(31 DOWNTO 0);
      acc    : OUT   std_logic_vector(31 DOWNTO 0)
   );
END ENTITY mac_pe;

ARCHITECTURE rtl OF mac_pe IS

   SIGNAL product : signed(15 DOWNTO 0);

BEGIN

   product <= signed(x) * signed(weight);

   mac_accumulate_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            acc <= (OTHERS => '0');
         ELSIF (clear = '1') THEN
            acc <= bias;
         ELSIF (enable = '1') THEN
            acc <= std_logic_vector(signed(acc) + resize(product, 32));
         END IF;
      END IF;

   END PROCESS mac_accumulate_proc;

END ARCHITECTURE rtl;
