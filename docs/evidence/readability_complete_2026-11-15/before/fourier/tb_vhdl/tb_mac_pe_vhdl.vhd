------------------------------------------------------------
-- mac_pe 모듈 단독 TB
-- DUT  : mac_pe_rtl.vhd
-- 근거 : DESIGN.md INT8 입력/weight, INT32 누산 계약
-- TC1 reset, TC2 clear 우선, TC3 signed 곱셈, TC4 hold
-- TC5 32비트 누산 wrap. 기대값은 기존 RTL 폭 규칙을 따른다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE std.env.ALL;

LIBRARY xil_defaultlib;

ENTITY tb_mac_pe_vhdl IS
END ENTITY tb_mac_pe_vhdl;

ARCHITECTURE sim OF tb_mac_pe_vhdl IS

   CONSTANT CLK_PERIOD          : time                          := 10 ns;
   SIGNAL   clk                 : std_logic                     := '0';
   SIGNAL   rst                 : std_logic                     := '1';
   SIGNAL   clear,       enable : std_logic                     := '0';
   SIGNAL   input_value, weight : std_logic_vector(7 DOWNTO 0)  := (OTHERS => '0');
   SIGNAL   bias                : std_logic_vector(31 DOWNTO 0) := (OTHERS => '0');
   SIGNAL   accumulator         : std_logic_vector(31 DOWNTO 0);

   COMPONENT mac_pe IS
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
   END COMPONENT mac_pe;

    FOR ALL : mac_pe USE ENTITY xil_defaultlib.mac_pe(rtl);

BEGIN

   U_DUT : COMPONENT mac_pe
      PORT MAP (
         clk    => clk,
         rst    => rst,
         clear  => clear,
         enable => enable,
         x      => input_value,
         weight => weight,
         bias   => bias,
         acc    => accumulator
      );

   clock_gen_proc : PROCESS IS
   BEGIN

      clk <= '0', '1' AFTER CLK_PERIOD / 2;
      WAIT FOR CLK_PERIOD;

   END PROCESS clock_gen_proc;

   stim_proc : PROCESS IS
   BEGIN

      WAIT UNTIL falling_edge(clk);
      ASSERT signed(accumulator) = 0
         REPORT "TC1 FAIL: reset"
         SEVERITY FAILURE;
      rst <= '0';

      clear       <= '1';
      enable      <= '1';
      bias        <= std_logic_vector(to_signed(123456, 32));
      input_value <= std_logic_vector(to_signed(-128, 8));
      weight      <= std_logic_vector(to_signed(127, 8));
      WAIT UNTIL falling_edge(clk);
      ASSERT signed(accumulator) = 123456
         REPORT "TC2 FAIL: clear priority"
         SEVERITY FAILURE;

      clear  <= '0';
      WAIT UNTIL falling_edge(clk);
      ASSERT signed(accumulator) = 107200
         REPORT "TC3 FAIL: signed product"
         SEVERITY FAILURE;
      enable <= '0';
      WAIT UNTIL falling_edge(clk);
      ASSERT signed(accumulator) = 107200
         REPORT "TC4 FAIL: hold"
         SEVERITY FAILURE;

      clear       <= '1';
      bias        <= x"7FFFFFFF";
      WAIT UNTIL falling_edge(clk);
      clear       <= '0';
      enable      <= '1';
      input_value <= x"01";
      weight      <= x"01";
      WAIT UNTIL falling_edge(clk);
      ASSERT accumulator = x"80000000"
         REPORT "TC5 FAIL: INT32 wrap"
         SEVERITY FAILURE;

      REPORT "TEST PASS tb_mac_pe_vhdl: reset, clear priority, signed MAC, hold, wrap"
         SEVERITY NOTE;
      stop;
      WAIT;

   END PROCESS stim_proc;

END ARCHITECTURE sim;
