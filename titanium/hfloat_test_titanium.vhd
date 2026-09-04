------------------------------------------------------------------------
-- hfloat_test - Efinix Titanium (Ti60F225) wrapper.
--
-- Reuses the titanium_build interface (peri.xml / sdc) unchanged so the
-- proven pin-out and PLL config carry over: 50 MHz ref -> main_clock
-- 120 MHz.  g_clock_divider 25 -> 120e6 / 25 = 4.800 MBaud (a rate the
-- host FT4232H generates exactly).
--
-- Only uart_rx / uart_tx and the clock are used; every other power-stage
-- / ADC / sigma-delta output is held at '0'.  The Agilex native_fp32
-- path is disabled (Titanium has no FP hard block).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

entity titanium_top is
    port (
        main_clock    : in std_logic
       ;main_clock_x2 : in std_logic
       ;pll_locked    : in std_logic

       ;uart_rx : in  std_logic
       ;uart_tx : out std_logic

       ;grid_inu_leg1_hi  : out std_logic
       ;grid_inu_leg1_low : out std_logic
       ;grid_inu_leg2_hi  : out std_logic
       ;grid_inu_leg2_low : out std_logic

       ;dab_primary_hi    : out std_logic
       ;dab_primary_low   : out std_logic
       ;dab_secondary_hi  : out std_logic
       ;dab_secondary_low : out std_logic

       ;output_inu_leg1_hi  : out std_logic
       ;output_inu_leg1_low : out std_logic
       ;output_inu_leg2_hi  : out std_logic
       ;output_inu_leg2_low : out std_logic

       ;primary_bypass_relay   : out std_logic
       ;secondary_bypass_relay : out std_logic

       ;gate_power1_pwm : out std_logic
       ;gate_power2_pwm : out std_logic
       ;gate_power3_pwm : out std_logic
       ;gate_power4_pwm : out std_logic
       ;gate_power5_pwm : out std_logic
       ;gate_power6_pwm : out std_logic

       ;grid_inu_sdm_clock   : out std_logic
       ;output_inu_sdm_clock : out std_logic
       ;dab_sdm_clock        : out std_logic

       ;ad_mux1_io           : out std_logic_vector(2 downto 0)
       ;ads_7056_clock       : out std_logic
       ;ads_7056_chip_select : out std_logic
       ;ads_7056_input_data  : in  std_logic

       ;ad_mux2_io               : out std_logic_vector(2 downto 0)
       ;ads_7056_clock_pri       : out std_logic
       ;ads_7056_chip_select_pri : out std_logic
       ;ads_7056_input_data_pri  : in  std_logic

       ;grid_inu_sdm_data   : in std_logic
       ;output_inu_sdm_data : in std_logic
       ;dab_sdm_data        : in std_logic
    );
end entity titanium_top;

architecture rtl of titanium_top is
begin

    u_core : entity work.hfloat_core
    generic map (
        g_clock_divider  => 25          -- 120 MHz / 25 = 4.8 MBaud
        ,g_has_native_fp => false
    )
    port map (
        clock   => main_clock
        ,reset  => not pll_locked
        ,uart_rx => uart_rx
        ,uart_tx => uart_tx
    );

    -- park every power-stage / measurement output
    grid_inu_leg1_hi <= '0'; grid_inu_leg1_low <= '0';
    grid_inu_leg2_hi <= '0'; grid_inu_leg2_low <= '0';
    dab_primary_hi   <= '0'; dab_primary_low   <= '0';
    dab_secondary_hi <= '0'; dab_secondary_low <= '0';
    output_inu_leg1_hi <= '0'; output_inu_leg1_low <= '0';
    output_inu_leg2_hi <= '0'; output_inu_leg2_low <= '0';
    primary_bypass_relay <= '0'; secondary_bypass_relay <= '0';
    gate_power1_pwm <= '0'; gate_power2_pwm <= '0'; gate_power3_pwm <= '0';
    gate_power4_pwm <= '0'; gate_power5_pwm <= '0'; gate_power6_pwm <= '0';
    grid_inu_sdm_clock <= '0'; output_inu_sdm_clock <= '0'; dab_sdm_clock <= '0';
    ad_mux1_io <= "000"; ads_7056_clock <= '0'; ads_7056_chip_select <= '1';
    ad_mux2_io <= "000"; ads_7056_clock_pri <= '0'; ads_7056_chip_select_pri <= '1';

end architecture rtl;
