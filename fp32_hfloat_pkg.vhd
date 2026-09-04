------------------------------------------------------------------------
-- fp32_hfloat_pkg - IEEE-754 binary32 <-> hVHDL hfloat_record glue.
--
-- multiply_add(hfloat) works in the hVHDL native hfloat form (24-bit
-- mantissa with the implicit leading 1, exponent biased by 126) and
-- serialises with to_std_logic / to_hfloat, NOT as IEEE fp32.  The UART
-- test wants to feed and read plain fp32 bit patterns, so these two
-- functions convert at the boundary.  Hand-rolled bit manipulation - no
-- ieee.float_pkg (keeps it synthesis-friendly on Quartus and Efinity).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    use work.float_typedefs_generic_pkg.all;

package fp32_hfloat_pkg is

    -- hVHDL hfloat sized for IEEE binary32: 8-bit exponent, 24-bit
    -- mantissa (23 stored fraction bits + the implicit leading 1)
    subtype hfloat_fp32 is hfloat_record(exponent(7 downto 0), mantissa(23 downto 0));

    constant hfloat_fp32_zero : hfloat_fp32 :=
        (sign => '0', exponent => (others => '0'), mantissa => (others => '0'));

    function fp32_to_hfloat (slv : std_logic_vector(31 downto 0)) return hfloat_fp32;
    function hfloat_to_fp32 (h   : hfloat_record)                 return std_logic_vector;

end package fp32_hfloat_pkg;

package body fp32_hfloat_pkg is

    function fp32_to_hfloat (slv : std_logic_vector(31 downto 0)) return hfloat_fp32 is
        variable be : natural := to_integer(unsigned(slv(30 downto 23)));
        variable h  : hfloat_fp32;
    begin
        h.sign := slv(31);
        if be = 0 or be > 250 then          -- zero / subnormal / inf / nan -> 0
            h.exponent := (others => '0');
            h.mantissa := (others => '0');
        else
            h.exponent := to_signed(be - 126, 8);
            h.mantissa := unsigned('1' & slv(22 downto 0));   -- implicit 1 + 23 frac
        end if;
        return h;
    end function;

    function hfloat_to_fp32 (h : hfloat_record) return std_logic_vector is
        variable r : std_logic_vector(31 downto 0) := (others => '0');
        variable e : signed(9 downto 0) := resize(h.exponent, 10) + 126;
        variable m : unsigned(h.mantissa'length - 1 downto 0) := shift_left(h.mantissa, 1);
    begin
        r(31)           := h.sign;
        r(30 downto 23) := std_logic_vector(e(7 downto 0));
        r(22 downto 0)  := std_logic_vector(m(m'high downto m'high - 22));
        if h.mantissa = 0 then               -- exact zero
            r(30 downto 0) := (others => '0');
        end if;
        return r;
    end function;

end package body fp32_hfloat_pkg;
