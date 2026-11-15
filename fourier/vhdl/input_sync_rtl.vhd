------------------------------------------------------------
-- 단일 비동기 입력의 2단 동기화
-- 사용 : AXI 주변장치의 SPI MISO 입력
-- 리셋 : 메인 클럭에서 active-high 동기 리셋
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;

ENTITY input_sync IS
   PORT (
      clk      : IN    std_logic;
      rst      : IN    std_logic;
      async_in : IN    std_logic;
      sync_out : OUT   std_logic
   );
END ENTITY input_sync;

ARCHITECTURE rtl OF input_sync IS

   SIGNAL sync_pipe : std_logic_vector(1 DOWNTO 0);
   ATTRIBUTE async_reg : string;
   ATTRIBUTE async_reg OF sync_pipe : signal IS "TRUE";

BEGIN

   input_sync_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            sync_pipe <= (OTHERS => '0');
         ELSE
            sync_pipe <= sync_pipe(0) & async_in;
         END IF;
      END IF;

   END PROCESS input_sync_proc;

   sync_out <= sync_pipe(1);

END ARCHITECTURE rtl;
