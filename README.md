# hfloat_test

A minimal, dual-target UART test harness for
[`hVHDL_floating_point`](https://github.com/hVHDL/hVHDL_floating_point).

It brings up a `fpga_communication` UART register block and wires a few
`hVHDL_floating_point` blocks to it so their behaviour can be checked on
real silicon over a serial link:

* **`multiply_add(hfloat)`** — the pure-logic fused multiply-add `a*b + c`
* **`multiply_add(fast_hfloat)`** — the shorter-pipeline soft FMA, built in
  parallel with the reference architecture off the same operands
* **`multiply_add(agilex)` / `native_fp32`** — the Altera hard float DSP
  (Agilex build only), for a side-by-side comparison
* **`float_to_fixed`** — the denormaliser `trunc(x · 2^radix)` converter

Two builds share one `top_test_hfloat`:

 | target      | board                                      | toolchain         | clock                    | UART                       |
 | --------    | -------                                    | -----------       | -------                  | ------                     |
 | `agilex/`   | Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`) | Quartus Prime Pro | 25 MHz → IOPLL → 100 MHz | 100e6 / 25 = **4.0 MBaud** |
 | `titanium/` | Efinix Ti60F225 custom board               | Efinity 2026.1    | 50 MHz → PLL → 120 MHz   | 120e6 / 25 = **4.8 MBaud** |

Both dividers land on rates the host FT4232H generates exactly
(12 MHz / 3 and 12 MHz / 2.5), so the link runs without baud skew.

## Sources

`source/` — three submodules, three vendored glue files:

| path | origin |
|------|--------|
| `source/hVHDL_uart` | `hVHDL/hVHDL_uart` |
| `source/hVHDL_fpga_interconnect` | `hVHDL/hVHDL_fpga_interconnect` |
| `source/hVHDL_floating_point` | `hVHDL/hVHDL_floating_point` |
| `source/fpga_communication/*.vhd` | vendored from `johonkanen/fpga_communication` |

First checkout: `git submodule update --init`.

## Build & program

### Agilex (from `agilex/`)

```
quartus_sh   -t build_agilex.tcl
qsys-generate ip/pll_100/pll_100.ip         --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate ip/native_fp32/native_fp32.ip --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_syn hfloat_test
quartus_fit hfloat_test
quartus_sta hfloat_test
quartus_asm hfloat_test
quartus_pgm -c 1 -m jtag -o "p;output_files/hfloat_test.sof"
```

### Titanium (from `titanium/`)

```
build_titanium.bat        rem synth + place + route + bitstream (Efinity 2026.1)
program_titanium.bat      rem JTAG load
```

## Talk to it

```
python test_hfloat.py COM6 4e6      # Agilex / AXC3000
python test_hfloat.py COM8 4.8e6    # Titanium
```

`test_hfloat.py` is self-contained (needs only `pip install pyserial`).

## Register map

| addr | meaning |
|-----:|---------|
| 1 | id constant `0x0000FACE` (RO) |
| 2 | git hash (RO) |
| 3 | loopback register (R/W) |
| 4 | read-strobe counter (RO, ++ per read) |
| 16 / 17 / 18 | FMA operands a / b / c — IEEE-754 binary32 (R/W) |
| 19 | FMA result `a*b + c` — `multiply_add(hfloat)` (RO) |
| 20 | soft FMA pipeline latency, clock edges (RO) |
| 21 | write → run the soft FMA latency probe (WO) |
| 22 | FMA result `a*b + c` — `multiply_add(fast_hfloat)` (RO) |
| 23 | fast FMA pipeline latency, clock edges (RO) |
| 27 | write → run the fast FMA latency probe (WO) |
| 24 | FMA result `a*b + c` — `native_fp32` (RO; `0` on Titanium) |
| 25 | native FMA pipeline latency (RO; `0` on Titanium) |
| 26 | write → run the native FMA latency probe (WO) |
| 32 | float→fixed input — IEEE-754 binary32 (R/W) |
| 33 | float→fixed radix (R/W, default 10) |
| 34 | float→fixed result = `trunc(x · 2^radix)` (RO, signed) |

FMA operands / results and the addr 32 input are raw binary32 bit
patterns (`struct.pack('!f', x)`).

`multiply_add(hfloat)` and `multiply_add(fast_hfloat)` work in the hVHDL
native hfloat serialisation, not IEEE fp32, so `fp32_hfloat_pkg` converts
at the register boundary. Both soft architectures are instantiated
together and driven from the same operand registers.

## Notes

* Critical Warning 20759 (missing Reset Release IP) on the Agilex build is
  expected for a bring-up image.
* The Titanium build reuses the `ac_in_ac_out_lab_power_supply`
  `titanium_build` interface (peri.xml / sdc) unchanged; the unused
  power-stage pins are held at `'0'`.
