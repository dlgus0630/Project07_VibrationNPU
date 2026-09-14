set R [file normalize [file join [file dirname [info script]] ..]]

connect

# The board is already running the previous firmware, so the APU holds the DAP and
# ps7_init cannot write the PLL registers. Reset the whole system first, then load
# the PL, then halt core 0 before running ps7_init.
# The level-0 ARM target is reported as "APU" when healthy and "DAP" when the debug
# access port is in the APB transaction error state, so accept either name.
targets -set -nocase -filter {name =~ "APU*" || name =~ "DAP*"}
puts "STEP0 system reset"
rst -srst
after 3000
puts "STEP0 done"

targets -set -nocase -filter {name =~ "xc7z020*"}
puts "STEP1 fpga download start"
fpga -file $R/artifacts/fourier.bit
puts "STEP1 fpga download done"

targets -set -nocase -filter {name =~ "ARM*#0"}
stop
configparams force-mem-access 1
puts "STEP2 ps7 init start"
source $R/artifacts/ps7_init.tcl
ps7_init
ps7_post_config
puts "STEP2 ps7 init done"

puts "STEP3 elf load start"
rst -processor
dow $R/artifacts/fourier_app.elf
configparams force-mem-access 0
puts "STEP3 elf load done"

con
after 1500
puts "STEP4 processor running"
exit
