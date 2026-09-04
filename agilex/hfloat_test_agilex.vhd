------------------------------------------------------------------------
-- hfloat_test - Agilex (Arrow AXC3000, Agilex 3 A3CY100BM16AE7S) wrapper.
--
--   clk_clk       PIN_A7    1.3-V LVCMOS   25 MHz oscillator
--   reset_reset_n PIN_A12   1.3-V LVCMOS   active low, weak pull-up
--   uart_rxd      PIN_AG23  3.3-V LVCMOS
--   uart_txd      PIN_AG24  3.3-V LVCMOS
--
-- 25 MHz -> pll_100 IOPLL -> 100 MHz core clock.
-- g_clock_divider 25 -> 100e6 / 25 = 4.000 MBaud.
-- The Agilex native_fp32 hard-float DSP path is enabled here.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

entity hfloat_test_top is
    port (
        clk_clk        : in  std_logic
        ;reset_reset_n : in  std_logic
        ;uart_rxd      : in  std_logic
        ;uart_txd      : out std_logic
    );
end entity hfloat_test_top;

architecture rtl of hfloat_test_top is

    component pll_100 is
        port (
            rst       : in  std_logic := 'X'
            ;refclk   : in  std_logic := 'X'
            ;locked   : out std_logic
            ;outclk_0 : out std_logic
        );
    end component pll_100;

    signal core_clock : std_logic;
    signal pll_locked : std_logic;

begin

    u_pll : component pll_100
    port map (
        rst       => not reset_reset_n
        ,refclk   => clk_clk
        ,locked   => pll_locked
        ,outclk_0 => core_clock
    );

    u_core : entity work.hfloat_core
    generic map (
        g_clock_divider => 25
        ,g_has_native_fp => true
    )
    port map (
        clock   => core_clock
        ,reset  => (not reset_reset_n) or (not pll_locked)
        ,uart_rx => uart_rxd
        ,uart_tx => uart_txd
    );

end architecture rtl;
