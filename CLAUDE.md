# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository scope

This repo contains exactly one SystemVerilog source file (`xsds_128mbyte_sdram_model.sv`) plus the AS4C32M16SB datasheet PDF and a short README. There is no build system, no test harness, and no CI. The model is consumed by external simulation environments (e.g., the MiSTer FPGA project's verification flow). When running it, the user supplies their own simulator (Verilator, ModelSim, Questa, VCS, Xcelium, etc.) and testbench.

The model is **simulation-only** — it uses `inout` DQ tri-state, `realtime` timing checks, `$error`/`$warning`/`$display`, a sparse associative-array memory, and SystemVerilog queues. Do not introduce constructs that would be fine in simulation but would silently change behavior here, and do not attempt to make any of it synthesizable.

## Architecture

The file declares two modules:

1. `xsds_128mbyte_sdram_model` — top-level 128 MB module wrapper. It instantiates two `as4c32m16sb_6tin_chip_model` chips on a shared DQ/CTRL bus and demuxes one module-level `Cs_n` into two per-chip chip-selects using the `ChipSel` input. `CHIPSEL_ACTIVE_FOR_CHIP1` (default 1) decides which logical level of `ChipSel` selects chip 1.
2. `as4c32m16sb_6tin_chip_model` — the actual 512 Mbit / 64 MB x16 SDR SDRAM behavioral model. All real protocol/timing/state lives here.

The wrapper has two responsibilities worth knowing:
- It enforces "only one of the two chips is selected at a time" via OR'ing `Cs_n` with the chip-mask (`chip0_cs_n = Cs_n | chip1_selected`, etc.). If both chips were ever selected together, the shared inout DQ bus would contend; `CHECK_BUS_CONTENTION` raises a `$warning` in that case.
- Because each chip independently tracks its own 8192-refresh-per-64ms window, **the surrounding controller/testbench must issue refreshes against both chip-select states** — refreshing only chip 0 will eventually trip the refresh checker on chip 1.

### Chip-model internal architecture

The chip model is organized as several cooperating subsystems, all driven by a single `always @(posedge Clk)` block (`main_proc`):

- **Command decode** — `decode_cmd()` maps `{Cs_n, Ras_n, Cas_n, We_n, Cke}` to one of `CMD_DESL/NOP/ACT/READ/WRIT/PRE/AREF/MRS/BST/SREF`. The AREF vs SREF distinction depends on CKE *at this clock*.
- **Sparse memory** — `data_t mem [mem_key_t]` is a 16-bit-wide associative array keyed on `{bank,row,col}` (25 bits). Reads of never-written cells return `16'hxxxx` when `INIT_UNWRITTEN_TO_X` is set, else `16'h0000`. Testbench helpers `poke()`, `peek()`, and `clear_memory()` provide direct backing-store access.
- **Bank state** — per-bank `bank_open`, `open_row`, and `last_activate/precharge/write/read` timestamps. `last_any_activate`, `last_refresh`, `last_mrs`, and `last_self_refresh_exit` are global. Timestamps are seeded to `-1.0e30` so the first command can't trigger a "previous interval too short" check.
- **Mode register** — `load_mode_register()` decodes BL (1/2/4/8/full-page), CAS latency (2 or 3), burst type (sequential/interleaved), and write-burst single-vs-burst. Reserved encodings issue an error and fall back to safe defaults.
- **Burst engine** — `burst_state_t burst` holds the active read or write burst. `next_col()` computes the next column for both sequential and interleaved bursts. Reads honor a two-cycle DQM output-mask pipeline (`dqm_pipe[0..1]`) per the datasheet's read-DQM latency. Writes go straight to memory through `consume_write_data()` on each clock that is part of the burst.
- **Refresh tracker** — `record_refresh()` keeps a queue of refresh timestamps capped at `REFRESHES_PER_WINDOW`. Once full, it errors if the span exceeds `tREF_WINDOW`. With `WARN_TREFI`, gaps larger than `tREFI_MAX` warn even before the window fills.
- **Init sequence checker** — `check_init_before_normal_cmd()` errors if any of CKE high, PRECHARGE ALL, MRS, or two AUTO REFRESH cycles haven't happened before an ACT/READ/WRITE.
- **Power-management states** — `in_power_down`, `in_self_refresh`, `in_clock_suspend`. Entry is gated on the CKE falling edge plus current command; exit is on the CKE rising edge. Self-refresh exit clears the refresh queue and stamps `last_self_refresh_exit` (used to enforce a tXSR-equivalent delay before the next ACT).
- **Clock-period checks** — separate `always @(posedge Clk)` / `always @(negedge Clk)` blocks check `tCH_MIN` / `tCL_MIN`. Note these are independent of `main_proc` and run unconditionally.

### Timing and error policy

`STRICT_TIMING` (default 1) routes `issue_error()` to `$error`; with it cleared, all errors degrade to `$warning`. `issue_warn()` always goes to `$warning`. `check_time_min()` is the canonical helper — it skips the check if the prior timestamp is still at the `-1e30` sentinel, so first-use of any state is safe. When changing or adding a check, follow this same pattern (sentinel guard + `check_time_min()` rather than ad-hoc subtraction).

The chip's default timing parameters are the **AS4C32M16SB-6TIN** speed grade (see the included datasheet PDF). Other speed grades / vendors can be modeled by overriding the `tCK_*`, `tRC_MIN`, `tRFC_MIN`, `tRCD_MIN`, `tRP_MIN`, `tRRD_MIN`, `tMRD_MIN`, `tRAS_MIN`/`MAX`, `tWR_MIN`, `tIS_MIN`, `tREFI_MAX` parameters at instantiation. `FULL_PAGE_LEN` is intentionally a parameter because some datasheets list 512 instead of 1024 for full-page bursts on this geometry.

### Geometry assumptions

The sparse-memory key (`mem_key_t = bit [24:0]`) and `make_key()` slice widths (`bank[1:0]`, `row[12:0]`, `col[9:0]`) are hard-coded for the 4-bank / 8192-row / 1024-column geometry. The `BANKS`/`ROW_BITS`/`COLS` parameters exist but `make_key()` will silently truncate if you change them without also widening `mem_key_t` and the slice widths. Treat geometry-parameter changes as cross-cutting edits.

## Working on this codebase

- The single-file structure is intentional. Keep both modules in `xsds_128mbyte_sdram_model.sv` unless explicitly asked to split.
- `DEBUG=1'b0` is the default; instantiating with `DEBUG=1'b1` produces verbose `$display` traces that are very useful when triaging a failing testbench but noisy otherwise. Don't unconditionally enable it.
- The README example shows the canonical wrapper instantiation (port-by-port, with `STRICT_TIMING`/`CHIPSEL_ACTIVE_FOR_CHIP1`). Update the README example if you change ports or rename parameters.
- There is no formatter or linter committed. Match the existing style: 4-space indent, lowercase task/function names with underscores, ALL_CAPS parameters, port lists aligned with two-space gutters between name and `(signal)`.
- The MiSTer SDRAM bus presents `Addr[12:0]` (13 bits) even on parts whose row width is smaller; row selection uses `Addr[ROW_BITS-1:0]` and column uses `Addr[COL_BITS-1:0]`, with `Addr[10]` reused as the auto-precharge / precharge-all flag.
