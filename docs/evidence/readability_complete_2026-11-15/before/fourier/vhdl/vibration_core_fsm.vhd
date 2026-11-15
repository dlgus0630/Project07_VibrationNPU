------------------------------------------------------------
-- 가속기 순서 제어 : FFT → NPU → BRAM 결과 11개 기록
-- 근거 : DESIGN.md의 START/busy/DONE 및 BRAM 배치 계약
-- 상태/데이터/카운터의 소유 프로세스를 분리한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY vibration_core IS
   PORT (
      clk        : IN    std_logic;
      rst        : IN    std_logic;
      start      : IN    std_logic;
      busy       : OUT   std_logic;
      done       : OUT   std_logic;
      cycles     : OUT   std_logic_vector(31 DOWNTO 0);
      npu_cycles : OUT   std_logic_vector(31 DOWNTO 0);
      features   : OUT   std_logic_vector(31 DOWNTO 0);
      hidden     : OUT   std_logic_vector(31 DOWNTO 0);
      logits     : OUT   std_logic_vector(15 DOWNTO 0);
      class_id   : OUT   std_logic;
      bram_en    : OUT   std_logic;
      bram_we    : OUT   std_logic_vector(3 DOWNTO 0);
      bram_addr  : OUT   std_logic_vector(9 DOWNTO 0);
      bram_wdata : OUT   std_logic_vector(31 DOWNTO 0);
      bram_rdata : IN    std_logic_vector(31 DOWNTO 0)
   );
END ENTITY vibration_core;

ARCHITECTURE rtl OF vibration_core IS

   CONSTANT IDLE   : integer := 0;
   CONSTANT FSTART : integer := 1;
   CONSTANT FWAIT  : integer := 2;
   CONSTANT NSTART : integer := 3;
   CONSTANT NWAIT  : integer := 4;
   CONSTANT STORE  : integer := 5;

   SIGNAL state, next_state : integer RANGE 0 TO 7;
   SIGNAL result_index      : unsigned(3 DOWNTO 0);

   SIGNAL fft_start          : std_logic;
   SIGNAL fft_busy           : std_logic;
   SIGNAL fft_done           : std_logic;
   SIGNAL fft_sample_enable  : std_logic;
   SIGNAL fft_sample_address : std_logic_vector(5 DOWNTO 0);
   SIGNAL fft_features       : std_logic_vector(31 DOWNTO 0);

   SIGNAL npu_start  : std_logic;
   SIGNAL npu_busy   : std_logic;
   SIGNAL npu_done   : std_logic;
   SIGNAL npu_class  : std_logic;
   SIGNAL npu_hidden : std_logic_vector(31 DOWNTO 0);
   SIGNAL npu_logits : std_logic_vector(15 DOWNTO 0);

BEGIN

   U_FFT : ENTITY work.fft64_features(rtl)
      PORT MAP (
         clk         => clk,
         rst         => rst,
         start       => fft_start,
         sample_en   => fft_sample_enable,
         sample_addr => fft_sample_address,
         sample_data => bram_rdata(15 DOWNTO 0),
         busy        => fft_busy,
         done        => fft_done,
         features    => fft_features
      );

   U_NPU : ENTITY work.npu_2pe(rtl)
      PORT MAP (
         clk      => clk,
         rst      => rst,
         start    => npu_start,
         features => features,
         busy     => npu_busy,
         done     => npu_done,
         hidden   => npu_hidden,
         logits   => npu_logits,
         class_id => npu_class,
         cycles   => npu_cycles
      );

   -- 각 시작 펄스는 해당 START 상태의 한 클럭 동안 발생한다.
   fft_start <= bit_if(state = FSTART);
   npu_start <= bit_if(state = NSTART);
   bram_en   <= bit_if(state = STORE) OR fft_sample_enable;
   bram_we   <= x"F" WHEN state = STORE ELSE
                x"0";
   bram_addr <= std_logic_vector(to_unsigned(256, 10) + resize(result_index, 10))
                WHEN state = STORE ELSE
                "0000" & fft_sample_address;

   --------------------------------------------------------
   -- 현재 상태 레지스터
   --------------------------------------------------------
   clocked_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            state <= IDLE;
         ELSE
            state <= next_state;
         END IF;
      END IF;

   END PROCESS clocked_proc;

   --------------------------------------------------------
   -- 다음 상태 : 연산 지연을 추가하지 않는 조합 논리
   --------------------------------------------------------
   nextstate_proc : PROCESS (ALL) IS
   BEGIN

      next_state <= state;

      CASE state IS

         WHEN IDLE =>

            IF (start = '1') THEN
               next_state <= FSTART;
            END IF;

         WHEN FSTART =>

            next_state <= FWAIT;

         WHEN FWAIT =>

            IF (fft_done = '1') THEN
               next_state <= NSTART;
            END IF;

         WHEN NSTART =>

            next_state <= NWAIT;

         WHEN NWAIT =>

            IF (npu_done = '1') THEN
               next_state <= STORE;
            END IF;

         WHEN STORE =>

            IF (result_index = 10) THEN
               next_state <= IDLE;
            END IF;

         WHEN OTHERS =>

            next_state <= IDLE;

      END CASE;

   END PROCESS nextstate_proc;

   --------------------------------------------------------
   -- 연산 결과 보관 : feature/hidden/logits/class의 유일한 writer
   --------------------------------------------------------
   result_capture_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            features <= (OTHERS => '0');
            hidden   <= (OTHERS => '0');
            logits   <= (OTHERS => '0');
            class_id <= '0';
         ELSE
            IF (state = FWAIT AND fft_done = '1') THEN
               features <= fft_features;
            END IF;
            IF (state = NWAIT AND npu_done = '1') THEN
               hidden   <= npu_hidden;
               logits   <= npu_logits;
               class_id <= npu_class;
            END IF;
         END IF;
      END IF;

   END PROCESS result_capture_proc;

   --------------------------------------------------------
   -- 결과 기록 순번 : feature 4 + hidden 4 + logits 2 + class 1
   --------------------------------------------------------
   result_index_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            result_index <= (OTHERS => '0');
         ELSIF (state = NWAIT AND npu_done = '1') THEN
            result_index <= (OTHERS => '0');
         ELSIF (state = STORE AND result_index /= 10) THEN
            result_index <= result_index + 1;
         END IF;
      END IF;

   END PROCESS result_index_proc;

   --------------------------------------------------------
   -- busy/DONE : 마지막 BRAM write가 끝나는 클럭에 완료
   --------------------------------------------------------
   handshake_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy <= '0';
         ELSE

            CASE state IS

               WHEN IDLE =>

                  IF (start = '1') THEN
                     busy <= '1';
                  END IF;

               WHEN STORE =>

                  IF (result_index = 10) THEN
                     busy <= '0';
                     done <= '1';
                  END IF;

               WHEN FSTART | FWAIT | NSTART | NWAIT =>

                  NULL;

               WHEN OTHERS =>

                  busy <= '0';

            END CASE;

         END IF;
      END IF;

   END PROCESS handshake_proc;

   cycle_count_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            cycles <= (OTHERS => '0');
         ELSIF (state = IDLE AND start = '1') THEN
            cycles <= (OTHERS => '0');
         ELSIF (busy = '1') THEN
            cycles <= std_logic_vector(unsigned(cycles) + 1);
         END IF;
      END IF;

   END PROCESS cycle_count_proc;

   --------------------------------------------------------
   -- BRAM 데이터 선택 : 주소 순서와 signed 확장은 기존과 동일
   --------------------------------------------------------
   result_write_proc : PROCESS (ALL) IS

      VARIABLE index_value : natural;

   BEGIN

      index_value := to_integer(result_index);
      bram_wdata  <= (OTHERS => '0');

      IF (index_value < 4) THEN
         bram_wdata <= x"000000" & features(index_value * 8 + 7 DOWNTO index_value * 8);
      ELSIF (index_value < 8) THEN
         bram_wdata <= x"000000" & hidden((index_value - 4) * 8 + 7 DOWNTO (index_value - 4) * 8);
      ELSIF (index_value = 8) THEN
         bram_wdata <= std_logic_vector(resize(signed(logits(7 DOWNTO 0)), 32));
      ELSIF (index_value = 9) THEN
         bram_wdata <= std_logic_vector(resize(signed(logits(15 DOWNTO 8)), 32));
      ELSE
         bram_wdata <= (31 DOWNTO 1 => '0') & class_id;
      END IF;

   END PROCESS result_write_proc;

END ARCHITECTURE rtl;
