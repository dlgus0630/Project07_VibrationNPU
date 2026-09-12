# PS FCLK0 is 100 MHz; clock and DDR constraints are provided by the board-preset PS IP.
# Digilent Zybo-Z7-Master.xdc: JE1..4.
set_property PACKAGE_PIN V12 [get_ports mpu_sclk]
set_property PACKAGE_PIN W16 [get_ports mpu_mosi]
set_property PACKAGE_PIN J15 [get_ports mpu_miso]
set_property PACKAGE_PIN H15 [get_ports mpu_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports {mpu_sclk mpu_mosi mpu_miso mpu_cs_n}]
set_property SLEW SLOW [get_ports {mpu_sclk mpu_mosi mpu_cs_n}]
# SPI is a 1 MHz enable-driven protocol, not an internal clock domain.
# MISO is sampled through two synchronizer flops. See hardware timing qualification in README.
set_false_path -from [get_ports mpu_miso]
# The enable-driven 1 MHz sensor timing is verified as a protocol, without an external clock.
set_false_path -to [get_ports {mpu_sclk mpu_mosi mpu_cs_n}]

# Fixed-duty L298N drive: JD1 -> ENA, JD2 -> IN1, JD3 -> IN2.
# Digilent Zybo-Z7-Master.xdc; sensor remains on JE1..4.
set_property PACKAGE_PIN T14 [get_ports motor_pwm]
set_property PACKAGE_PIN T15 [get_ports motor_in1]
set_property PACKAGE_PIN P14 [get_ports motor_in2]
set_property PACKAGE_PIN G15 [get_ports {motor_sw[0]}]
set_property PACKAGE_PIN P15 [get_ports {motor_sw[1]}]
set_property PACKAGE_PIN W13 [get_ports {motor_sw[2]}]
set_property PACKAGE_PIN K18 [get_ports motor_stop]
set_property PACKAGE_PIN M14 [get_ports motor_armed]
set_property IOSTANDARD LVCMOS33 [get_ports {motor_pwm motor_in1 motor_in2 motor_sw[*] motor_stop motor_armed}]
set_false_path -from [get_ports {motor_sw[*]}]
set_false_path -from [get_ports motor_stop]
set_false_path -to [get_ports {motor_pwm motor_in1 motor_in2 motor_armed}]
