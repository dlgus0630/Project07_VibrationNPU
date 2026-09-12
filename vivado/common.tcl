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
    add_files [glob [file join $root common *.v]]
    add_files [glob [file join $root $project rtl *.v]]
    set_property file_type Verilog [get_files *.v]
    add_files [glob [file join $root data *.mem]]
    set_property file_type {Memory File} [get_files *.mem]
    set_property target_language Verilog [current_project]
    set_property simulator_language Verilog [current_project]
}
proc ip {name vlnv} {return [create_bd_cell -type ip -vlnv $vlnv $name]}
proc net {args} {set pins {};foreach name $args {lappend pins [get_bd_pins $name]};connect_bd_net {*}$pins}
