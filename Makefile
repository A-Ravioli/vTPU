PYTHON ?= python3
PYTHONPATH := src:.
OPENROAD_FLOW_ROOT ?= /Users/arav/Desktop/Coding/OpenROAD-flow-scripts/flow
OPENROAD_DOCKER_IMAGE ?= openroad/orfs:latest
OPENROAD_DOCKER_PLATFORM ?= linux/amd64
RTL_SOURCES := \
	rtl/common/vtpu_pkg.sv \
	rtl/common/perf_counters.sv \
	rtl/primitive/pe_int8.sv \
	rtl/primitive/fp32_mul.sv \
	rtl/primitive/fp32_add.sv \
	rtl/primitive/fp32_recip.sv \
	rtl/primitive/fp32_rsqrt.sv \
	rtl/primitive/fp32_exp.sv \
	rtl/primitive/pe_bf16.sv \
	rtl/memory/vmem_bank.sv \
	rtl/mxu/systolic_array.sv \
	rtl/mxu/systolic_array_bf16.sv \
	rtl/mxu/mxu_top.sv \
	rtl/vector/vector_unit.sv \
	rtl/vector/reduce_unit.sv \
	rtl/tensor_core/tensor_core.sv \
	rtl/isa/instr_decoder.sv \
	rtl/isa/instr_mem.sv \
	rtl/isa/control_fsm.sv \
	rtl/memory/hbm_model.sv \
	rtl/memory/hbm_model_loadable.sv \
	rtl/memory/cmem_top.sv \
	rtl/memory/dma_engine.sv \
	rtl/memory/vmem_top.sv \
	rtl/top/virtual_tpu_v4_top.sv

.PHONY: all test-python test-rtl-unit test-rtl-integration lint physical-lint physical-full-lint physical-synth-check physical-synth-check-docker physical-full-synth-check-docker physical-openroad physical-openroad-docker physical-openroad-synth-odb-docker physical-openroad-floorplan-docker physical-full-openroad-docker physical-full-openroad-floorplan-docker waves clean

all: test-python test-rtl-unit test-rtl-integration

test-python:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m pytest -q tests/python

lint:
	@if command -v verilator >/dev/null 2>&1; then \
		verilator --lint-only -Wall --timing --Wno-MULTITOP --Wno-UNUSEDPARAM --Wno-UNUSEDSIGNAL --Wno-BLKSEQ -Irtl/common $(RTL_SOURCES); \
	else \
		echo "verilator not installed"; \
		exit 1; \
	fi

physical-lint:
	@if command -v verilator >/dev/null 2>&1; then \
		verilator --lint-only -Wall --timing --Wno-MULTITOP --Wno-UNUSEDPARAM --Wno-UNUSEDSIGNAL --Wno-BLKSEQ -Irtl/common -f physical/rtl_sources.f --top-module vtpu_pd_tiny_top; \
	else \
		echo "verilator not installed"; \
		exit 1; \
	fi

physical-full-lint:
	@if command -v verilator >/dev/null 2>&1; then \
		verilator --lint-only -Wall --timing --Wno-MULTITOP --Wno-UNUSEDPARAM --Wno-UNUSEDSIGNAL --Wno-BLKSEQ -Irtl/common -f physical/rtl_sources.f --top-module vtpu_pd_full_top; \
	else \
		echo "verilator not installed"; \
		exit 1; \
	fi

physical-synth-check:
	@if ! command -v yosys >/dev/null 2>&1; then \
		echo "yosys not installed"; \
		exit 1; \
	elif yosys -m slang -p slang_version >/dev/null 2>&1; then \
		yosys -q -m slang -s physical/yosys/synth_vtpu_pd_tiny_slang.ys; \
	else \
		echo "local yosys is installed but lacks the slang plugin; use 'make physical-synth-check-docker'"; \
		exit 1; \
	fi

physical-synth-check-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-w /work/vTPU \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && yosys -q -m slang -s physical/yosys/synth_vtpu_pd_tiny_slang.ys'

physical-full-synth-check-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-w /work/vTPU \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && yosys -q -m slang -s physical/yosys/synth_vtpu_pd_full_slang.ys'

physical-openroad:
	@if [ -z "$(OPENROAD_FLOW_ROOT)" ]; then \
		echo "Set OPENROAD_FLOW_ROOT to your OpenROAD-flow-scripts/flow directory"; \
		exit 1; \
	fi
	$(MAKE) -C $(OPENROAD_FLOW_ROOT) DESIGN_CONFIG=$(CURDIR)/physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk

physical-openroad-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-v $(OPENROAD_FLOW_ROOT):/OpenROAD-flow-scripts/flow \
		-w /OpenROAD-flow-scripts/flow \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG=/work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk'

physical-openroad-synth-odb-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-v $(OPENROAD_FLOW_ROOT):/OpenROAD-flow-scripts/flow \
		-w /OpenROAD-flow-scripts/flow \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && mkdir -p results/sky130hd/vtpu_pd_tiny/base && cp /work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_tiny/constraint.sdc results/sky130hd/vtpu_pd_tiny/base/1_2_yosys.sdc && touch results/sky130hd/vtpu_pd_tiny/base/1_2_yosys.v results/sky130hd/vtpu_pd_tiny/base/1_2_yosys.sdc && make DESIGN_CONFIG=/work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk results/sky130hd/vtpu_pd_tiny/base/1_synth.odb'

physical-openroad-floorplan-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-v $(OPENROAD_FLOW_ROOT):/OpenROAD-flow-scripts/flow \
		-w /OpenROAD-flow-scripts/flow \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && cp /work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_tiny/constraint.sdc results/sky130hd/vtpu_pd_tiny/base/1_synth.sdc && make DESIGN_CONFIG=/work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_tiny/config.mk do-2_1_floorplan'

physical-full-openroad-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-v $(OPENROAD_FLOW_ROOT):/OpenROAD-flow-scripts/flow \
		-w /OpenROAD-flow-scripts/flow \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG=/work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_full/config.mk'

physical-full-openroad-floorplan-docker:
	docker run --rm --platform $(OPENROAD_DOCKER_PLATFORM) \
		-u $$(id -u):$$(id -g) \
		-v $(CURDIR):/work/vTPU \
		-v $(OPENROAD_FLOW_ROOT):/OpenROAD-flow-scripts/flow \
		-w /OpenROAD-flow-scripts/flow \
		$(OPENROAD_DOCKER_IMAGE) \
		bash -lc 'source /OpenROAD-flow-scripts/env.sh && make DESIGN_CONFIG=/work/vTPU/physical/openroad/designs/sky130hd/vtpu_pd_full/config.mk do-2_1_floorplan'

test-rtl-unit: lint
	PYTHONPATH=$(PYTHONPATH):tests/cocotb $(PYTHON) -m pytest -q tests/rtl/test_pe_runner.py
	PYTHONPATH=$(PYTHONPATH):tests/cocotb $(PYTHON) -m pytest -q tests/rtl/test_memory_runner.py
	PYTHONPATH=$(PYTHONPATH):tests/cocotb $(PYTHON) -m pytest -q tests/rtl/test_unit_matrix_runner.py

test-rtl-integration: lint
	PYTHONPATH=$(PYTHONPATH):tests/cocotb $(PYTHON) -m pytest -q tests/rtl/test_chip_runner.py

waves:
	WAVES=1 $(MAKE) test-rtl-unit

clean:
	rm -rf .pytest_cache sim_build tests/python/__pycache__ tests/rtl/__pycache__ tests/cocotb/__pycache__ src/virtual_tpu/__pycache__ src/virtual_tpu/archsim/__pycache__ src/virtual_tpu/archsim/network/__pycache__ compiler/__pycache__ examples/__pycache__
