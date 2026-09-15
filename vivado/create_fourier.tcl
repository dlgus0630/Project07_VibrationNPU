source [file join [file dirname [info script]] common.tcl]
if {[info exists ::env(DIGILENT_BOARD_REPO)]} {set_param board.repoPaths [list $::env(DIGILENT_BOARD_REPO)]}
create_project -force fourier [file join $root build fourier] -part xc7z020clg400-1
set boards [lsort -dictionary [get_board_parts -quiet *:zybo-z7-20:part0:*]]
if {[llength $boards]==0} {error "Install Digilent Zybo Z7-20 board files (2024.2 Board Store), or set DIGILENT_BOARD_REPO to new/board_files. Do not substitute guessed DDR settings."}
set_property board_part [lindex $boards end] [current_project]
add_rtl fourier
create_bd_design system
ip ps xilinx.com:ip:processing_system7:5.5
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} [get_bd_cells ps]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_USE_FABRIC_INTERRUPT {1} CONFIG.PCW_IRQ_F2P_INTR {1}] [get_bd_cells ps]
ip reset xilinx.com:ip:proc_sys_reset:5.0
ip one xilinx.com:ip:xlconstant:1.1
ip zero xilinx.com:ip:xlconstant:1.1
set_property CONFIG.CONST_VAL 0 [get_bd_cells zero]
ip interconnect xilinx.com:ip:smartconnect:1.0
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 2] [get_bd_cells interconnect]
ip ram_controller xilinx.com:ip:axi_bram_ctrl:4.1
set_property -dict [list CONFIG.DATA_WIDTH 32 CONFIG.SINGLE_PORT_BRAM 1] [get_bd_cells ram_controller]
ip memory xilinx.com:ip:blk_mem_gen:8.4
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.Use_BRAM_Block {BRAM_Controller} CONFIG.Write_Width_A 32 CONFIG.Read_Width_A 32 CONFIG.Write_Depth_A 1024 CONFIG.Write_Width_B 32 CONFIG.Read_Width_B 32 CONFIG.Register_PortB_Output_of_Memory_Primitives false] [get_bd_cells memory]
create_bd_cell -type module -reference axi_vibration_top accelerator
create_bd_cell -type module -reference fourier_motor_control motor
net ps/FCLK_CLK0 motor/clk
net reset/peripheral_aresetn motor/reset_n
create_bd_port -dir I -from 3 -to 0 motor_sw
connect_bd_net [get_bd_ports motor_sw] [get_bd_pins motor/sw]
create_bd_port -dir I motor_stop
connect_bd_net [get_bd_ports motor_stop] [get_bd_pins motor/stop_button]
foreach port {motor_pwm motor_in1 motor_in2 motor_armed motor_fault} {
    create_bd_port -dir O $port
    connect_bd_net [get_bd_ports $port] [get_bd_pins motor/$port]
}
# Classification -> motor guard, latched fault -> status register. Both cells run on
# ps/FCLK_CLK0 and reset/peripheral_aresetn, so this is a single clock domain.
net accelerator/class_valid motor/class_valid
net accelerator/class_id motor/class_id
net motor/motor_fault accelerator/motor_fault_latched
net accelerator/ps_heartbeat motor/ps_heartbeat
net motor/motor_warning accelerator/motor_warning
net motor/motor_derated accelerator/motor_derated
net motor/motor_watchdog_fault accelerator/motor_watchdog_fault
net motor/motor_fault_cause accelerator/motor_fault_cause
net motor/motor_fault_consec accelerator/motor_fault_consec
net motor/motor_abnormal_count accelerator/motor_abnormal_count
net ps/FCLK_CLK0 ps/M_AXI_GP0_ACLK reset/slowest_sync_clk interconnect/aclk ram_controller/s_axi_aclk accelerator/aclk
net ps/FCLK_RESET0_N reset/ext_reset_in
net one/dout reset/dcm_locked reset/aux_reset_in
net zero/dout reset/mb_debug_sys_rst
net reset/interconnect_aresetn interconnect/aresetn
net reset/peripheral_aresetn ram_controller/s_axi_aresetn accelerator/aresetn
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_GP0] [get_bd_intf_pins interconnect/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins interconnect/M00_AXI] [get_bd_intf_pins accelerator/S_AXI]
connect_bd_intf_net [get_bd_intf_pins interconnect/M01_AXI] [get_bd_intf_pins ram_controller/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ram_controller/BRAM_PORTA] [get_bd_intf_pins memory/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins accelerator/M_BRAM] [get_bd_intf_pins memory/BRAM_PORTB]
net accelerator/irq ps/IRQ_F2P
foreach port {mpu_sclk mpu_mosi mpu_cs_n} {create_bd_port -dir O $port;connect_bd_net [get_bd_ports $port] [get_bd_pins accelerator/$port]}
create_bd_port -dir I mpu_miso
connect_bd_net [get_bd_ports mpu_miso] [get_bd_pins accelerator/mpu_miso]
set ctrl_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins accelerator/S_AXI]]
set ram_seg [get_bd_addr_segs -of_objects [get_bd_intf_pins ram_controller/S_AXI]]
if {[llength $ctrl_seg]!=1 || [llength $ram_seg]!=1} {error "Unexpected AXI address segment count"}
assign_bd_address -offset 0x43C00000 -range 0x1000 -target_address_space [get_bd_addr_spaces ps/Data] $ctrl_seg
assign_bd_address -offset 0x40000000 -range 0x1000 -target_address_space [get_bd_addr_spaces ps/Data] $ram_seg
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $root fourier constraints zybo_z7_20.xdc]
update_compile_order -fileset sources_1
puts "PROJECT CREATED: no synthesis has run."
