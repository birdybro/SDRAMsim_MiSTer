# Verilator targets for the xsds_128mbyte_sdram_model + adapter + TB shim.
#
# Run from the repository root:
#   make -C verilator lint   # lint the wrapper + chip model
#   make -C verilator smoke  # build and run the TB shim smoke test
#   make -C verilator clean  # remove obj_dir/
#
# --bbox-unsup is required because Verilator does not currently support
# tristate (inout) ports propagating through hierarchy: the wrapper's
# inout Dq pass-through to the chip instances trips an UNSUPPORTED check,
# and the same propagation cascades onto every other port of a chip-level
# instance. With --bbox-unsup, those constructs are black-boxed at
# elaboration time and the rest of the model still lints / simulates
# normally — every genuine syntax / width / unused-signal issue is caught,
# and the chip protocol logic still runs end-to-end under simulation.

VERILATOR ?= verilator

# Project root, regardless of where make is invoked.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

LINT_FLAGS := \
	--lint-only \
	--sv \
	--timing \
	--bbox-unsup \
	--top-module verilator_lint_stub

LINT_SOURCES := \
	$(ROOT)/verilator/lint_stub.sv \
	$(ROOT)/xsds_128mbyte_sdram_model.sv

SMOKE_FLAGS := \
	--binary \
	--sv \
	--timing \
	--bbox-unsup \
	--top-module xsds_tb_shim

SMOKE_SOURCES := \
	$(ROOT)/xsds_tb_shim.sv \
	$(ROOT)/xsds_cs1_adapter.sv \
	$(ROOT)/xsds_128mbyte_sdram_model.sv

MEMTEST_FLAGS := \
	--binary \
	--sv \
	--timing \
	--bbox-unsup \
	-Wno-fatal \
	--top-module xsds_tb_memtest

MEMTEST_SOURCES := \
	$(ROOT)/verilator/altddio_out_stub.sv \
	$(ROOT)/ref/MiSTer\ SDRAM\ Controller\ Modules/MemTest_MiSTer/rtl/sdram.v \
	$(ROOT)/xsds_tb_memtest.sv \
	$(ROOT)/xsds_128mbyte_sdram_model.sv

.PHONY: lint smoke memtest clean

lint:
	$(VERILATOR) $(LINT_FLAGS) $(LINT_SOURCES)

smoke:
	$(VERILATOR) $(SMOKE_FLAGS) $(SMOKE_SOURCES)
	./obj_dir/Vxsds_tb_shim

memtest:
	$(VERILATOR) $(MEMTEST_FLAGS) $(MEMTEST_SOURCES)
	./obj_dir/Vxsds_tb_memtest

clean:
	rm -rf obj_dir
