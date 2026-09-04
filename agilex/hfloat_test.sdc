# Timing constraints for the Agilex hfloat_test build (Arrow AXC3000).
#
# clk_clk (25 MHz) and core_clock (120 MHz) are created by the SDC that
# Platform Designer generates for pll_120 and pulls in automatically - do
# not create_clock / derive_pll_clocks here (Agilex 3 has no derive_pll_clocks).

derive_clock_uncertainty

set_false_path -from [get_ports reset_reset_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]
