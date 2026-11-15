set root [file normalize [file join [file dirname [info script]] ..]]
if {![string match "2024.2*" [version -short]]} { error "Use Vivado 2024.2, matching this package target." }
set py python3
if {[info exists ::env(FPGA_PYTHON)]} {
    set py $::env(FPGA_PYTHON)
} elseif {[file executable /usr/bin/python3]} {
    set py /usr/bin/python3
}
proc gate {action stage} {
    global py root
    if {[catch {exec $py [file join $root tools gates.py] $action $stage} result]} {error $result}
}
proc add_rtl {project} {
    global root
    if {$project ne "fourier"} {error "VHDL source list is defined only for fourier"}
    # Package first, followed by entities and their dependants. The original
    # Verilog is retained separately as the simulation comparison baseline.
    set source_paths {
        fourier/vhdl/vibration_types.vhd fourier/vhdl/vibration_regs.vhd
        common/reset_sync.vhd fourier/vhdl/input_sync_rtl.vhd
        fourier/vhdl/mac_pe_rtl.vhd fourier/vhdl/fault_latch_rtl.vhd
        fourier/vhdl/safety_supervisor_rtl.vhd fourier/vhdl/unsigned_divider_rtl.vhd
        fourier/vhdl/pwm_period_rtl.vhd fourier/vhdl/mpu_spi_fsm.vhd
        fourier/vhdl/fft64_features_fsm.vhd fourier/vhdl/npu_2pe_fsm.vhd
        fourier/vhdl/vibration_core_fsm.vhd fourier/vhdl/pid_controller_fsm.vhd
        fourier/vhdl/encoder_quadrature_rtl.vhd fourier/vhdl/encoder_speed_rtl.vhd
        fourier/vhdl/motor_run_control_rtl.vhd
        fourier/vhdl/fourier_motor_struct.vhd fourier/vhdl/fourier_motor_control.vhd
        fourier/vhdl/axi_registers_rtl.vhd
        fourier/vhdl/axi_vibration_struct.vhd fourier/vhdl/axi_vibration_top.vhd
    }
    foreach path $source_paths {add_files -norecurse [file join $root $path]}
    set_property file_type {VHDL 2008} [get_files *.vhd]
    # Vivado 2024.2 IP Integrator requires the referenced top file to be
    # VHDL-93. These shells only connect ports to the VHDL-2008 implementations.
    set_property file_type VHDL [get_files [file join $root fourier vhdl axi_vibration_top.vhd]]
    set_property file_type VHDL [get_files [file join $root fourier vhdl fourier_motor_control.vhd]]
    add_files [glob [file join $root data *.mem]]
    set_property file_type {Memory File} [get_files *.mem]
    set_property target_language VHDL [current_project]
    set_property simulator_language Mixed [current_project]
}
proc ip {name vlnv} {return [create_bd_cell -type ip -vlnv $vlnv $name]}
proc net {args} {set pins {};foreach name $args {lappend pins [get_bd_pins $name]};connect_bd_net {*}$pins}
