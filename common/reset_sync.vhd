LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;

ENTITY reset_sync IS
   PORT (
      clk         : IN    std_logic;
      async_reset : IN    std_logic;
      sync_reset  : OUT   std_logic
   );
END ENTITY reset_sync;

ARCHITECTURE rtl OF reset_sync IS

   SIGNAL reset_pipe : std_logic_vector(1 DOWNTO 0) := "11";
   ATTRIBUTE async_reg : string;
   ATTRIBUTE async_reg OF reset_pipe : signal IS "TRUE";

BEGIN

   reset_sync_proc : PROCESS (clk, async_reset) IS
   BEGIN

      IF (async_reset = '1') THEN
         reset_pipe <= "11";
      ELSIF rising_edge(clk) THEN
         reset_pipe <= reset_pipe(0) & '0';
      END IF;

   END PROCESS reset_sync_proc;

   sync_reset <= reset_pipe(1);

END ARCHITECTURE rtl;
