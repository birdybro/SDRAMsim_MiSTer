# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

This repo is a full simulation model for the **XSDS RAM module addon board** for the MiSTer FPGA project — a two-chip 128 MB SDR SDRAM module that plugs into a MiSTer host. The model has two consumers:

1. **The MiSTer SDRAM-controller authors** — they tune their HDL controllers against this model to make sure they meet real-chip timing/protocol rules before going to silicon. So the model has to be *strict* about timing (it is, via `STRICT_TIMING=1`) and faithful about protocol corner cases — the whole point is to fail loudly when a controller does something a real chip would punish.
2. **MiSTer core developers running open simulators (Verilator, GHDL, etc.)** — they want a drop-in 128 MB SDRAM peripheral they can attach to their core's testbench so the entire memory path is exercised in sim, not just the controller in isolation. So the model has to be portable across open-source simulators, not just commercial ones.

When in doubt about a behavior decision, prefer matching real silicon (per the AS4C32M16SB datasheet in `ref/`) over convenience. Loose modeling defeats the controller-tuning use case.

## Repository scope

The project's primary source is `xsds_128mbyte_sdram_model.sv`, which contains both the chip-level behavioral model (`as4c32m16sb_6tin_chip_model`) and the XSDS module wrapper (`xsds_128mbyte_sdram_model`). Around that core sit a small number of supporting files:

- `xsds_cs1_adapter.sv` — purely combinational shim that adapts a typical "single-CS-tied-low" MiSTer controller to the XSDS bus (it takes a 1-bit `ctrl_chip` signal and forces NOP encoding when the controller deasserts CS, so neither chip catches a stray command on the always-one-chip-selected XSDS bus). Drop-in transparent for unmodified controllers (tie `ctrl_chip = 0`).
- `xsds_tb_shim.sv` — a self-contained smoke test that drives synthetic stim against the adapter + chip pair.
- `xsds_tb_memtest.sv`, `xsds_tb_neogeo.sv`, `xsds_tb_nes.sv`, `xsds_tb_saturn.sv` — bring-up TBs that drive the actual MiSTer-core SDRAM controllers (pulled into `ref/MiSTer SDRAM Controller Modules/`) against the chip model. Each documents the controller-specific quirks it had to work around (clock rate, init-pipeline reset gaps, AREF source, etc.). Saturn is the first CL=3 target; the rest are CL=2.
- `verilator/` — Verilator-specific bits: `lint_stub.sv` (top-level shim because Verilator does not support tristate at top-level ports), `altddio_out_stub.sv` (sim-only stand-in for the Altera vendor IP MiSTer cores use to derive `DRAM_CLK`), and a `Makefile` exposing `lint`, `smoke`, `memtest`, `neogeo`, and `nes` targets. The model also runs under commercial simulators (ModelSim, Questa, VCS, Xcelium) without these workarounds.
- `CONTROLLER_GUIDE.md` — protocol/timing rules a controller must follow to satisfy the model.

Everything under `ref/` is reference material, not project source:

- `ref/AllianceMemory_512M_SDRAM_Bdie_AS4C32M16SB-7TXN-6TIN-7BIN_Rev1.2_March2020.pdf` — datasheet for the chip the model emulates. Authoritative source for the per-chip timing parameter defaults and the protocol/state-machine behavior in `as4c32m16sb_6tin_chip_model`.
- `ref/sdram_xsds_3.0.pdf` — datasheet for the XSDS-style module form factor that the top-level `xsds_128mbyte_sdram_model` wrapper emulates (two-chip 128 MB module with shared bus + ChipSel).
- `ref/mt48lc16m16a2.v` and `ref/IS42VM16400K.v` — vendor BFM Verilog models (Micron 256Mb, ISSI 64Mb LP). These are *reference implementations*, not part of the build. They illustrate how each vendor structures bank state, command pipelines, mode-register decode, and DQM/burst handling. Useful when cross-checking that the project model handles a corner case the same way a known-good vendor model does. Do not edit them — they are upstream copies.
- `ref/MiSTer SDRAM Controller Modules/` — snapshot of ~91 community SDRAM controllers from real MiSTer cores (NES_MiSTer, Genesis_MiSTer, PSX_MiSTer, Saturn_MiSTer, the Arcade-* family, etc.) plus the standalone `jtframe_sdram/` library and the upstream-pulled `NeoGeo_MiSTer/` controller. These are the test targets the model needs to handle. Read-only — don't edit. The Arcade-* folders do **not** import from `jtframe_sdram`; they're independent Sorgelig-derived copies, so jtframe is its own bring-up surface.

### XSDS hardware (per `ref/sdram_xsds_3.0.pdf`)

The XSDS v3.0 board's 40-pin connector exposes **only**: `DQ[15:0]`, `A[12:0]`, `BA[1:0]`, `CLK`, `RAS#`, `CAS#`, `WE#`, `CS1`, `VCC`, `GND`. Three signals you'd expect on an SDRAM are *not* on the connector — they're managed on the board:

1. **CKE is hardwired to VCC.** Both chips' CKE pins (U1.37 / U2.37) sit on the VCC rail. **Power-down, self-refresh, and clock-suspend are physically impossible through this connector.** The chip-level model's CKE-low code paths only matter when someone uses `as4c32m16sb_6tin_chip_model` standalone in a non-XSDS testbench.
2. **DQM is tied to A[11:12].** Net `A11` connects to both chips' A11 *and* DQML pins; net `A12` connects to both chips' A12 *and* DQMH pins. So existing MiSTer controllers' `assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];` works on this board unchanged — the convention is preserved.
3. **There is no separate ChipSel pin — `CS1` is the high chip-select bit, internally inverted.** The board has a `LVC1G04` single-gate inverter (`U3`): connector `CS1` → chip U1's CS# directly, and `~CS1` → chip U2's CS#. CS2 is an internal-only net. **The hardware cannot deselect both chips at once** — whichever way `CS1` goes, exactly one chip is decoding commands.

The third point is the sharpest controller-tuning hazard the model can expose. Existing MiSTer controllers keep `CS=0` always and use NOP (`RAS=CAS=WE=1`) for idle, so on the XSDS they only ever address chip 1 (the lower 64 MB). To reach the full 128 MB, a controller must (a) use `CS1` as a high address bit, *and* (b) be careful that any cycle where it drives `CS1=1` also drives RAS/CAS/WE to NOP — otherwise it's silently issuing commands to chip 2 instead of "deselecting." A controller that gets this wrong on the XSDS will appear fine on a single-chip module.

### Wrapper-vs-hardware mapping

The `xsds_128mbyte_sdram_model` wrapper now matches the 40-pin connector exactly. Ports: `Clk`, `Cs1_n`, `Ras_n`, `Cas_n`, `We_n`, `Ba`, `Addr`, `Dq`. Internally: `Cke` tied to `1'b1`; `Ldqm`/`Udqm` for both chips driven from `Addr[11]`/`Addr[12]`; chip 0's `Cs_n = Cs1_n`, chip 1's `Cs_n = ~Cs1_n` (mirroring the LVC1G04 inverter U3 on the board). The chip-level `as4c32m16sb_6tin_chip_model` keeps independent CKE/DQM ports because that's still the correct chip-level abstraction — it's reusable for non-XSDS testbenches where CKE and DQM *are* externally controllable.

### Reference-controller realities

Most of the ~91 controllers under `ref/MiSTer SDRAM Controller Modules/` target a single MT48LC16M16A2-class 32 MB chip and hold CS tied low — they only ever address chip 0 (the lower 64 MB) of the XSDS module. **Two known exceptions are XSDS-native already**: `MemTest_MiSTer` and `NeoGeo_MiSTer` both drive their CS pin from a high address bit, bond DQM to `Addr[12:11]`, and alternate CS during distributed refresh — they reach the full 128 MB without any adapter.

For the remaining ~89 tied-low controllers, `xsds_cs1_adapter.sv` is the bridge: it accepts the controller's existing single-CS bus plus a 1-bit `ctrl_chip` signal (which the controller is expected to drive from the high bit of its address), and produces the XSDS connector bus. With `ctrl_chip = 0` the adapter is transparent (controller behaves exactly as on a 64 MB single-chip module), so it's safe to wire any tied-low controller through it.

Protocol distribution across the corpus (useful for prioritizing test surface):
- BL=1 dominates massively (`BURST_LENGTH = 3'b000` is the typical pattern). A handful use BL=2 or BL=4 (Arcade-IremM62, Arcade-IremM90, Arcade-MCR2, Arcade-IremM92). MemTest and NeoGeo use BL=4 themselves. Full-page bursts appear in some console cores. **No controller uses interleaved bursts** — that code path in `next_col` is essentially dead in practice, though don't delete it.
- CL=2 majority, CL=3 minority (Saturn, ~100 MHz designs).
- Distributed AUTO REFRESH is the norm. SELF REFRESH appears in `Jaguar_MiSTer` and `Arcade-Darius_MiSTer` only — but on the XSDS connector these can never engage because CKE is hardwired high. So tXP/tCKS/tXSR work has *no* live regression target on this board; it only matters for chip-level standalone use of `as4c32m16sb_6tin_chip_model`.

Common controller quirks observed during bring-up (worth assuming for new targets unless proven otherwise):
- **Incomplete reset of the command pipeline.** MemTest, NES, and NeoGeo all leave their `cmd` / `cs` registers at undefined values during reset. At the very first clock edge under 2-state Verilator those registers are 0, which decodes as `LOAD_MODE` and trips the chip's 200 µs power-up check. Bring-up TBs gate `RAS/CAS/WE` to NOP encoding while reset/init is active.
- **`altddio_out` for `DRAM_CLK`.** All three landed bring-ups use the Altera vendor IP. `verilator/altddio_out_stub.sv` covers it; reuse it for any new target.
- **Clock rate mismatches against AS4C32M16SB-6TIN.** NES at 85.91 MHz with `RASCAS_DELAY=1` violates the -6TIN tRCD spec; it's designed for the looser MT48LC16M16A2 timing. Override `tRCD_MIN` at instantiation when modeling a controller built for a different chip family. The `do_precharge` AP path defers PRE internally to satisfy tRAS, so AP timing usually does not need an override. Saturn shows the same pattern at 114.5 MHz with `RASCAS_DELAY=2` (ACT→CAS = 17.46 ns vs the -6TIN's 18 ns spec) — same tRCD_MIN=11.0 override.
- **Controller init→normal transition can violate tRFC.** Saturn's `sdram1.sv` unconditionally sets `state[0].RFS<=1` during `!init_done`; when init_done flips to 1 with mode=MODE_NORMAL, the lingering RFS=1 fires AUTO_REFRESH on the very next cycle, and `st_num=2` (the case-3'b010 branch) fires another AREF ~3 cycles later. -6TIN's tRFC of 60 ns is violated. Surface via per-instance `tRFC_MIN` override (Saturn TB uses 25 ns) with a comment documenting the controller mechanism — this is real-silicon-relevant behavior the model would otherwise correctly catch.

The model is **simulation-only** — it uses `inout` DQ tri-state, `realtime` timing checks, `$error`/`$warning`/`$display`, a sparse associative-array memory, and SystemVerilog queues. Do not introduce constructs that would be fine in simulation but would silently change behavior here, and do not attempt to make any of it synthesizable.

## Architecture

The file declares two modules:

1. `xsds_128mbyte_sdram_model` — top-level 128 MB module wrapper. Its port set matches the XSDS v3.0 40-pin connector exactly: `Clk`, `Cs1_n`, `Ras_n`, `Cas_n`, `We_n`, `Ba`, `Addr`, `Dq`. Internally it instantiates two `as4c32m16sb_6tin_chip_model` chips on a shared DQ bus, ties CKE high, drives `Ldqm`/`Udqm` for both chips from `Addr[11]`/`Addr[12]`, and feeds chip 0's `Cs_n` from `Cs1_n` directly while chip 1's `Cs_n` is `~Cs1_n` (mirroring the on-board LVC1G04 inverter U3). Together this means exactly one chip is always selected — both-deselected is structurally impossible. Parameters: `DEBUG`, `STRICT_TIMING`, `WARN_TREFI`, `INIT_UNWRITTEN_TO_X` (forwarded to both chip instances).
2. `as4c32m16sb_6tin_chip_model` — the actual 512 Mbit / 64 MB x16 SDR SDRAM behavioral model. All real protocol/timing/state lives here. Keeps independent CKE/DQM ports because that's still the correct chip-level abstraction — it's reusable for non-XSDS testbenches where CKE and DQM *are* externally controllable.

Because each chip independently tracks its own 8192-refresh-per-64 ms window, **the surrounding controller/testbench must issue refreshes against both `Cs1_n=0` and `Cs1_n=1`** — refreshing only one will eventually trip the refresh checker on the other chip.

The wrapper exposes a small set of test-bench convenience tasks: `module_dump_state()`, `module_refresh_status()`, `module_dump_memory(prefix)`, `module_load_memory(prefix)`, `module_load_rom_hex(filename, byte_base)` (handles ROM images that straddle the 64 MB chip boundary), and the read-only `module_error_count()` / `module_warning_count()` functions for end-of-test assertions. Each chip-level instance exposes the same set without the `module_` prefix.

### Chip-model internal architecture

The chip model is organized as several cooperating subsystems, all driven by a single `always @(posedge Clk)` block (`main_proc`):

- **Command decode** — `decode_cmd()` maps `{Cs_n, Ras_n, Cas_n, We_n, Cke}` to one of `CMD_DESL/NOP/ACT/READ/WRIT/PRE/AREF/MRS/BST/SREF`. The AREF vs SREF distinction depends on CKE *at this clock*.
- **Sparse memory** — `data_t mem [mem_key_t]` is a 16-bit-wide associative array keyed on `{bank,row,col}` (25 bits). Reads of never-written cells return `16'hxxxx` when `INIT_UNWRITTEN_TO_X` is set, else `16'h0000`. Testbench helpers `poke()`, `peek()`, and `clear_memory()` provide direct backing-store access.
- **Bank state** — per-bank `bank_open`, `open_row`, and `last_activate/precharge/write/read` timestamps. `last_any_activate`, `last_refresh`, `last_mrs`, and `last_self_refresh_exit` are global. Timestamps are seeded to `-1.0e30` so the first command can't trigger a "previous interval too short" check.
- **Mode register** — `load_mode_register()` decodes BL (1/2/4/8/full-page), CAS latency (2 or 3), burst type (sequential/interleaved), and write-burst single-vs-burst. Reserved encodings issue an error and fall back to safe defaults.
- **Burst engine** — `burst_state_t burst` holds the active read or write burst. `next_col()` computes the next column for both sequential and interleaved bursts. Reads honor a two-cycle DQM output-mask pipeline (`dqm_pipe[0..1]`) per the datasheet's read-DQM latency. Writes go straight to memory through `consume_write_data()` on each clock that is part of the burst.
- **Refresh tracker** — `record_refresh()` keeps a queue of refresh timestamps capped at `REFRESHES_PER_WINDOW`. Once full, it errors if the span exceeds `tREF_WINDOW`. With `WARN_TREFI`, gaps larger than `tREFI_MAX` warn even before the window fills.
- **Init sequence checker** — `check_init_before_normal_cmd()` errors if any of CKE high, PRECHARGE ALL, MRS, or two AUTO REFRESH cycles haven't happened before an ACT/READ/WRITE. Also enforces the 200 µs power-up window against any non-NOP/DESL command (anchored at `$realtime` rather than the CKE-high edge so it works on the XSDS connector where CKE is hardwired high).
- **Power-management states** — `in_power_down`, `in_self_refresh`, `in_clock_suspend`. Entry is gated on the CKE falling edge plus current command; exit is on the CKE rising edge. Self-refresh exit clears the refresh queue and stamps `last_self_refresh_exit` (used by the explicit `tXSR_MIN` parameter check before the next ACT). Clock-suspend during a read burst holds DQ at its current value rather than going Hi-Z (matches real silicon).
- **Clock-period checks** — separate `always @(posedge Clk)` / `always @(negedge Clk)` blocks check `tCH_MIN` / `tCL_MIN`. Note these are independent of `main_proc` and run unconditionally.
- **Setup / hold tracking** — dedicated `always @(...)` blocks track the most-recent transition timestamp for command pins (Cs/Ras/Cas/We), address pins (Ba/Addr/Ldqm/Udqm), and Dq. tIS / tDS are checked at posedge Clk; tIH / tDH are checked at each pin transition. The hold-side checks include a `delta > 0.0` guard so the standard NBA-at-posedge sync pattern doesn't false-fire (real silicon's tCO propagation delay would put the change slightly past the edge, which behavioral sim can't represent).
- **X-prop check** — at the top of `main_proc`, errors on `$isunknown` of any command pin while CKE=1 and init has progressed. `$isunknown` rather than `=== 1'bx` so the check works under 2-state simulators (Verilator default).
- **Auto-precharge with deferred PRECHARGE** — `do_precharge` accepts `auto_from_write` / `auto_from_read` flags. On those paths, the in-task tRAS / tWR checks are skipped (real silicon defers the implied PRECHARGE to satisfy them internally) and `last_precharge[bank]` is stamped at the later of the burst-end-with-tWR time or `last_activate + tRAS_MIN`, so the next ACT's tRP check measures from the deferred event. This is what lets controllers like NES and NeoGeo issue `ACT → WRITE+AP` one cycle apart without false violations.

### Timing and error policy

`STRICT_TIMING` (default 1) routes `issue_error()` to `$error`; with it cleared, all errors degrade to `$warning`. `issue_warn()` always goes to `$warning`. `check_time_min()` is the canonical helper — it skips the check if the prior timestamp is still at the `-1e30` sentinel, so first-use of any state is safe. When changing or adding a check, follow this same pattern (sentinel guard + `check_time_min()` rather than ad-hoc subtraction).

The chip's default timing parameters are the **AS4C32M16SB-6TIN** speed grade (see `ref/AllianceMemory_…AS4C32M16SB…pdf`). Other speed grades / vendors can be modeled by overriding the `tCK_*`, `tRC_MIN`, `tRFC_MIN`, `tRCD_MIN`, `tRP_MIN`, `tRRD_MIN`, `tMRD_MIN`, `tRAS_MIN`/`MAX`, `tWR_MIN`, `tWTR_MIN`, `tCCD_MIN`, `tXSR_MIN`, `tIS_MIN`, `tIH_MIN`, `tDS_MIN`, `tDH_MIN`, `tAC_MAX`, `tHZ_MAX`, `tLZ_MIN`, `tREFI_MAX` parameters at instantiation. `FULL_PAGE_LEN` is intentionally a parameter because some datasheets list 512 instead of 1024 for full-page bursts on this geometry.

`tXP` / `tCKS` are intentionally not modeled — both depend on CKE-driven power-management states (PD/SREF entry/exit) which are physically impossible on the XSDS connector since CKE is hardwired to VCC. They would only matter for chip-level standalone use of `as4c32m16sb_6tin_chip_model` outside of an XSDS context, which is not a project goal.

### Geometry assumptions

The sparse-memory key (`mem_key_t = bit [24:0]`) and `make_key()` slice widths (`bank[1:0]`, `row[12:0]`, `col[9:0]`) are hard-coded for the 4-bank / 8192-row / 1024-column geometry. The `BANKS`/`ROW_BITS`/`COLS` parameters exist but `make_key()` will silently truncate if you change them without also widening `mem_key_t` and the slice widths. Treat geometry-parameter changes as cross-cutting edits.

## Working on this codebase

- The two-module-per-file structure for the model itself is intentional. Keep `xsds_128mbyte_sdram_model` and `as4c32m16sb_6tin_chip_model` together in `xsds_128mbyte_sdram_model.sv` unless explicitly asked to split. The adapter (`xsds_cs1_adapter.sv`) and TBs (`xsds_tb_*.sv`) are separate files because they're separate concerns.
- `DEBUG=1'b0` is the default; instantiating with `DEBUG=1'b1` produces verbose `$display` traces that are very useful when triaging a failing testbench but noisy otherwise. Don't unconditionally enable it.
- The README example shows the canonical wrapper instantiation. Update the README example if you change ports or rename parameters.
- Verilator coverage: `make -C verilator lint` lints the model + wrapper stub; `make -C verilator smoke` runs the synthetic adapter+chip stim TB; `make -C verilator memtest` / `neogeo` / `nes` / `saturn` build and run the corresponding bring-up TBs. All five currently pass clean. Verilator needs `--timing` for the NBA intra-assignment delays to model `tAC` / `tHZ` / `tLZ`, and needs `--bbox-unsup` because Verilator does not support inout pass-through through hierarchy. Both flags are wired up in `verilator/Makefile`.
- There is no formatter or linter committed. Match the existing style: 4-space indent, lowercase task/function names with underscores, ALL_CAPS parameters, port lists aligned with two-space gutters between name and `(signal)`.
- The MiSTer SDRAM bus presents `Addr[12:0]` (13 bits) even on parts whose row width is smaller; row selection uses `Addr[ROW_BITS-1:0]` and column uses `Addr[COL_BITS-1:0]`, with `Addr[10]` reused as the auto-precharge / precharge-all flag.
- `Addr[12:11]` are bonded to the chips' DQM pins on the XSDS board, so they double as the per-byte write mask. The wrapper does this routing internally; controllers that follow the standard `assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];` convention work transparently through the wrapper.
