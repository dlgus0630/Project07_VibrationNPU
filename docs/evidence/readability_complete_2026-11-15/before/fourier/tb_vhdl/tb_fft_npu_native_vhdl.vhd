------------------------------------------------------------
-- FFT/NPU 연결 TB (VHDL)
-- DUT  : fft64_features_fsm.vhd + npu_2pe_fsm.vhd
-- 근거 : DESIGN.md 정수 형식/대역/동점 class 0 계약
-- 입력 : 기존 samples.mem 20개, 가중치/기대값 파일도 그대로 사용
-- TC1  : 각 입력의 4개 FFT 특징 일치
-- TC2  : hidden 4개, logits 2개, class 일치
-- TC3  : NPU 처리 시간 18클럭과 완료 시 busy 해제
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE std.env.ALL;

LIBRARY xil_defaultlib;
   USE xil_defaultlib.vibration_types.ALL;

ENTITY tb_fft_npu_native_vhdl IS
END ENTITY tb_fft_npu_native_vhdl;

ARCHITECTURE sim OF tb_fft_npu_native_vhdl IS

   CONSTANT CLK_PERIOD        : time                                     := 10 ns;
   CONSTANT CASE_COUNT        : positive                                 := 20;
   CONSTANT SAMPLES           : signed16_array(0 TO CASE_COUNT * 64 - 1) := load16("samples.mem", CASE_COUNT * 64);
   CONSTANT EXPECTED_FEATURES : signed8_array(0 TO CASE_COUNT * 4 - 1)   := load8("features.mem", CASE_COUNT * 4);
   CONSTANT EXPECTED_HIDDEN   : signed8_array(0 TO CASE_COUNT * 4 - 1)   := load8("hidden.mem", CASE_COUNT * 4);
   CONSTANT EXPECTED_LOGITS   : signed8_array(0 TO CASE_COUNT * 2 - 1)   := load8("logits.mem", CASE_COUNT * 2);
   CONSTANT EXPECTED_CLASS    : signed8_array(0 TO CASE_COUNT - 1)       := load8("class.mem", CASE_COUNT);

   SIGNAL clk                  : std_logic                         := '0';
   SIGNAL rst                  : std_logic                         := '1';
   SIGNAL fft_start, npu_start : std_logic                         := '0';
   SIGNAL fft_busy             : std_logic;
   SIGNAL fft_done             : std_logic;
   SIGNAL sample_enable        : std_logic;
   SIGNAL npu_busy             : std_logic;
   SIGNAL npu_done             : std_logic;
   SIGNAL class_id             : std_logic;
   SIGNAL sample_address       : std_logic_vector(5 DOWNTO 0);
   SIGNAL sample_data          : std_logic_vector(15 DOWNTO 0)     := (OTHERS => '0');
   SIGNAL features             : std_logic_vector(31 DOWNTO 0);
   SIGNAL hidden               : std_logic_vector(31 DOWNTO 0);
   SIGNAL cycles               : std_logic_vector(31 DOWNTO 0);
   SIGNAL logits               : std_logic_vector(15 DOWNTO 0);
   SIGNAL current_case         : natural RANGE 0 TO CASE_COUNT - 1 := 0;

   COMPONENT fft64_features IS
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
   END COMPONENT fft64_features;

   COMPONENT npu_2pe IS
      PORT (
         clk      : IN    std_logic;
         rst      : IN    std_logic;
         start    : IN    std_logic;
         features : IN    std_logic_vector(31 DOWNTO 0);
         busy     : OUT   std_logic;
         done     : OUT   std_logic;
         hidden   : OUT   std_logic_vector(31 DOWNTO 0);
         logits   : OUT   std_logic_vector(15 DOWNTO 0);
         class_id : OUT   std_logic;
         cycles   : OUT   std_logic_vector(31 DOWNTO 0)
      );
   END COMPONENT npu_2pe;

    FOR ALL : fft64_features USE ENTITY xil_defaultlib.fft64_features(rtl);
    FOR ALL : npu_2pe USE ENTITY xil_defaultlib.npu_2pe(rtl);

BEGIN

   U_FFT : COMPONENT fft64_features
      PORT MAP (
         clk         => clk,
         rst         => rst,
         start       => fft_start,
         sample_en   => sample_enable,
         sample_addr => sample_address,
         sample_data => sample_data,
         busy        => fft_busy,
         done        => fft_done,
         features    => features
      );

   U_NPU : COMPONENT npu_2pe
      PORT MAP (
         clk      => clk,
         rst      => rst,
         start    => npu_start,
         features => features,
         busy     => npu_busy,
         done     => npu_done,
         hidden   => hidden,
         logits   => logits,
         class_id => class_id,
         cycles   => cycles
      );

   clock_gen_proc : PROCESS IS
   BEGIN

      clk <= '0', '1' AFTER CLK_PERIOD / 2;
      WAIT FOR CLK_PERIOD;

   END PROCESS clock_gen_proc;

   -- 기존 외부 BRAM과 같은 1클럭 응답을 제공한다.
   sample_source_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (sample_enable = '1') THEN
            sample_data <= std_logic_vector(samples(current_case * 64 + to_integer(unsigned(sample_address))));
         END IF;
      END IF;

   END PROCESS sample_source_proc;

   stim_proc : PROCESS IS
   BEGIN

      FOR n IN 1 TO 4 LOOP

         WAIT UNTIL falling_edge(clk);

      END LOOP;

      rst <= '0';

      FOR case_index IN 0 TO CASE_COUNT - 1 LOOP

         current_case <= case_index;
         WAIT UNTIL falling_edge(clk);
         fft_start    <= '1';
         WAIT UNTIL falling_edge(clk);
         fft_start    <= '0';
         WAIT UNTIL fft_done = '1' FOR 20 us;
         ASSERT fft_done = '1'
            REPORT "TC1 FAIL: FFT timeout"
            SEVERITY FAILURE;
         WAIT UNTIL falling_edge(clk);

         FOR channel IN 0 TO 3 LOOP

            ASSERT features(channel * 8 + 7 DOWNTO channel * 8) =
                   std_logic_vector(expected_features(case_index * 4 + channel))
               REPORT "TC1 FAIL: features case " & integer'IMAGE(case_index) & " channel " & integer'IMAGE(channel)
               SEVERITY FAILURE;

         END LOOP;

         npu_start <= '1';
         WAIT UNTIL falling_edge(clk);
         npu_start <= '0';
         WAIT UNTIL npu_done = '1' FOR 1 us;
         ASSERT npu_done = '1'
            REPORT "TC2 FAIL: NPU timeout"
            SEVERITY FAILURE;
         WAIT UNTIL falling_edge(clk);

         FOR channel IN 0 TO 3 LOOP

            ASSERT hidden(channel * 8 + 7 DOWNTO channel * 8) =
                   std_logic_vector(expected_hidden(case_index * 4 + channel))
               REPORT "TC2 FAIL: hidden case " & integer'IMAGE(case_index)
               SEVERITY FAILURE;

         END LOOP;

         FOR channel IN 0 TO 1 LOOP

            ASSERT logits(channel * 8 + 7 DOWNTO channel * 8) =
                   std_logic_vector(expected_logits(case_index * 2 + channel))
               REPORT "TC2 FAIL: logits case " & integer'IMAGE(case_index)
               SEVERITY FAILURE;

         END LOOP;

         ASSERT class_id = expected_class(case_index)(0)
            REPORT "TC2 FAIL: class case " & integer'IMAGE(case_index)
            SEVERITY FAILURE;
         ASSERT unsigned(cycles) = 18 AND npu_busy = '0'
            REPORT "TC3 FAIL: NPU cycle/busy contract"
            SEVERITY FAILURE;

      END LOOP;

      REPORT "TEST PASS tb_fft_npu_native_vhdl: 20 Golden cases and NPU 18 cycles"
         SEVERITY NOTE;
      stop;
      WAIT;

   END PROCESS stim_proc;

END ARCHITECTURE sim;
