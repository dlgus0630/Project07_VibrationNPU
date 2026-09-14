set root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root build fourier fourier.xpr]
open_run impl_1

# Real-measurement weights changed the NPU constants, so the default route missed
# setup by -0.161 ns. Same remedy the previous build used: optimize the routed
# design, reroute changed nets, and write the bitstream/XSA only after the
# timing and DRC checks pass on the optimized result.
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore

set out [file join $root reports fourier_postroute]
file mkdir $out
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
report_drc -file [file join $out drc.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]

foreach type {max min} {
    set path [get_timing_paths -delay_type $type -max_paths 1]
    if {[llength $path] != 1} {error "No timing path found for $type"}
    set slack [get_property SLACK $path]
    puts "FINAL $type SLACK $slack ns"
    if {$slack < 0} {error "Timing failed ($type): $slack ns"}
}
set violations [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $violations] > 0} {error "DRC errors; bitstream blocked"}

write_checkpoint -force [file join $out fourier_real_model.dcp]

# write_hw_platform -fixed -include_bit reads the bitstream from the implementation
# run directory, so write it there under the expected top name before copying it out.
set bitpath [file join [get_property DIRECTORY [get_runs impl_1]] [get_property TOP [current_fileset]].bit]
write_bitstream -force $bitpath
file copy -force $bitpath [file join $out fourier_real_model.bit]
write_hw_platform -fixed -include_bit -force [file join $out fourier_real_model.xsa]
puts "REAL MODEL POST-ROUTE BUILD PASS"
