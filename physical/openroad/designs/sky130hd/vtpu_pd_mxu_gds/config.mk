export DESIGN_NICKNAME = vtpu_pd_mxu_gds
export DESIGN_NAME = vtpu_pd_mxu_gds_top
export PLATFORM = sky130hd
export VTPU_REPO_ROOT = $(abspath $(dir $(DESIGN_CONFIG))/../../../../..)

export VERILOG_FILES = \
  $(VTPU_REPO_ROOT)/rtl/common/vtpu_pkg.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/pe_int8.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/fp32_mul.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/fp32_add.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/fp32_recip.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/fp32_rsqrt.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/fp32_exp.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/pe_bf16.sv \
  $(VTPU_REPO_ROOT)/rtl/mxu/systolic_array.sv \
  $(VTPU_REPO_ROOT)/rtl/mxu/systolic_array_bf16.sv \
  $(VTPU_REPO_ROOT)/rtl/mxu/mxu_top.sv \
  $(VTPU_REPO_ROOT)/rtl/physical/vtpu_pd_mxu_gds_top.sv

export SDC_FILE = $(VTPU_REPO_ROOT)/physical/openroad/designs/sky130hd/vtpu_pd_mxu_gds/constraint.sdc
export VERILOG_INCLUDE_DIRS = $(VTPU_REPO_ROOT)/rtl/common

export SYNTH_HDL_FRONTEND = slang
export SYNTH_SLANG_ARGS = --std 1800-2017
export SYNTH_READ_BLACKBOX_LIB = 1
export SYNTH_NO_FLAT = 0
export SYNTH_OPT_SELECTION = 1

export PLACE_DENSITY = 0.20
export DIE_AREA = 0 0 500 500
export CORE_AREA = 40 40 460 460

export PLACE_PINS_ARGS = -hor_layers met3 -ver_layers met2
export MIN_ROUTING_LAYER = met1
export MAX_ROUTING_LAYER = met5

export TNS_END_PERCENT = 0
export SKIP_CTS_REPAIR_TIMING = 1
export SKIP_INCREMENTAL_REPAIR = 1
export SKIP_LAST_GASP = 1
export SETUP_SLACK_MARGIN = -100
export HOLD_SLACK_MARGIN = -100

export MAX_REPAIR_ANTENNAS_ITER_GRT = 2
export MAX_REPAIR_ANTENNAS_ITER_DRT = 1

export KLAYOUT_TECH_FILE = /OpenROAD-flow-scripts/flow/platforms/sky130hd/sky130hd.lyt
export KLAYOUT_PROPERTIES = /OpenROAD-flow-scripts/flow/platforms/sky130hd/sky130hd.lyp
export KLAYOUT_DRC_FILE = /OpenROAD-flow-scripts/flow/platforms/sky130hd/sky130hd_mr.drc
