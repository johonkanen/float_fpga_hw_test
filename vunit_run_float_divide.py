#!/usr/bin/env python3

from pathlib import Path
from vunit import VUnit

ROOT = Path(__file__).resolve().parent
FP = ROOT / "source/hVHDL_floating_point/vhdl2008"
FX = ROOT / "source/hVHDL_fixed_point"

VU = VUnit.from_argv()

# float_divide.vhd lives at the repo root, not in either submodule: it
# needs hfloat_record (hVHDL_floating_point) and lut_reciprocal_pkg
# (hVHDL_fixed_point) at once, and this repo is the only place both are
# compiled into the same work library.
work = VU.add_library("generic_lib")
work.add_source_files(FP / "float_typedefs_generic_pkg.vhd")
work.add_source_files(FP / "normalizer_generic_pkg.vhd")
work.add_source_files(FP / "float_to_real_conversions_pkg.vhd")
work.add_source_files(FX / "lut_interpolation/lut_reciprocal_pkg.vhd")
work.add_source_files(ROOT / "fp32_hfloat_pkg.vhd")
work.add_source_files(ROOT / "float_divide.vhd")
work.add_source_files(ROOT / "testbenches/float_divide_tb.vhd")

VU.main()
