# Timing constraints for the Agilex hfloat_test build (Arrow AXC3000).
#
# clk_clk (25 MHz) and core_clock (120 MHz) are created by the SDC that
# Platform Designer generates for pll_120 and pulls in automatically - do
# not create_clock / derive_pll_clocks here (Agilex 3 has no derive_pll_clocks).

derive_clock_uncertainty

set_false_path -from [get_ports reset_reset_n]
set_false_path -from [get_ports uart_rxd]
set_false_path -to   [get_ports uart_txd]

# reset_meta is the first flop of the reset synchroniser; its input is the
# async (not reset_reset_n) or (not pll_locked).  pll_locked crosses from the
# PLL control domain and just fails setup by ~0.15 ns at 120 MHz - the 2-FF
# sync is what handles it, so cut the path.
set_false_path -to [get_registers {*reset_meta*}]
