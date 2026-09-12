source [file join [file dirname [info script]] common.tcl]
gate check matlab
gate check sim
source [file join $root vivado create_fourier.tcl]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
set out [file join $root reports fourier]
file mkdir $out
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
report_drc -file [file join $out drc.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
foreach type {max min} {
    set path [get_timing_paths -delay_type $type -max_paths 1]
    if {[llength $path]!=1 || [get_property SLACK $path]<0} {error "Timing failed ($type), inspect reports/fourier"}
}
set violations [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $violations]>0} {error "DRC errors; bitstream blocked"}
set bitpath [file join [get_property DIRECTORY [get_runs impl_1]] [get_property TOP [current_fileset]].bit]
write_bitstream -force $bitpath
file copy -force $bitpath [file join $out fourier.bit]
write_hw_platform -fixed -include_bit -force [file join $out fourier.xsa]
puts "BUILD COMPLETE. Hardware measurements are still required."
