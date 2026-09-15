source [file join [file dirname [info script]] common.tcl]
set ::env(PYTHON) $py
unset -nocomplain ::env(PYTHONHOME)
unset -nocomplain ::env(PYTHONPATH)
gate clear sim
gate check matlab
set part xc7z020clg400-1
set simdir [file join $root build fourier_sim]
create_project -force fourier_sim $simdir -part $part
add_rtl fourier
add_files -fileset sim_1 [glob [file join $root fourier tb *.v]]
set_property file_type Verilog [get_files *.v]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
set tests {tb_mac tb_fft_npu tb_core tb_axi tb_spi tb_fault_latch tb_safety_supervisor tb_fourier_motor}
file mkdir [file join $root reports]
foreach test $tests {
    catch {close_sim}
    set_property top $test [get_filesets sim_1]
    update_compile_order -fileset sim_1
    reset_simulation -simset sim_1 -mode behavioral
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim
    set logpath [file join $simdir fourier_sim.sim sim_1 behav xsim simulate.log]
    if {![file exists $logpath]} {error "Simulation log missing: $logpath"}
    set f [open $logpath r];set log [read $f];close $f
    file copy -force $logpath [file join $root reports ${test}.log]
    if {[regexp {TEST FAIL|FATAL|ERROR:} $log] || ![string match "*TEST PASS $test*" $log]} {error "FAILED $test; inspect reports/${test}.log"}
    puts "VERIFIED $test"
}
gate mark sim
puts "XSIM REGRESSION PASS fourier"
