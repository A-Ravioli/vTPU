export DESIGN_NICKNAME = vtpu_pd_tiny
export DESIGN_NAME = vtpu_pd_tiny_top
export PLATFORM = sky130hd
export VTPU_REPO_ROOT = $(abspath $(dir $(DESIGN_CONFIG))/../../../../..)

export VERILOG_FILES = \
  $(VTPU_REPO_ROOT)/rtl/common/vtpu_pkg.sv \
  $(VTPU_REPO_ROOT)/rtl/common/perf_counters.sv \
  $(VTPU_REPO_ROOT)/rtl/primitive/pe_int8.sv \
  $(VTPU_REPO_ROOT)/rtl/memory/vmem_bank.sv \
  $(VTPU_REPO_ROOT)/rtl/mxu/systolic_array.sv \
  $(VTPU_REPO_ROOT)/rtl/mxu/mxu_top.sv \
  $(VTPU_REPO_ROOT)/rtl/vector/vector_unit.sv \
  $(VTPU_REPO_ROOT)/rtl/vector/reduce_unit.sv \
  $(VTPU_REPO_ROOT)/rtl/tensor_core/tensor_core.sv \
  $(VTPU_REPO_ROOT)/rtl/isa/instr_decoder.sv \
  $(VTPU_REPO_ROOT)/rtl/isa/instr_mem.sv \
  $(VTPU_REPO_ROOT)/rtl/isa/control_fsm.sv \
  $(VTPU_REPO_ROOT)/rtl/memory/hbm_model.sv \
  $(VTPU_REPO_ROOT)/rtl/memory/cmem_top.sv \
  $(VTPU_REPO_ROOT)/rtl/memory/dma_engine.sv \
  $(VTPU_REPO_ROOT)/rtl/memory/vmem_top.sv \
  $(VTPU_REPO_ROOT)/rtl/top/virtual_tpu_v4_top.sv \
  $(VTPU_REPO_ROOT)/rtl/physical/vtpu_pd_tiny_top.sv

export SDC_FILE = $(VTPU_REPO_ROOT)/physical/openroad/designs/sky130hd/vtpu_pd_tiny/constraint.sdc
export VERILOG_INCLUDE_DIRS = $(VTPU_REPO_ROOT)/rtl/common
export SYNTH_HDL_FRONTEND = slang
export SYNTH_SLANG_ARGS = --std 1800-2017

export PLACE_DENSITY = 0.35
export TNS_END_PERCENT = 100
export REMOVE_ABC_BUFFERS = 1

export DIE_AREA = 0 0 2200 2200
export CORE_AREA = 100 100 2100 2100

export ABC_AREA = 1
export SYNTH_HIERARCHICAL = 1
