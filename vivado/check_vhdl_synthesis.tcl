# Separate out-of-context synthesis check. Does not touch the saved board project,
# final timing reports, hardware evidence, or official MATLAB/simulation gates.
set root [file normalize [file join [file dirname [info script]] ..]]
set outdir [file join $root build vhdl_synthesis_check]
file mkdir $outdir
cd $outdir
create_project -in_memory -part xc7z020clg400-1
set sources {
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
foreach source $sources { read_vhdl -vhdl2008 [file join $root $source] }
foreach memory [glob [file join $root data *.mem]] {
    file copy -force $memory [file join $outdir [file tail $memory]]
    add_files -norecurse $memory
}
set_property file_type {Memory Initialization Files} [get_files *.mem]
set top accelerator
if {[info exists ::env(VHDL_SYNTH_TOP)]} {set top $::env(VHDL_SYNTH_TOP)}
if {$top eq "accelerator"} {set top axi_vibration_top} elseif {$top eq "motor"} {set top fourier_motor_control} else {error "Invalid VHDL_SYNTH_TOP"}
synth_design -top $top -part xc7z020clg400-1 -mode out_of_context
report_utilization -file [file join $outdir ${top}_utilization.rpt]
puts "VHDL SYNTHESIS PASS $top (out of context; not a routed timing report)"
