# PROVISIONAL, NOT A COMPLETE BOARD CONSTRAINT SET. NOT USED BY vivado.tcl.
# F14 is a board oscillator pin, not a promise of a 50 MHz board oscillator.
# Intended future wrapper port, not the generic SoC's 50 MHz cpu_clk.
set_property PACKAGE_PIN F14 [get_ports clk_100mhz]
set_property PACKAGE_PIN U11 [get_ports uart_tx]
set_property PACKAGE_PIN V12 [get_ports uart_rx]
# I/O standards, oscillator frequency, reset, video and RAM pins are NOT verified.
