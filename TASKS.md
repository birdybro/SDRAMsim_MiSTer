# TASKS

Gap list for `xsds_128mbyte_sdram_model.sv`, derived from an audit against the AS4C32M16SB datasheet, the project goals stated in `CLAUDE.md` (controller tuning + open-simulator coverage), and a survey of the ~91 reference MiSTer controllers under `ref/MiSTer SDRAM Controller Modules/`. Items are ordered by impact on those goals, not by implementation effort.

## XSDS hardware facts (resolved by inspecting `ref/sdram_xsds_3.0.pdf`)

These were open architectural questions in earlier revisions of this file. Answered by the schematic; left here because they shape every other task.

- ✅ **DQM is tied to A[11:12] on the XSDS board.** Both chips' DQML/DQMH pins are bonded to the A11/A12 nets at the connector. Existing MiSTer controllers' `assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];` works as-is.
- ✅ **There is no separate ChipSel pin.** The connector exposes only `CS1`; an on-board `LVC1G04` inverter (U3) drives chip 2's `CS#` from `~CS1`. The hardware cannot deselect both chips simultaneously. To reach the full 128 MB, a controller has to use `CS1` as the high address bit *and* always drive RAS/CAS/WE = NOP encoding (`111`) when `CS1=1`, otherwise it'll silently route commands to chip 2 instead of idling.
- ✅ **CKE is hardwired to VCC.** Power-down, self-refresh, and clock-suspend are physically impossible through the XSDS connector.

## Top priority — wrapper rewrite ✅ done

- [x] **Rewrite the `xsds_128mbyte_sdram_model` wrapper to match the actual 40-pin XSDS connector.** Landed: wrapper now exposes only connector signals (`Clk`, `Cs1_n`, `Ras_n`, `Cas_n`, `We_n`, `Ba`, `Addr`, `Dq`); `Cke` tied to `1'b1` internally; `Ldqm`/`Udqm` driven from `Addr[11]`/`Addr[12]`; chip 0's `Cs_n = Cs1_n`, chip 1's `Cs_n = ~Cs1_n`. Dead parameters (`CHIPSEL_ACTIVE_FOR_CHIP1`, `CHECK_BUS_CONTENTION`) removed; `WARN_TREFI`/`INIT_UNWRITTEN_TO_X` now forwarded. README example and chip-level model unchanged.

## Direction resolved (was "decision still pending")

- [x] ~~**No existing MiSTer controller addresses chip 2.**~~ Direction: build a small CS1-aware adapter so existing cores can transparently address the full 128 MB. NeoGeo is the load-bearing case (its ROMs are the only ones in the MiSTer fleet that actually need the upper 64 MB).

## Test-harness work

- [x] ~~**Top-level testbench shim that maps a MiSTer-style controller bus to the new wrapper.**~~ Landed: `xsds_cs1_adapter.sv` is a purely combinational CS1-aware adapter (takes a controller's existing single-CS SDRAM bus plus a 1-bit `ctrl_chip` signal and forces NOP encoding when the controller deasserts CS); `xsds_tb_shim.sv` is a self-contained smoke test that wires the adapter to two chip instances and exercises init / write / read on both chips. Passes clean under Verilator (`make -C verilator smoke`) with zero violations. Notes for bring-up: under Verilator the shim instantiates the chips directly because Verilator's tristate-through-hierarchy limitation chokes on the wrapper's inout pass-through even with --bbox-unsup at runtime; commercial sims can use the wrapper directly with the same adapter + stim pattern.
- [~] **Bring-up target order** (agreed): (1) `MemTest_MiSTer` — **first bring-up landed** as `xsds_tb_memtest.sv` (`make -C verilator memtest`). 50 µs of activity post-rst_n: both chips init clean, BL=4 CL=3 bursts run, distributed refresh ticking — 0 errors / 0 warnings. Notable findings during bring-up: MemTest is XSDS-native (drives CS as the high chip-select bit; does NOT use `xsds_cs1_adapter`), uses `altddio_out` (stubbed in `verilator/altddio_out_stub.sv`), and does not reset its `cmd`/`cs` pipeline (TB gates RAS/CAS/WE to NOP during rst_n so the chip's 200 µs power-up check sees clean idle). (2) A representative BL=1 CL=2 console core (`NES_MiSTer` or `Genesis_MiSTer`). (3) A full-page-burst core (Saturn/MegaCD). (4) `jtframe_sdram` as its own track. NeoGeo is the load-bearing case for chip-2 coverage once its controller is added to the corpus. Note: `Jaguar_MiSTer` / `Arcade-Darius_MiSTer` self-refresh paths can't be exercised through the XSDS connector since CKE is tied high — they're chip-level standalone tests, not XSDS regressions.

## Bugs

- [x] ~~**Sequential burst column wrap is wrong for BL ∈ {2, 4, 8}.**~~ Fixed: `next_col` sequential branch now uses `(base | offset) & (COLS - 1)` with `base = start_col & ~(len-1)` and `offset = (start_col + index) & (len-1)`, mirroring the interleaved branch but with `+` instead of `^`. Wraps inside the BL-aligned block per JEDEC; collapses to the page-wrap formula at `len == FULL_PAGE_LEN`.

## Missing timing checks (high value for controller tuning)

These are the rules MiSTer-style controllers most commonly trip:

- [x] ~~**tWTR** — WRITE-to-READ recovery, same bank.~~ Added: `tWTR_MIN` parameter (default 7.5 ns ≈ 1 tCK at the -6/-7 grade) and a `check_time_min` against `last_write[bank]` at the top of `do_read`. As part of this fix, `last_write[bank]` is now stamped inside `consume_write_data` on every data cycle instead of once at the WRITE command, so tWR (write-to-precharge) and tWTR both measure from the last DQ input — correct for BL > 1.
- [ ] **tIS / tIH** — input setup/hold on Cs/Ras/Cas/We/Addr/Ba/DQM around `posedge Clk`. `tIS_MIN` parameter exists at `xsds_128mbyte_sdram_model.sv:181` but is only used in a tXSR derivation, never as an actual input-side check.
- [ ] **tDS / tDH** — DQ setup/hold during writes. Not modeled.
- [~] **tAC / tOH / tHZ / tLZ** — read DQ output timing. tAC partially modeled: added `tAC_MAX` parameter (default 5.4 ns, the AS4C32M16SB-6TIN typical) and converted `advance_read_burst`'s `dq_out`/`dq_oe` updates plus the main-loop "not read this cycle" fallback to NBA-with-intra-assignment-delay. DQ now becomes valid `tAC_MAX` after the clock edge and goes Hi-Z `tAC_MAX` after the cycle that ends a read. This uses one parameter as an approximation for tAC / tLZ / tHZ; tOH still ends up roughly equal to tAC under this scheme. **Note**: Verilator users need `--timing` for intra-assignment delays to take effect; without it the read window collapses back to zero. CKE-low / SREF / PD paths' `dq_oe = 0` writes are still blocking (unreachable on XSDS so deferred). Remaining work: split into separate tHZ/tLZ parameters and add a real tOH.
- [ ] **tXP / tCKS** — power-down exit timing and CKE setup before SREF/PD entry. Not modeled. **Note**: CKE is tied to VCC on the XSDS board, so this can never trigger for the XSDS use case. Only relevant for non-XSDS standalone use of the chip model. Lower priority than other timing checks.
- [x] ~~**tCCD** — column-to-column command spacing.~~ Added: `tCCD_MIN` parameter (default 6.0 ns ≈ 1 tCK at -6) plus a global `last_col_cmd` timestamp stamped by both `do_read` and `do_write`. The check fires on any READ/WRITE pair (cross-bank or same-bank) issued closer than `tCCD_MIN`. In practice satisfied trivially when the clock period meets tCK_MIN; main value is making the parameter set explicit and giving slower-grade overrides somewhere to land.

## Behavioral subtleties that diverge from real silicon

- [x] ~~**Clock-suspend during a read burst Hi-Z's DQ.**~~ Fixed: the CKE falling-edge handler no longer clears `dq_oe` when entering clock-suspend (real silicon holds DQ at its current value while the burst engine is frozen). The generic !Cke fallback also no longer clears `dq_oe`. PD / SREF paths still force Hi-Z on entry, which is the correct behavior for those states. Irrelevant on the XSDS connector (CKE is tied to VCC) but matters for chip-level standalone testbenches.
- [x] ~~**Auto-precharge timing fires after the last burst output (READ side).**~~ Fixed for reads: AP now fires when `burst.index` reaches `max(1, BL - CL)` rather than at burst end, so tRP overlaps the trailing CL data cycles and a same-bank ACT can come sooner. The remaining read data continues to drive Dq from the burst snapshot (mem_read uses `burst.row`, not `open_row[bank]`), so closing the row early doesn't affect the data stream.
- [x] ~~**WRITE auto-precharge interacts badly with the per-data-cycle `last_write[bank]` stamp.**~~ Fixed: `do_precharge` now takes an `auto_from_write` flag (default 0). `maybe_auto_precharge` forwards it; `consume_write_data` passes `1` at burst end. When set, the in-task `tWR` check is skipped and `last_precharge[bank]` is stamped at `$realtime + tWR_MIN` so the next ACT's `tRP` check measures from the *deferred* precharge event, not the AP-issue time. Explicit PRE commands and READ+AP continue to use the strict path.
- [ ] **Mode register decoded to defaults at time 0.** Real silicon has it undefined until MRS. The init checker prevents anyone from seeing the defaults today, so cosmetic, but a tester who disables the init checker silently gets BL=1/CL=3 instead of an error.
- [x] ~~**X-propagation on commands.**~~ Added an explicit X/Z check at the top of `main_proc`: always errors on X/Z on Cke; once `init_seen_cke_high` is set, also errors on X/Z on Cs_n/Ras_n/Cas_n/We_n while Cke=1. On detection, the cycle exits via `disable main_proc` so no garbage command dispatches. Pre-init X is tolerated to avoid spamming the log during testbench reset.

## Module-wrapper gaps (XSDS-specific)

- [x] ~~**No aggregate refresh status across the two chips.**~~ Added: wrapper-level `module_refresh_status()` task that calls each chip's `report_refresh_status()`. Testbenches can invoke `<dut>.module_refresh_status()` at end-of-test to dump both chips' refresh counters / window state side by side. (Per-chip violations still raise during the run via `record_refresh`; this task is a TB-side post-mortem helper, not a new check.)
- [x] ~~Bus-contention warning is combinational and posts continuously while both selects assert.~~ Resolved by the wrapper rewrite — `chip0_cs_n = Cs1_n` and `chip1_cs_n = ~Cs1_n` make both-selected structurally impossible. The warning was removed.
- [x] ~~No ChipSel-vs-command timing relationship checked.~~ Obsolete: there is no separate `ChipSel`. `Cs1_n` flows directly into the chip-level command-decode pipeline, so any setup/hold or mid-burst-flip issues are caught by the chip model's own checks.

## Testbench affordances missing

- [x] ~~**`dump_memory(filename)` / `load_memory(filename)` tasks.**~~ Added at both layers: chip-level `dump_memory` / `load_memory` write/read a sparse `<key_hex> <data_hex>` text format (one line per populated cell), and wrapper-level `module_dump_memory` / `module_load_memory` delegate to both chips with `.chip0` / `.chip1` filename suffixes. Round-trips cleanly; comment/blank lines are skipped on load. Good for snapshot/restore between runs.
- [x] ~~**ROM-seeding helper (`load_rom_hex` / similar).**~~ Added: chip-level `load_rom_hex(filename, word_base)` reads one 16-bit hex value per line (no `@address` syntax, comments/blanks skipped) and pokes consecutive words starting at the chip-local 25-bit word index. Wrapper-level `module_load_rom_hex(filename, byte_base)` does the same against module byte address space, dispatching each word to chip 0 or chip 1 based on bit 25 of the global word index — so ROM images that straddle the 64 MB chip boundary at byte 0x0400_0000 are handled in a single call.
- [x] ~~**Global error counter readable from the testbench.**~~ Added: each chip exposes `error_count` / `warning_count` (int unsigned), bumped by every `issue_error` / `issue_warn` call regardless of `STRICT_TIMING` downgrade. Wrapper-level `module_error_count()` / `module_warning_count()` return the sum across both chips. A TB can do `if (dut.module_error_count() != 0) $fatal;` at end-of-test without parsing simulator output.
- [x] ~~**`dump_state()` task** that prints all bank/burst/mode-register state for post-mortem after a failure.~~ Added at chip level: prints counters, mode register, power-management flags, init-checker state, refresh-queue summary, per-bank activity (open/row/last-act/rd/wr/pre), and the current burst (or "idle"). Wrapper-level `module_dump_state()` calls both chips.

## Open-simulator coverage

- [x] ~~**Verify Verilator build.**~~ Confirmed against Verilator 5.048 (April 2026). Queues, associative arrays, `parameter realtime`, and NBA intra-assignment delays all work as expected. Required tweaks: a tiny stub (`verilator/lint_stub.sv`) that makes Dq internal because Verilator does not support tristate at a top-level port, plus the `--bbox-unsup` flag because Verilator does not support the wrapper's inout pass-through through hierarchy either. With those, lint runs clean (no warnings, no errors). Three small width casts (`int'(...)`) and two `mem.first/next() != 0` rewrites in the model were needed to silence cosmetic WIDTHEXPAND / WIDTHTRUNC warnings.
- [x] ~~**CI smoke test under Verilator** with `--lint-only`.~~ Added `verilator/Makefile` with a `lint` target. Run with `make -C verilator lint`. Drop-in for a CI job; exit non-zero on any new warning.
- [ ] **Decide on GHDL strategy.** GHDL is VHDL-only; using this model with GHDL needs either mixed-language sim (fragile) or a VHDL port of the model (real project). Pick a direction or drop GHDL from the stated goals.

## Smaller cleanup

- [x] ~~`last_self_refresh_exit` uses `tRC + tIS` as the post-SREF lockout.~~ Added explicit `tXSR_MIN` parameter (default 70.0 ns per the AS4C32M16SB datasheet). Replaces the `tRC_MIN + tIS_MIN` derivation, which gave 61.5 ns — looser than spec. Note: this is a behavior change for any test that exercised SREF exit at 62–69 ns and used to pass; on the XSDS connector CKE is tied high so SREF is unreachable, but chip-level standalone tests of `as4c32m16sb_6tin_chip_model` may newly trip.
- [x] ~~`check_init_before_normal_cmd` counts init refreshes when `init_seen_precharge_all || init_seen_mrs` is true.~~ Tightened: the gate in `do_auto_refresh` is now just `init_seen_precharge_all`. Out-of-order init sequences (e.g. MRS before PRE-ALL) will no longer have their post-MRS AREFs counted toward the init quota and will instead trip `check_init_before_normal_cmd` on the eventual ACT/READ/WRITE.

## Lower priority based on corpus survey (don't drop, don't prioritize)

- [ ] **Interleaved-burst code path is dead in practice.** Zero of the 91 reference controllers use interleaved burst type — they're all sequential. Don't delete the interleaved support (real chips support it, and a custom test could exercise it), but don't sink optimization or correctness work into it ahead of items above.
