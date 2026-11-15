------------------------------------------------------------
-- 모터 최상위 구조 : 리셋, 운전, 안전, 인코더, PI, PWM 연결
-- 이 파일에서 U_* 인스턴스를 따라 각 기능 파일로 이동한다.
-- 포트와 generic은 기존 fourier_motor_control 계약을 유지한다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE work.vibration_types.ALL;

ENTITY fourier_motor_impl IS
   GENERIC (
      CLK_HZ          : integer := 100000000;
      FAULT_HZ        : integer := 32;
      FAULT_CONSEC    : integer := 3;
      WATCHDOG_CYCLES : integer := CLK_HZ / 2
   );
   PORT (
      clk                    : IN    std_logic;
      reset_n                : IN    std_logic;
      stop_button            : IN    std_logic;
      sw                     : IN    std_logic_vector(3 DOWNTO 0);
      motor_pwm              : OUT   std_logic;
      motor_in1              : OUT   std_logic;
      motor_in2              : OUT   std_logic;
      motor_armed            : OUT   std_logic;
      class_valid            : IN    std_logic;
      class_id               : IN    std_logic;
      ps_heartbeat           : IN    std_logic;
      motor_fault            : OUT   std_logic;
      motor_warning          : OUT   std_logic;
      motor_derated          : OUT   std_logic;
      motor_watchdog_fault   : OUT   std_logic;
      motor_fault_cause      : OUT   std_logic_vector(1 DOWNTO 0);
      motor_fault_consec     : OUT   std_logic_vector(7 DOWNTO 0);
      motor_abnormal_count   : OUT   std_logic_vector(15 DOWNTO 0);
      encoder_a              : IN    std_logic;
      encoder_b              : IN    std_logic;
      quad_position_wr_en    : IN    std_logic;
      quad_position_wr_value : IN    std_logic_vector(31 DOWNTO 0);
      quad_direction         : OUT   std_logic;
      quad_position          : OUT   std_logic_vector(31 DOWNTO 0);
      quad_illegal_fault     : OUT   std_logic;
      quad_illegal_count     : OUT   std_logic_vector(15 DOWNTO 0);
      quad_timeout_fault     : OUT   std_logic;
      quad_overflow_fault    : OUT   std_logic;
      motor_speed_reference  : OUT   std_logic_vector(12 DOWNTO 0);
      motor_measured_speed   : OUT   std_logic_vector(12 DOWNTO 0);
      motor_requested_duty   : OUT   std_logic_vector(12 DOWNTO 0);
      motor_pid_integral     : OUT   std_logic_vector(31 DOWNTO 0);
      motor_watchdog_count   : OUT   std_logic_vector(31 DOWNTO 0);
      kp_gain                : IN    std_logic_vector(17 DOWNTO 0);
      ki_gain                : IN    std_logic_vector(17 DOWNTO 0);
      anti_windup_enable     : IN    std_logic;
      open_loop_enable       : IN    std_logic;
      open_loop_duty         : IN    std_logic_vector(12 DOWNTO 0)
   );
END ENTITY fourier_motor_impl;

------------------------------------------------------------
-- 모터 구조 연결
-- U_RUN의 운전 명령과 각 기능 모듈을 이름 기반으로 연결한다.
------------------------------------------------------------

ARCHITECTURE structural OF fourier_motor_impl IS

   SIGNAL rst,      async_reset : std_logic;
   SIGNAL armed_command : std_logic;
   SIGNAL enabled : std_logic;
   SIGNAL clear_fault : std_logic;
   SIGNAL fault_latched : std_logic;
   SIGNAL sample_tick : std_logic;
   SIGNAL speed_valid : std_logic;
   SIGNAL encoder_pulse : std_logic;
   SIGNAL speed_reference : std_logic_vector(12 DOWNTO 0);
   SIGNAL measured_speed : std_logic_vector(12 DOWNTO 0);
   SIGNAL requested_duty : std_logic_vector(12 DOWNTO 0);
   SIGNAL pid_start : std_logic;
   SIGNAL pid_busy : std_logic;
   SIGNAL pid_done : std_logic;
   SIGNAL controller_reset : std_logic;
   SIGNAL pid_duty, active_duty : std_logic_vector(12 DOWNTO 0);
   SIGNAL pid_integral : std_logic_vector(31 DOWNTO 0);
   SIGNAL pid_derivative : std_logic_vector(17 DOWNTO 0);

BEGIN

   async_reset      <= NOT reset_n OR stop_button;
   controller_reset <= rst OR NOT enabled;

   U_RESET : ENTITY work.reset_sync(rtl)
      PORT MAP (
         clk         => clk,
         async_reset => async_reset,
         sync_reset  => rst
      );

   U_RUN : ENTITY work.motor_run_control(rtl)
      GENERIC MAP (
         clk_hz => CLK_HZ, fault_hz => FAULT_HZ
      )
      PORT MAP (
         clk              => clk,
         rst              => rst,
         reset_n          => reset_n,
         stop_button      => stop_button,
         sw               => sw,
         fault_latched    => fault_latched,
         derated          => motor_derated,
         speed_valid      => speed_valid,
         pid_busy         => pid_busy,
         pid_duty         => pid_duty,
         open_loop_enable => open_loop_enable,
         open_loop_duty   => open_loop_duty,
         armed            => armed_command,
         enabled          => enabled,
         clear_fault      => clear_fault,
         sample_tick      => sample_tick,
         pid_start        => pid_start,
         speed_reference  => speed_reference,
         duty             => requested_duty
      );

   U_SAFETY : ENTITY work.safety_supervisor(rtl)
      GENERIC MAP (
         trip_consec     => FAULT_CONSEC,
         derate_consec   => 2,
         watchdog_cycles => WATCHDOG_CYCLES
      )
      PORT MAP (
         clk                => clk,
         rst                => rst,
         clear              => clear_fault,
         armed              => armed_command,
         class_valid        => class_valid,
         class_id           => class_id,
         heartbeat          => ps_heartbeat,
         warning            => motor_warning,
         derated            => motor_derated,
         latched            => fault_latched,
         watchdog_fault     => motor_watchdog_fault,
         fault_cause        => motor_fault_cause,
         consec_count       => motor_fault_consec,
         abnormal_count     => motor_abnormal_count,
         watchdog_count_out => motor_watchdog_count
      );

   U_ENCODER : ENTITY work.encoder_speed_hybrid(rtl)
      GENERIC MAP (
         clk_hz => CLK_HZ
      )
      PORT MAP (
         clk         => clk,
         rst         => rst,
         sample_tick => sample_tick,
         encoder_a   => encoder_a,
         speed       => measured_speed,
         pulse       => encoder_pulse,
         speed_valid => speed_valid
      );

   U_PID : ENTITY work.pid_fixed(rtl)
      PORT MAP (
         clk                => clk,
         rst                => controller_reset,
         start              => pid_start,
         reference          => speed_reference,
         measured           => measured_speed,
         kp_gain            => kp_gain,
         ki_gain            => ki_gain,
         anti_windup_enable => anti_windup_enable,
         busy               => pid_busy,
         done               => pid_done,
         duty               => pid_duty,
         integral           => pid_integral,
         derivative         => pid_derivative
      );

   U_QUADRATURE : ENTITY work.encoder_quadrature(rtl)
      GENERIC MAP (
         clk_hz => CLK_HZ
      )
      PORT MAP (
         clk                      => clk,
         rst                      => rst,
         clear                    => clear_fault,
         enabled                  => enabled,
         duty                     => requested_duty,
         encoder_a                => encoder_a,
         encoder_b                => encoder_b,
         position_wr_en           => quad_position_wr_en,
         position_wr_value        => quad_position_wr_value,
         direction                => quad_direction,
         position                 => quad_position,
         illegal_transition_fault => quad_illegal_fault,
         illegal_transition_count => quad_illegal_count,
         timeout_fault            => quad_timeout_fault,
         overflow_fault           => quad_overflow_fault
      );

   U_PWM : ENTITY work.pwm_period(rtl)
      GENERIC MAP (
         period => CLK_HZ / 20000
      )
      PORT MAP (
         clk         => clk,
         rst         => rst,
         enable      => enabled,
         duty        => requested_duty,
         pwm         => motor_pwm,
         active_duty => active_duty
      );

   -- 외부 출력 연결
   motor_in1             <= enabled;
   motor_in2             <= '0';
   motor_armed           <= enabled;
   motor_fault           <= fault_latched;
   motor_speed_reference <= speed_reference;
   motor_measured_speed  <= measured_speed;
   motor_requested_duty  <= requested_duty;
   motor_pid_integral    <= pid_integral;

END ARCHITECTURE structural;
