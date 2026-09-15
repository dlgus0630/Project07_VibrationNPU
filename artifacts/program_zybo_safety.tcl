set R [file normalize [file join [file dirname [info script]] ..]]

connect
targets -set -nocase -filter {name =~ "APU*" || name =~ "DAP*"}
puts "STEP0 system reset"
rst -srst
after 3000

targets -set -nocase -filter {name =~ "xc7z020*"}
puts "STEP1 safety FPGA download"
fpga -file $R/artifacts/fourier_safety_supervisor.bit

targets -set -nocase -filter {name =~ "ARM*#0"}
stop
configparams force-mem-access 1
puts "STEP2 PS initialization"
source $R/artifacts/ps7_init.tcl
ps7_init
ps7_post_config

puts "STEP3 safety firmware download"
rst -processor
dow $R/artifacts/fourier_safety_supervisor.elf
configparams force-mem-access 0
con
after 1500
puts "SAFETY IMAGE RUNNING"
exit
