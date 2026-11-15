source [file join [file dirname [info script]] common.tcl]
unset -nocomplain ::env(PYTHONHOME)
unset -nocomplain ::env(PYTHONPATH)
# Preserve the existing policy: no official simulation PASS until MATLAB has
# validated the current source digest. The standalone diagnostic runner itself
# never reads or writes any official PASS marker.
gate clear sim
gate check matlab
if {[catch {exec $py [file join $root tools run_vhdl_validation.py] 2>@1} result]} {
    puts $result
    error "VHDL simulation regression failed; inspect its run directory"
}
puts $result
gate mark sim
puts "XSIM VHDL REGRESSION PASS fourier"
