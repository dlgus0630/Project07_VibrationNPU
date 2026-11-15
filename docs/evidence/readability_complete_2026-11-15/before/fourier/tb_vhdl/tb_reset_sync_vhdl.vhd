------------------------------------------------------------
-- reset_sync 모듈 단독 TB
-- DUT  : common/reset_sync.vhd
-- 근거 : reset_sync의 비동기 인가/2클럭 동기 해제 계약
-- TC1  : 초기 FPGA 리셋과 비동기 리셋 인가
-- TC2  : 해제 후 첫 클럭은 유지, 두 번째 클럭에 해제
-- TC3  : 해제 도중 재인가하면 다시 두 클럭 유지
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE std.env.ALL;

LIBRARY xil_defaultlib;

ENTITY tb_reset_sync_vhdl IS
END ENTITY tb_reset_sync_vhdl;

ARCHITECTURE sim OF tb_reset_sync_vhdl IS

   CONSTANT CLK_PERIOD  : time := 10 ns;
   CONSTANT SETTLE_TIME : time := 1 ps;

   SIGNAL clk         : std_logic := '0';
   SIGNAL async_reset : std_logic := '0';
   SIGNAL sync_reset  : std_logic;

   COMPONENT reset_sync IS
      PORT (
         clk         : IN    std_logic;
         async_reset : IN    std_logic;
         sync_reset  : OUT   std_logic
      );
   END COMPONENT reset_sync;

    FOR ALL : reset_sync USE ENTITY xil_defaultlib.reset_sync(rtl);

BEGIN

   U_DUT : COMPONENT reset_sync
      PORT MAP (
         clk         => clk,
         async_reset => async_reset,
         sync_reset  => sync_reset
      );

   clock_gen_proc : PROCESS IS
   BEGIN

      clk <= '0', '1' AFTER CLK_PERIOD / 2;
      WAIT FOR CLK_PERIOD;

   END PROCESS clock_gen_proc;

   stim_proc : PROCESS IS
   BEGIN

      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC1 FAIL: power-on reset missing"
         SEVERITY FAILURE;

      WAIT FOR 2 ns;
      async_reset <= '1';
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC1 FAIL: asynchronous assertion"
         SEVERITY FAILURE;

      -- 해제를 클럭 에지 사이에 넣어 두 번의 상승 에지를 구분한다.
      WAIT UNTIL falling_edge(clk);
      async_reset <= '0';
      WAIT UNTIL rising_edge(clk);
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC2 FAIL: released on first clock"
         SEVERITY FAILURE;
      WAIT UNTIL rising_edge(clk);
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '0'
         REPORT "TC2 FAIL: not released on second clock"
         SEVERITY FAILURE;

      -- 정상 해제 상태에서도 다음 클럭을 기다리지 않고 인가돼야 한다.
      WAIT FOR 2 ns;
      async_reset <= '1';
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC3 FAIL: reassertion was not asynchronous"
         SEVERITY FAILURE;
      async_reset <= '0';
      WAIT UNTIL rising_edge(clk);
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC3 FAIL: first release clock"
         SEVERITY FAILURE;

      WAIT FOR 1 ns;
      async_reset <= '1';
      WAIT FOR SETTLE_TIME;
      async_reset <= '0';
      WAIT UNTIL rising_edge(clk);
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '1'
         REPORT "TC3 FAIL: release did not restart"
         SEVERITY FAILURE;
      WAIT UNTIL rising_edge(clk);
      WAIT FOR SETTLE_TIME;
      ASSERT sync_reset = '0'
         REPORT "TC3 FAIL: restarted release incomplete"
         SEVERITY FAILURE;

      REPORT "TEST PASS tb_reset_sync_vhdl: power-on, async assertion, two-clock release, retrigger"
         SEVERITY NOTE;
      stop;
      WAIT;

   END PROCESS stim_proc;

END ARCHITECTURE sim;
