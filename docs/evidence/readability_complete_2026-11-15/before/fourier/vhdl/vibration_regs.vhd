------------------------------------------------------------
-- 진동 가속기 공통 레지스터 정의
-- 근거 : DESIGN.md의 AXI 주소 계약
-- 주소와 초기 게인은 기존 펌웨어/Verilog와 동일하다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;

PACKAGE vibration_regs IS

   SUBTYPE register_address IS std_logic_vector(11 DOWNTO 0);

   CONSTANT ADDR_CONTROL        : register_address := x"000";
   CONSTANT ADDR_STATUS         : register_address := x"004";
   CONSTANT ADDR_CLASS          : register_address := x"008";
   CONSTANT ADDR_TOTAL_CYCLES   : register_address := x"00C";
   CONSTANT ADDR_NPU_CYCLES     : register_address := x"010";
   CONSTANT ADDR_FEATURE_0      : register_address := x"020";
   CONSTANT ADDR_FEATURE_1      : register_address := x"024";
   CONSTANT ADDR_FEATURE_2      : register_address := x"028";
   CONSTANT ADDR_FEATURE_3      : register_address := x"02C";
   CONSTANT ADDR_LOGIT_0        : register_address := x"030";
   CONSTANT ADDR_LOGIT_1        : register_address := x"034";
   CONSTANT ADDR_SPI_COMMAND    : register_address := x"040";
   CONSTANT ADDR_SPI_STATUS     : register_address := x"044";
   CONSTANT ADDR_HEARTBEAT      : register_address := x"048";
   CONSTANT ADDR_SAFETY         : register_address := x"04C";
   CONSTANT ADDR_SPEED_TARGET   : register_address := x"050";
   CONSTANT ADDR_SPEED_MEASURED : register_address := x"054";
   CONSTANT ADDR_MOTOR_DUTY     : register_address := x"058";
   CONSTANT ADDR_PID_INTEGRAL   : register_address := x"05C";
   CONSTANT ADDR_MOTOR_ARMED    : register_address := x"060";
   CONSTANT ADDR_WATCHDOG_COUNT : register_address := x"064";
   CONSTANT ADDR_CONTROL_2      : register_address := x"068";
   CONSTANT ADDR_OPEN_LOOP_DUTY : register_address := x"06C";
   CONSTANT ADDR_KP_GAIN        : register_address := x"070";
   CONSTANT ADDR_KI_GAIN        : register_address := x"074";
   CONSTANT ADDR_QUAD_STATUS    : register_address := x"078";
   CONSTANT ADDR_QUAD_POSITION  : register_address := x"07C";
   CONSTANT ADDR_QUAD_ILLEGAL   : register_address := x"080";

   CONSTANT AXI_OKAY   : std_logic_vector(1 DOWNTO 0)  := "00";
   CONSTANT AXI_SLVERR : std_logic_vector(1 DOWNTO 0)  := "10";
   CONSTANT DEFAULT_KP : std_logic_vector(17 DOWNTO 0) := std_logic_vector(to_signed(58982, 18));
   CONSTANT DEFAULT_KI : std_logic_vector(17 DOWNTO 0) := std_logic_vector(to_signed(3932, 18));

END PACKAGE vibration_regs;
