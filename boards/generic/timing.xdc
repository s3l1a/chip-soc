# Generic SoC clocks are externally supplied. This is not a board clock plan.
create_clock -name cpu_clk -period 20.000 [get_ports cpu_clk]
create_clock -name pixel_clk -period 39.721946 [get_ports pixel_clk]
# No blanket asynchronous clock groups or false paths: CDC must be audited first.
