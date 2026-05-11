# Verilator lint target for xsds_128mbyte_sdram_model.sv.
#
# This Makefile is run from the repository root:
#   make -C verilator lint
#
# --bbox-unsup is required because Verilator does not currently support
# tristate (inout) ports propagating through hierarchy: the wrapper's
# inout Dq pass-through to the chip instances trips an UNSUPPORTED check.
# With --bbox-unsup, those constructs are black-boxed at elaboration
# time and the rest of the model still lints normally — every genuine
# syntax / width / unused-signal issue is caught.

VERILATOR ?= verilator

# Project root, regardless of where make is invoked.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

LINT_FLAGS := \
	--lint-only \
	--sv \
	--timing \
	--bbox-unsup \
	--top-module verilator_lint_stub

SOURCES := \
	$(ROOT)/verilator/lint_stub.sv \
	$(ROOT)/xsds_128mbyte_sdram_model.sv

.PHONY: lint clean
lint:
	$(VERILATOR) $(LINT_FLAGS) $(SOURCES)

clean:
	rm -rf obj_dir
