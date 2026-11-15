------------------------------------------------------------
-- 센서 SPI Mode-0 : 주소+데이터 16비트 또는 주소+데이터 24비트
-- 분주, 전송 제어, 수신 shift, 완료 결과를 별도 프로세스로 둔다.
-- read_two는 연속된 두 바이트를 CS 유지 상태에서 읽는다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

ENTITY mpu_reg_spi IS
   GENERIC (
      CLK_HZ : integer := 125000000;
      SPI_HZ : integer := 1000000
   );
   PORT (
      clk      : IN    std_logic;
      rst      : IN    std_logic;
      start    : IN    std_logic;
      rd       : IN    std_logic;
      read_two : IN    std_logic;
      addr     : IN    std_logic_vector(6 DOWNTO 0);
      wdata    : IN    std_logic_vector(7 DOWNTO 0);
      rdata    : OUT   std_logic_vector(7 DOWNTO 0);
      rdata16  : OUT   std_logic_vector(15 DOWNTO 0);
      busy     : OUT   std_logic;
      done     : OUT   std_logic;
      sclk     : OUT   std_logic;
      mosi     : OUT   std_logic;
      miso     : IN    std_logic;
      cs_n     : OUT   std_logic
   );
END ENTITY mpu_reg_spi;

ARCHITECTURE rtl OF mpu_reg_spi IS

   FUNCTION maximum (
      a,
      b : integer
   ) RETURN integer IS
   BEGIN

      IF (a > b) THEN
         RETURN a;
      ELSE
         RETURN b;
      END IF;

   END FUNCTION maximum;

   CONSTANT HALF_DIV : integer := maximum(1, (CLK_HZ + SPI_HZ * 2 - 1) / (SPI_HZ * 2));
   SIGNAL divcnt : unsigned(31 DOWNTO 0);
   SIGNAL bitcnt : unsigned(4 DOWNTO 0);
   SIGNAL tx, rx : std_logic_vector(23 DOWNTO 0);
   SIGNAL transaction_24 : std_logic;
   SIGNAL start_accepted : std_logic;
   SIGNAL clock_tick : std_logic;
   SIGNAL sample_edge : std_logic;
   SIGNAL transfer_complete : std_logic;

BEGIN

   -- 16비트/24비트 전송의 각 반주기 이벤트
   start_accepted    <= '1' WHEN start = '1' AND busy = '0' ELSE
                        '0';
   clock_tick        <= '1' WHEN busy = '1' AND divcnt = HALF_DIV - 1 ELSE
                        '0';
   sample_edge       <= clock_tick AND NOT sclk;
   transfer_complete <= '1' WHEN clock_tick = '1' AND sclk = '1' AND bitcnt = 0 ELSE
                        '0';

   -- 한 반주기마다 clock_tick을 발생시키는 분주 카운터.
   spi_divider_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR start_accepted = '1') THEN
            divcnt <= (OTHERS => '0');
         ELSIF (busy = '1') THEN
            IF (divcnt = HALF_DIV - 1) THEN
               divcnt <= (OTHERS => '0');
            ELSE
               divcnt <= divcnt + 1;
            END IF;
         END IF;
      END IF;

   END PROCESS spi_divider_proc;

   --------------------------------------------------------
   -- Mode-0 전송 제어 : 상승 에지에서 수신, 하강 에지에서 MOSI 변경
   --------------------------------------------------------
   transaction_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         done <= '0';
         IF (rst = '1') THEN
            busy           <= '0';
            sclk           <= '0';
            mosi           <= '0';
            cs_n           <= '1';
            bitcnt         <= (OTHERS => '0');
            tx             <= (OTHERS => '0');
            transaction_24 <= '0';
         ELSIF (start_accepted = '1') THEN
            busy <= '1';
            cs_n <= '0';
            sclk <= '0';
            mosi <= rd;
            IF (read_two = '1') THEN
               transaction_24 <= '1';
               bitcnt         <= to_unsigned(23, 5);
               tx             <= rd & addr & x"0000";
            ELSE
               transaction_24 <= '0';
               bitcnt         <= to_unsigned(15, 5);
               tx             <= x"00" & rd & addr & wdata;
            END IF;
         ELSIF (clock_tick = '1') THEN
            IF (sclk = '0') THEN
               sclk <= '1';
            ELSE
               sclk <= '0';
               IF (bitcnt = 0) THEN
                  busy <= '0';
                  cs_n <= '1';
                  done <= '1';
               ELSE
                  bitcnt <= bitcnt - 1;
                  mosi   <= tx(to_integer(bitcnt) - 1);
               END IF;
            END IF;
         END IF;
      END IF;

   END PROCESS transaction_proc;

   -- SCLK 상승 에지에 해당하는 클럭에서 MISO를 저장한다.
   receive_shift_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1' OR start_accepted = '1') THEN
            rx <= (OTHERS => '0');
         ELSIF (sample_edge = '1') THEN
            rx <= rx(22 DOWNTO 0) & miso;
         END IF;
      END IF;

   END PROCESS receive_shift_proc;

   -- 마지막 하강 에지에서 완성된 수신값을 출력에 보관한다.
   receive_result_proc : PROCESS (clk) IS
   BEGIN

      IF rising_edge(clk) THEN
         IF (rst = '1') THEN
            rdata   <= (OTHERS => '0');
            rdata16 <= (OTHERS => '0');
         ELSIF (transfer_complete = '1') THEN
            rdata <= rx(7 DOWNTO 0);
            IF (transaction_24 = '1') THEN
               rdata16 <= rx(15 DOWNTO 0);
            END IF;
         END IF;
      END IF;

   END PROCESS receive_result_proc;

END ARCHITECTURE rtl;
