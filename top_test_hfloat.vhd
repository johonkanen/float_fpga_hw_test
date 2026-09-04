------------------------------------------------------------------------
-- top_test_hfloat - target-agnostic UART test harness for hVHDL_floating_point.
--
-- Exposes, over the fpga_communication UART register interface
-- (32-bit data, 16-bit address):
--
--   1  : id constant 0x0000FACE                          RO
--   2  : git hash                                        RO
--   3  : loopback register                               RW
--   4  : read-strobe counter (++ on every read)          RO
--
--   16 : FMA operand a  (IEEE-754 binary32)              RW
--   17 : FMA operand b                                   RW
--   18 : FMA operand c                                   RW
--   19 : FMA result a*b + c  - multiply_add(hfloat)      RO
--   20 : soft FMA pipeline latency, clock edges          RO
--   21 : write -> run the soft FMA latency probe         WO
--   22 : FMA result a*b + c  - multiply_add(fast_hfloat) RO
--   23 : fast FMA pipeline latency, clock edges          RO
--   27 : write -> run the fast FMA latency probe         WO
--   24 : FMA result a*b + c  - Agilex native_fp32        RO   (0 on Titanium)
--   25 : native FMA pipeline latency, clock edges        RO   (0 on Titanium)
--   26 : write -> run the native FMA latency probe       WO
--
--   32 : float->fixed input  (IEEE-754 binary32)         RW
--   33 : float->fixed radix   (default 10)               RW
--   34 : float->fixed result  = trunc(x * 2**radix)      RO   (signed)
--
-- g_has_native_fp enables the multiply_add(agilex) / native_fp32 path;
-- leave it false on devices without the hard float DSP (e.g. Titanium).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity top_test_hfloat is
    generic (
        g_clock_divider : natural := 25;      -- clock (Hz) / baud; 120e6/25 = 4.8 MBaud
        g_has_native_fp : boolean := false
    );
    port (
        clock   : in  std_logic;
        reset   : in  std_logic;              -- active high, synchronous
        uart_rx : in  std_logic;
        uart_tx : out std_logic
    );
end entity top_test_hfloat;

architecture rtl of top_test_hfloat is

    use work.fpga_interconnect_pkg.all;
    use work.multiply_add_pkg.all;
    use work.float_typedefs_generic_pkg.all;
    use work.fp32_hfloat_pkg.all;
    use work.float_to_fixed_pkg.all;

    -- power-on reset stretch so the UART starts from a known state
    signal por_counter  : natural range 0 to 1_048_575 := 1_048_575;
    signal reset_meta   : std_logic := '1';
    signal reset_sync   : std_logic := '1';
    signal system_reset : std_logic := '1';

    signal bus_to_communications   : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_communications : fpga_interconnect_record := init_fpga_interconnect;
    signal bus_from_top            : fpga_interconnect_record := init_fpga_interconnect;

    signal loopback_register : std_logic_vector(31 downto 0) := (others => '0');
    signal read_counter      : std_logic_vector(31 downto 0) := (others => '0');

    -- FMA operands (raw IEEE-754 binary32 bit patterns from the UART)
    signal fp_a : std_logic_vector(31 downto 0) := (others => '0');
    signal fp_b : std_logic_vector(31 downto 0) := (others => '0');
    signal fp_c : std_logic_vector(31 downto 0) := (others => '0');

    -- soft path: hVHDL multiply_add(hfloat), hfloat-serialised operands
    -- (1 + 8 + 24 bits); a fp32 -> hfloat glue sits at the boundary
    constant soft_ref : mpya_subtype_record := create_mpya_typeref(hfloat_fp32_zero);
    signal soft_in    : soft_ref.mpya_in'subtype  := soft_ref.mpya_in;
    signal soft_out   : soft_ref.mpya_out'subtype := soft_ref.mpya_out;
    signal soft_result : std_logic_vector(31 downto 0) := (others => '0');
    signal soft_a_fp32, soft_b_fp32, soft_c_fp32 : std_logic_vector(31 downto 0) := (others => '0');

    -- fast path: hVHDL multiply_add(fast_hfloat), same hfloat serialisation,
    -- runs in parallel with the reference architecture off the same operands
    signal fast_in    : soft_ref.mpya_in'subtype  := soft_ref.mpya_in;
    signal fast_out   : soft_ref.mpya_out'subtype := soft_ref.mpya_out;
    signal fast_result : std_logic_vector(31 downto 0) := (others => '0');
    signal fast_a_fp32, fast_b_fp32, fast_c_fp32 : std_logic_vector(31 downto 0) := (others => '0');

    -- registered hfloat operands / result: the fp32<->hfloat conversion glue
    -- sits between these registers and the raw fp32 / fp32 output, so the fast
    -- latency probe brackets exactly the native hfloat core (it subtracts the
    -- two boundary registers below).
    -- no power-up values: keeps the Agilex Hyper-Retimer free to move these
    -- across the fp32<->hfloat conversion logic
    signal fast_hf_a   : soft_ref.mpya_in.mpy_a'subtype;
    signal fast_hf_b   : soft_ref.mpya_in.mpy_b'subtype;
    signal fast_hf_c   : soft_ref.mpya_in.add_a'subtype;
    signal fast_hf_res : soft_ref.mpya_out.result'subtype;
    constant c_fast_boundary_regs : natural := 2;

    -- native path: multiply_add(agilex) / native_fp32, plain fp32
    constant nat_ref  : mpya_subtype_record := create_mpya_typeref;
    signal native_in  : nat_ref.mpya_in'subtype  := nat_ref.mpya_in;
    signal native_out : nat_ref.mpya_out'subtype := nat_ref.mpya_out;
    signal native_result : std_logic_vector(31 downto 0) := (others => '0');

    -- one latency probe, retargetable: drives (1.0, 8.0, 0.0) -> 8.0, then
    -- steps a to 8.0 and counts clock edges until the selected result
    -- reads 64.0
    constant c_fma_a0 : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    constant c_fma_a1 : std_logic_vector(31 downto 0) := x"41000000";  -- 8.0
    constant c_fma_b  : std_logic_vector(31 downto 0) := x"41000000";  -- 8.0
    constant c_fma_c  : std_logic_vector(31 downto 0) := x"00000000";  -- 0.0
    constant c_fma_r1 : std_logic_vector(31 downto 0) := x"42800000";  -- 64.0

    type probe_state_t is (P_IDLE, P_SETTLE, P_MEASURE, P_DONE);
    signal probe_state   : probe_state_t := P_IDLE;
    signal probe_active  : std_logic := '0';
    signal probe_native  : std_logic := '0';   -- 1 = measure native path
    signal probe_fast    : std_logic := '0';   -- 1 = measure fast_hfloat path
    signal probe_a       : std_logic_vector(31 downto 0) := c_fma_a0;
    signal probe_wait    : natural range 0 to 255 := 0;
    signal probe_count   : natural range 0 to 255 := 0;
    signal soft_latency  : std_logic_vector(31 downto 0) := (others => '0');
    signal fast_latency  : std_logic_vector(31 downto 0) := (others => '0');
    signal nat_latency   : std_logic_vector(31 downto 0) := (others => '0');
    signal probe_trig_s  : std_logic := '0';   -- toggles on write to 21
    signal probe_seen_s  : std_logic := '0';
    signal probe_trig_f  : std_logic := '0';   -- toggles on write to 27
    signal probe_seen_f  : std_logic := '0';
    signal probe_trig_n  : std_logic := '0';   -- toggles on write to 26
    signal probe_seen_n  : std_logic := '0';

    -- float -> fixed
    constant c_conv_stages : natural := 2;
    constant c_conv_radix  : natural := 10;

    constant f2f_ref : float_to_fixed_typeref := create_float_to_fixed_typeref(hfloat32);
    signal   f2f_in  : f2f_ref.f2f_in'subtype  := f2f_ref.f2f_in;
    signal   f2f_out : f2f_ref.f2f_out'subtype := f2f_ref.f2f_out;

    signal fp_conv_in     : std_logic_vector(31 downto 0) := (others => '0');
    signal conv_radix     : std_logic_vector(31 downto 0)
                          := std_logic_vector(to_unsigned(c_conv_radix, 32));
    signal fixed_conv_out : std_logic_vector(31 downto 0) := (others => '0');

begin

------------------------------------------------------------------------
    reset_synchroniser : process (clock) is
    begin
        if rising_edge(clock) then
            reset_meta <= reset;
            reset_sync <= reset_meta;
            if por_counter /= 0 then
                por_counter  <= por_counter - 1;
                system_reset <= '1';
            else
                system_reset <= reset_sync;
            end if;
        end if;
    end process reset_synchroniser;

------------------------------------------------------------------------
    test_registers : process (clock) is
    begin
        if rising_edge(clock) then
            init_bus(bus_from_top);

            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 1, x"0000FACE");
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 2, work.git_hash_pkg.git_hash);
            connect_data_to_address(bus_from_communications, bus_from_top, 3, loopback_register);

            if data_is_requested_from_address(bus_from_communications, 4) then
                read_counter <= std_logic_vector(unsigned(read_counter) + 1);
                write_data_to_address(bus_from_top, 0, read_counter);
            end if;

            -- FMA
            connect_data_to_address(bus_from_communications, bus_from_top, 16, fp_a);
            connect_data_to_address(bus_from_communications, bus_from_top, 17, fp_b);
            connect_data_to_address(bus_from_communications, bus_from_top, 18, fp_c);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 19, soft_result);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 20, soft_latency);
            if write_is_requested_to_address(bus_from_communications, 21) then
                probe_trig_s <= not probe_trig_s;
            end if;
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 22, fast_result);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 23, fast_latency);
            if write_is_requested_to_address(bus_from_communications, 27) then
                probe_trig_f <= not probe_trig_f;
            end if;
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 24, native_result);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 25, nat_latency);
            if write_is_requested_to_address(bus_from_communications, 26) then
                probe_trig_n <= not probe_trig_n;
            end if;

            -- float -> fixed
            connect_data_to_address(bus_from_communications, bus_from_top, 32, fp_conv_in);
            connect_data_to_address(bus_from_communications, bus_from_top, 33, conv_radix);
            connect_read_only_data_to_address(bus_from_communications, bus_from_top, 34, fixed_conv_out);

            bus_to_communications <= bus_from_top;

            if system_reset = '1' then
                loopback_register     <= (others => '0');
                read_counter          <= (others => '0');
                fp_a                  <= (others => '0');
                fp_b                  <= (others => '0');
                fp_c                  <= (others => '0');
                fp_conv_in            <= (others => '0');
                conv_radix            <= std_logic_vector(to_unsigned(c_conv_radix, 32));
                bus_to_communications <= init_fpga_interconnect;
            end if;
        end if;
    end process test_registers;

------------------------------------------------------------------------
    u_fpga_communications : entity work.fpga_communications
    generic map (
        fpga_interconnect_pkg => work.fpga_interconnect_pkg
        ,g_clock_divider      => g_clock_divider
    )
    port map (
        clock                    => clock
        ,uart_rx                 => uart_rx
        ,uart_tx                 => uart_tx
        ,bus_to_communications   => bus_to_communications
        ,bus_from_communications => bus_from_communications
    );

------------------------------------------------------------------------
    -- soft FMA - hVHDL multiply_add(hfloat).  Operands are converted from
    -- fp32 to the native hfloat serialisation on the way in, and the
    -- result back to fp32 on the way out.  The latency probe overrides
    -- operand a while it runs.
    soft_a_fp32 <= probe_a when probe_active = '1' and probe_native = '0' and probe_fast = '0' else fp_a;
    soft_b_fp32 <= c_fma_b when probe_active = '1' and probe_native = '0' and probe_fast = '0' else fp_b;
    soft_c_fp32 <= c_fma_c when probe_active = '1' and probe_native = '0' and probe_fast = '0' else fp_c;

    soft_in.mpy_a        <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(soft_a_fp32));
    soft_in.mpy_b        <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(soft_b_fp32));
    soft_in.add_a        <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(soft_c_fp32));
    soft_in.is_requested <= '1';

    u_soft_fma : entity work.multiply_add(hfloat)
    generic map (g_floatref => hfloat_fp32_zero)
    port map (clock => clock, mpya_in => soft_in, mpya_out => soft_out);

    soft_result <= hfloat_to_fp32(to_hfloat(get_mpya_result(soft_out), hfloat_fp32_zero));

------------------------------------------------------------------------
    -- fast FMA - hVHDL multiply_add(fast_hfloat), same fp32 <-> hfloat glue
    -- as the reference path, wired up in parallel.  Its own latency probe
    -- overrides operand a while it runs.
    fast_a_fp32 <= probe_a when probe_active = '1' and probe_fast = '1' else fp_a;
    fast_b_fp32 <= c_fma_b when probe_active = '1' and probe_fast = '1' else fp_b;
    fast_c_fp32 <= c_fma_c when probe_active = '1' and probe_fast = '1' else fp_c;

    -- boundary registers: fp32 -> hfloat on the way in, hfloat -> fp32 on the
    -- way out, both isolated between flops so the conversion glue is off the
    -- FMA critical path and the probe measures the hfloat core alone
    fast_hfloat_boundary : process (clock) is
    begin
        if rising_edge(clock) then
            fast_hf_a   <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(fast_a_fp32));
            fast_hf_b   <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(fast_b_fp32));
            fast_hf_c   <= to_std_logic(work.fp32_hfloat_pkg.fp32_to_hfloat(fast_c_fp32));
            fast_hf_res <= get_mpya_result(fast_out);
        end if;
    end process fast_hfloat_boundary;

    fast_in.mpy_a        <= fast_hf_a;
    fast_in.mpy_b        <= fast_hf_b;
    fast_in.add_a        <= fast_hf_c;
    fast_in.is_requested <= '1';

    u_fast_fma : entity work.multiply_add(fast_hfloat)
    generic map (g_floatref => hfloat_fp32_zero)
    port map (clock => clock, mpya_in => fast_in, mpya_out => fast_out);

    fast_result <= hfloat_to_fp32(to_hfloat(fast_hf_res, hfloat_fp32_zero));

    gen_native : if g_has_native_fp generate
        native_in.mpy_a        <= probe_a when probe_active = '1' and probe_native = '1' else fp_a;
        native_in.mpy_b        <= c_fma_b when probe_active = '1' and probe_native = '1' else fp_b;
        native_in.add_a        <= c_fma_c when probe_active = '1' and probe_native = '1' else fp_c;
        native_in.is_requested <= '1';

        u_native_fma : entity work.multiply_add(agilex)
        port map (clock => clock, mpya_in => native_in, mpya_out => native_out);

        native_result <= get_mpya_result(native_out);
    end generate gen_native;

------------------------------------------------------------------------
    fma_latency_probe : process (clock) is
        variable measured : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clock) then
            case probe_state is
                when P_IDLE =>
                    probe_active <= '0';
                    if probe_trig_s /= probe_seen_s then
                        probe_seen_s <= probe_trig_s;
                        probe_native <= '0';
                        probe_fast   <= '0';
                        probe_a      <= c_fma_a0;
                        probe_active <= '1';
                        probe_wait   <= 255;
                        probe_state  <= P_SETTLE;
                    elsif probe_trig_f /= probe_seen_f then
                        probe_seen_f <= probe_trig_f;
                        probe_native <= '0';
                        probe_fast   <= '1';
                        probe_a      <= c_fma_a0;
                        probe_active <= '1';
                        probe_wait   <= 255;
                        probe_state  <= P_SETTLE;
                    elsif probe_trig_n /= probe_seen_n then
                        probe_seen_n <= probe_trig_n;
                        probe_native <= '1';
                        probe_fast   <= '0';
                        probe_a      <= c_fma_a0;
                        probe_active <= '1';
                        probe_wait   <= 255;
                        probe_state  <= P_SETTLE;
                    end if;

                when P_SETTLE =>
                    if probe_wait = 0 then
                        probe_a     <= c_fma_a1;
                        probe_count <= 0;
                        probe_state <= P_MEASURE;
                    else
                        probe_wait <= probe_wait - 1;
                    end if;

                when P_MEASURE =>
                    if probe_native = '1' then
                        measured := native_result;
                    elsif probe_fast = '1' then
                        measured := fast_result;
                    else
                        measured := soft_result;
                    end if;
                    if measured = c_fma_r1 then
                        if probe_native = '1' then
                            nat_latency <= std_logic_vector(to_unsigned(probe_count, 32));
                        elsif probe_fast = '1' then
                            -- subtract the fp32<->hfloat boundary registers so the
                            -- reading is the native hfloat core latency alone
                            fast_latency <= std_logic_vector(to_unsigned(probe_count - c_fast_boundary_regs, 32));
                        else
                            soft_latency <= std_logic_vector(to_unsigned(probe_count, 32));
                        end if;
                        probe_state <= P_DONE;
                    elsif probe_count = 255 then
                        if probe_native = '1' then
                            nat_latency <= x"FFFFFFFF";
                        elsif probe_fast = '1' then
                            fast_latency <= x"FFFFFFFF";
                        else
                            soft_latency <= x"FFFFFFFF";
                        end if;
                        probe_state <= P_DONE;
                    else
                        probe_count <= probe_count + 1;
                    end if;

                when P_DONE =>
                    probe_active <= '0';
                    probe_state  <= P_IDLE;
            end case;

            if system_reset = '1' then
                probe_state  <= P_IDLE;
                probe_active <= '0';
                probe_seen_s <= probe_trig_s;
                probe_seen_f <= probe_trig_f;
                probe_seen_n <= probe_trig_n;
            end if;
        end if;
    end process fma_latency_probe;

------------------------------------------------------------------------
    u_float_to_fixed : entity work.float_to_fixed
        generic map (g_stages => c_conv_stages)
        port map (
            clock              => clock,
            float_to_fixed_in  => f2f_in,
            float_to_fixed_out => f2f_out
        );

    float_to_fixed : process (clock) is
    begin
        if rising_edge(clock) then
            request_float_to_fixed(f2f_in,
                work.float_to_fixed_pkg.fp32_to_hfloat(fp_conv_in),
                to_integer(unsigned(conv_radix(5 downto 0))));
            fixed_conv_out <= std_logic_vector(get_fixed_result(f2f_out));
            if system_reset = '1' then
                fixed_conv_out <= (others => '0');
            end if;
        end if;
    end process float_to_fixed;

end architecture rtl;
