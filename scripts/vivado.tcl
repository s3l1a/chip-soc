# Generic out-of-context assessment only. Deliberately no write_bitstream.
# vivado -mode batch -source scripts/vivado.tcl -tclargs [synth|impl] [output-dir]
set root [file normalize [file join [file dirname [info script]] ..]]
set mode synth
if {[llength $argv] > 0} { set mode [lindex $argv 0] }
if {$mode ni {synth impl}} { error "mode must be synth or impl" }
set out [file join $root build vivado]
if {[llength $argv] > 1} { set out [file normalize [lindex $argv 1]] }
file mkdir $out

proc collect_rtl {dir} {
    set sources {}
    foreach path [lsort [glob -nocomplain -directory $dir *]] {
        if {[file isdirectory $path]} {
            set sources [concat $sources [collect_rtl $path]]
        } elseif {[file extension $path] eq ".sv"} {
            lappend sources $path
        }
    }
    return $sources
}
create_project -in_memory -part xc7s50csga324-1
set sources [collect_rtl [file join $root rtl]]
# Prefer the canonical RTL tree; legacy root sources are not mixed into it.
if {[llength $sources] == 0} { error "no canonical RTL sources in rtl/" }
set package [file join $root rtl soc soc_pkg.sv]
if {![file exists $package]} { error "missing rtl/soc/soc_pkg.sv" }
read_verilog -sv $package
set top_found 0
foreach source $sources {
    if {$source ne $package && [file tail $source] ne "sim_ram.sv"} { read_verilog -sv $source }
    if {[file tail $source] eq "soc_top.sv"} { set top_found 1 }
}
if {!$top_found} { error "missing canonical rtl/soc/soc_top.sv" }
read_xdc [file join $root boards generic timing.xdc]
synth_design -top soc_top -part xc7s50csga324-1 -mode out_of_context
foreach port {cpu_clk rst_n pixel_clk pixel_rst_n uart_tx uart_rx} {
    if {[llength [get_ports -quiet $port]] != 1} {
        error "expected generic soc_top port $port; board-clock legacy top is unsupported"
    }
}
report_utilization -file [file join $out synthesis_utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $out synthesis_timing.rpt]
report_clocks -file [file join $out synthesis_clocks.rpt]
report_clock_interaction -file [file join $out synthesis_clock_interaction.rpt]
report_cdc -details -file [file join $out synthesis_cdc.rpt]
report_drc -file [file join $out synthesis_drc.rpt]
report_methodology -file [file join $out synthesis_methodology.rpt]
write_checkpoint -force [file join $out synthesis.dcp]
if {$mode eq "impl"} {
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -file [file join $out implementation_utilization.rpt]
    report_timing_summary -report_unconstrained -file [file join $out implementation_timing.rpt]
    report_drc -file [file join $out implementation_drc.rpt]
    report_methodology -file [file join $out implementation_methodology.rpt]
    report_clocks -file [file join $out implementation_clocks.rpt]
    report_clock_interaction -file [file join $out implementation_clock_interaction.rpt]
    report_cdc -details -file [file join $out implementation_cdc.rpt]
    write_checkpoint -force [file join $out implementation.dcp]
}
puts "Generic OOC assessment complete. No board pinout, RAM controller, or bitstream."
