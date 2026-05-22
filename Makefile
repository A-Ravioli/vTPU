PYTHON ?= python3
PYTHONPATH := src:.
RTL_SOURCES := \
	rtl/common/vtpu_pkg.sv \
	rtl/common/perf_counters.sv \
	rtl/primitive/pe_int8.sv \
	rtl/memory/vmem_bank.sv \
	rtl/mxu/systolic_array.sv \
	rtl/mxu/mxu_top.sv \
	rtl/vector/vector_unit.sv \
	rtl/vector/reduce_unit.sv \
	rtl/tensor_core/tensor_core.sv \
	rtl/isa/instr_decoder.sv \
	rtl/isa/instr_mem.sv \
	rtl/isa/control_fsm.sv \
	rtl/memory/hbm_model.sv \
	rtl/memory/cmem_top.sv \
	rtl/memory/dma_engine.sv \
	rtl/memory/vmem_top.sv \
	rtl/top/virtual_tpu_v4_top.sv

.PHONY: all test-python test-rtl-unit test-rtl-integration lint waves clean

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
