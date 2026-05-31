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
  $(VTPU_REPO_ROOT)/rtl/physical/physical_memories.sv \
  $(VTPU_REPO_ROOT)/rtl/physical/vtpu_pd_tiny_top.sv

export SDC_FILE = $(VTPU_REPO_ROOT)/physical/openroad/designs/sky130hd/vtpu_pd_tiny/constraint.sdc
export VERILOG_INCLUDE_DIRS = $(VTPU_REPO_ROOT)/rtl/common
export SYNTH_HDL_FRONTEND = slang
export SYNTH_SLANG_ARGS = --std 1800-2017 -DVTPU_PHYSICAL_SRAM_MACROS
export SYNTH_BLACKBOXES = sky130_sram_1rw1r_80x64_8
# Keep the educational macro smoke flow practical under Docker/QEMU on Apple
# Silicon. The default adder remap invokes Yosys extract_fa, which can dominate
# runtime on this flattened vTPU design and is not needed to validate SRAM macros.
export ADDER_MAP_FILE =

export SRAM_DIR = $(FLOW_HOME)/platforms/sky130ram/sky130_sram_1rw1r_80x64_8
export ADDITIONAL_LEFS = $(SRAM_DIR)/sky130_sram_1rw1r_80x64_8.lef
export ADDITIONAL_LIBS = $(SRAM_DIR)/sky130_sram_1rw1r_80x64_8_TT_1p8V_25C.lib
export ADDITIONAL_GDS = $(SRAM_DIR)/sky130_sram_1rw1r_80x64_8.gds
export MACRO_PLACEMENT_TCL = $(VTPU_REPO_ROOT)/physical/openroad/designs/sky130hd/vtpu_pd_tiny/macro_placement.tcl
export PDN_TCL = $(VTPU_REPO_ROOT)/physical/openroad/designs/sky130hd/vtpu_pd_tiny/pdn.tcl
export MACRO_PLACE_HALO = 20 20

export PLACE_DENSITY = 0.20
export GPL_TIMING_DRIVEN = 0
export GPL_ROUTABILITY_DRIVEN = 0
export TNS_END_PERCENT = 0
export REMOVE_ABC_BUFFERS = 1
export SKIP_CTS_REPAIR_TIMING = 1
export SKIP_INCREMENTAL_REPAIR = 1
export SKIP_LAST_GASP = 1
export SETUP_SLACK_MARGIN = -100
export HOLD_SLACK_MARGIN = -100

export DIE_AREA = 0 0 5200 5200
export CORE_AREA = 100 100 5100 5100

export ABC_AREA = 1
export SYNTH_HIERARCHICAL = 1
