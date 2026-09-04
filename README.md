# hfloat_test

A minimal, dual-target UART test harness for
[`hVHDL_floating_point`](https://github.com/hVHDL/hVHDL_floating_point).

It brings up a `fpga_communication` UART register block and wires a few
`hVHDL_floating_point` blocks to it so their behaviour can be checked on
real silicon over a serial link:

* **`multiply_add(hfloat)`** — the pure-logic fused multiply-add `a*b + c`
  (8 clock-edge pipeline)
* **`multiply_add(fast_hfloat)`** — the shorter-pipeline soft FMA (4 clock
  edges), built in parallel with the reference architecture off the same
  operands
* **`multiply_add(agilex)` / `native_fp32`** — the Altera hard float DSP
  (Agilex build only, 3 clock edges), for a side-by-side comparison
* **`float_to_fixed`** — the denormaliser `trunc(x · 2^radix)` converter

Two builds share one `top_test_hfloat`:

 | target      | board                                      | toolchain         | clock                    | UART                       |
 | --------    | -------                                    | -----------       | -------                  | ------                     |
 | `agilex/`   | Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`) | Quartus Prime Pro | 25 MHz → IOPLL → 120 MHz | 120e6 / 25 = **4.8 MBaud** |
 | `titanium/` | Efinix Ti60F225 custom board               | Efinity 2026.1    | 50 MHz → PLL → 120 MHz   | 120e6 / 25 = **4.8 MBaud** |

Both run the core at 120 MHz and the link at 4.8 MBaud (12 MHz / 2.5), a
rate the host FT4232H generates exactly, so there is no baud skew.

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
quartus_sh -t build_agilex.tcl compile
quartus_pgm -c 1 -m jtag -o "p;output_files/hfloat_test.sof"
```

`build_agilex.tcl` is a Tcl *project* script - run it with `-t`, not
`quartus_sh --flow compile build_agilex.tcl` (that fails with error 16368
looking for an entity named `build_agilex`; the project it builds is
`hfloat_test`). The `compile` argument generates the IP and runs the full
flow; without it the script just writes the project and you drive the
steps yourself:

```
quartus_sh   -t build_agilex.tcl
qsys-generate ip/pll_100/pll_100.ip         --synthesis=VHDL --part=A3CY100BM16AE7S
qsys-generate ip/native_fp32/native_fp32.ip --synthesis=VHDL --part=A3CY100BM16AE7S
quartus_sh --flow compile hfloat_test
```

### Titanium (from `titanium/`)

```
build_titanium.bat        rem synth + place + route + bitstream (Efinity 2026.1)
program_titanium.bat      rem JTAG load
```

## Talk to it

```
python test_hfloat.py COM6 4.8e6    # Agilex / AXC3000
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

## Measured performance

Pipeline latency is read straight off the on-chip probes (registers
20/21, 23/27, 25/26), in core-clock edges from operand-registered to
result-registered:

| block | latency | notes |
|-------|--------:|-------|
| `multiply_add(hfloat)` | 8 | sign-magnitude adder + one barrel shifter |
| `multiply_add(fast_hfloat)` | 4 | one-hot align multiply, fused magnitude/normalise |
| `native_fp32` (Agilex) | 3 | hard-float DSP |

Both boards close timing at a 120 MHz core clock:

| target | Fmax | worst-case setup slack @ 120 MHz |
|--------|-----:|---------------------------------:|
| Agilex 3 (Quartus Pro 26.1.1, `-slow_0c`) | ~141 MHz | +1.26 ns |
| Titanium Ti60F225 (Efinity 2026.1, C4) | ~180 MHz | +2.78 ns |

The `fast_hfloat` datapath carries no register power-up values so the
Agilex Hyper-Retimer can move them; `multiply_add(fast_hfloat)` bit-matches
`multiply_add(hfloat)` on every register test on both boards.

## Notes

* Critical Warning 20759 (missing Reset Release IP) on the Agilex build is
  expected for a bring-up image.
* The Titanium build reuses the `ac_in_ac_out_lab_power_supply`
  `titanium_build` interface (peri.xml / sdc) unchanged; the unused
  power-stage pins are held at `'0'`.
