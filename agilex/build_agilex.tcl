# ------------------------------------------------------------------------
# Quartus Prime Pro project script - hfloat_test, Agilex target.
# Board: Arrow AXC3000 (Agilex 3 A3CY100BM16AE7S)
#
# Exercises hVHDL_floating_point over UART: soft multiply_add(hfloat),
# the Agilex native_fp32 hard-float DSP, and the float_to_fixed converter.
#
# First checkout:  git submodule update --init
#
# Build everything in one step (run from this directory):
#     quartus_sh -t build_agilex.tcl compile
#
# This is a Tcl PROJECT script - it must be run with "-t", NOT
# "quartus_sh --flow compile build_agilex.tcl" (that treats "build_agilex"
# as a project/entity name and fails with error 16368).  The project it
# builds is called "hfloat_test".
#
# Or drive the steps yourself:
#     quartus_sh   -t build_agilex.tcl            ;# (re)write the project
#     qsys-generate ip/pll_120/pll_120.ip         --synthesis=VHDL --part=A3CY100BM16AE7S
#     qsys-generate ip/native_fp32/native_fp32.ip --synthesis=VHDL --part=A3CY100BM16AE7S
#     quartus_syn hfloat_test
#     quartus_fit hfloat_test
#     quartus_sta hfloat_test
#     quartus_asm hfloat_test
#
# Program (cable INDEX, not name):
#     quartus_pgm -c 1 -m jtag -o "p;output_files/hfloat_test.sof"
#
# Talk to it:  python ../test_hfloat.py COM<x> 4e6
# ------------------------------------------------------------------------

package require ::quartus::project

variable this_file_path [file dirname [file normalize [info script]]]
variable repo_root      [file dirname $this_file_path]

set need_to_close_project 0
if {[is_project_open]} {
    if {[string compare $quartus(project) "hfloat_test"]} { puts "Project hfloat_test is not open"; exit 1 }
} else {
    if {[project_exists hfloat_test]} {
        project_open -revision hfloat_test hfloat_test
    } else {
        project_new -revision hfloat_test hfloat_test
    }
    set need_to_close_project 1
}

# ---------------------------------------------------------------- device
set_global_assignment -name FAMILY "Agilex 3"
set_global_assignment -name DEVICE A3CY100BM16AE7S
set_global_assignment -name TOP_LEVEL_ENTITY hfloat_test_top
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 25.3.0
set_global_assignment -name LAST_QUARTUS_VERSION "25.3.0 Pro Edition"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100
set_global_assignment -name ERROR_CHECK_FREQUENCY_DIVISOR 256
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2019
set_global_assignment -name OPTIMIZATION_MODE BALANCED
set_global_assignment -name BOARD default
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_INIT_DONE SDM_IO0
set_global_assignment -name FLOW_ENABLE_HYPER_RETIMER_FAST_FORWARD ON
set_global_assignment -name FLOW_ENABLE_INTERACTIVE_TIMING_ANALYZER OFF

# ------------------------------------------------------------ source set
set_global_assignment -name VHDL_FILE $repo_root/source/hVHDL_fpga_interconnect/fpga_interconnect_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/source/fpga_communication/fpga_interconnect_16bit_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/source/hVHDL_uart/uart_rx/uart_rx_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/source/hVHDL_uart/uart_tx/uart_tx_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/source/fpga_communication/serial_protocol_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/source/fpga_communication/communications.vhd
set_global_assignment -name VHDL_FILE $repo_root/git_hash_pkg.vhd

# hVHDL_floating_point (generic / vhdl2008 flavour), canonical order
set FP $repo_root/source/hVHDL_floating_point/vhdl2008
set_global_assignment -name VHDL_FILE $FP/float_typedefs_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/normalizer_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/denormalizer_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/float_multiplier_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/float_adder_generic_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/float_to_real_conversions_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/multiply_add_entity.vhd
set_global_assignment -name VHDL_FILE $FP/multiply_add_arch_hfloat.vhd
set_global_assignment -name VHDL_FILE $FP/fast_hfloat_pkg.vhd
set_global_assignment -name VHDL_FILE $FP/multiply_add_arch_fast_hfloat.vhd
set_global_assignment -name VHDL_FILE $FP/altera/multiply_add_arch_agilex.vhd
set_global_assignment -name VHDL_FILE $FP/float_to_fixed.vhd

set_global_assignment -name VHDL_FILE $repo_root/fp32_hfloat_pkg.vhd
set_global_assignment -name VHDL_FILE $repo_root/top_test_hfloat.vhd
set_global_assignment -name VHDL_FILE $this_file_path/hfloat_test_agilex.vhd

# ------------------------------------------------------------------- IP
set_global_assignment -name IP_FILE $this_file_path/ip/pll_120/pll_120.ip
set_global_assignment -name IP_FILE $this_file_path/ip/native_fp32/native_fp32.ip

# ---------------------------------------------------------- constraints
set_global_assignment -name SDC_FILE $this_file_path/hfloat_test.sdc

# ------------------------------------------------------------------ pins
set_location_assignment PIN_A7   -to clk_clk
set_location_assignment PIN_A12  -to reset_reset_n
set_location_assignment PIN_AG23 -to uart_rxd
set_location_assignment PIN_AG24 -to uart_txd

set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to clk_clk       -entity hfloat_test_top
set_instance_assignment -name IO_STANDARD "1.3-V LVCMOS" -to reset_reset_n -entity hfloat_test_top
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_rxd      -entity hfloat_test_top
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to uart_txd      -entity hfloat_test_top
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON   -to reset_reset_n -entity hfloat_test_top
set_instance_assignment -name CURRENT_STRENGTH_NEW 6MA   -to uart_txd      -entity hfloat_test_top

export_assignments

# ---------------------------------------------------------------- compile
# "quartus_sh -t build_agilex.tcl compile" also generates the IP and runs
# the full compile flow.  Plain "-t build_agilex.tcl" just (re)writes the
# project so you can drive quartus_syn / fit / sta / asm yourself.
if {[lsearch -exact $quartus(args) "compile"] >= 0} {

    set qgen "qsys-generate"
    if {[auto_execok $qgen] eq ""} {
        set qgen [file normalize [file join $quartus(binpath) .. sopc_builder bin qsys-generate]]
    }

    foreach ip {pll_120 native_fp32} {
        set ip_file [file join $this_file_path ip $ip $ip.ip]
        puts "### qsys-generate $ip"
        # -ignorestderr: qsys-generate prints its licence banner to stderr,
        # which Tcl exec would otherwise raise as an error on a clean run
        if {[catch {exec -ignorestderr $qgen $ip_file \
                        --synthesis=VHDL --part=A3CY100BM16AE7S} msg]} {
            puts $msg
            puts "ERROR: qsys-generate $ip failed"
            exit 1
        }
    }

    package require ::quartus::flow
    if {[catch {execute_flow -compile} msg]} {
        puts "ERROR: compile flow failed: $msg"
        exit 1
    }
}

if {$need_to_close_project} { project_close }
