# TASKS

Gap list for `xsds_128mbyte_sdram_model.sv`, derived from an audit against the AS4C32M16SB datasheet, the project goals stated in `CLAUDE.md` (controller tuning + open-simulator coverage), and a survey of the ~91 reference MiSTer controllers under `ref/MiSTer SDRAM Controller Modules/`. Items are ordered by impact on those goals, not by implementation effort.

## XSDS hardware facts (resolved by inspecting `ref/sdram_xsds_3.0.pdf`)

These were open architectural questions in earlier revisions of this file. Answered by the schematic; left here because they shape every other task.

- ✅ **DQM is tied to A[11:12] on the XSDS board.** Both chips' DQML/DQMH pins are bonded to the A11/A12 nets at the connector. Existing MiSTer controllers' `assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];` works as-is.
- ✅ **There is no separate ChipSel pin.** The connector exposes only `CS1`; an on-board `LVC1G04` inverter (U3) drives chip 2's `CS#` from `~CS1`. The hardware cannot deselect both chips simultaneously. To reach the full 128 MB, a controller has to use `CS1` as the high address bit *and* always drive RAS/CAS/WE = NOP encoding (`111`) when `CS1=1`, otherwise it'll silently route commands to chip 2 instead of idling.
- ✅ **CKE is hardwired to VCC.** Power-down, self-refresh, and clock-suspend are physically impossible through the XSDS connector.

## Top priority — wrapper rewrite ✅ done

- [x] **Rewrite the `xsds_128mbyte_sdram_model` wrapper to match the actual 40-pin XSDS connector.** Landed: wrapper now exposes only connector signals (`Clk`, `Cs1_n`, `Ras_n`, `Cas_n`, `We_n`, `Ba`, `Addr`, `Dq`); `Cke` tied to `1'b1` internally; `Ldqm`/`Udqm` driven from `Addr[11]`/`Addr[12]`; chip 0's `Cs_n = Cs1_n`, chip 1's `Cs_n = ~Cs1_n`. Dead parameters (`CHIPSEL_ACTIVE_FOR_CHIP1`, `CHECK_BUS_CONTENTION`) removed; `WARN_TREFI`/`INIT_UNWRITTEN_TO_X` now forwarded. README example and chip-level model unchanged.

## Decision still pending

- [ ] **No existing MiSTer controller addresses chip 2.** All ~91 keep `CS=0` always, so on the XSDS they only touch the lower 64 MB. Pick: (a) build a small CS1-aware adapter/wrapper controller so existing cores can transparently address the full 128 MB; (b) write the first XSDS-native reference controller in this repo; (c) accept the lower-64-MB limit for now. This gates whether chip 2 ever gets real exercise.

## Test-harness work

- [ ] **Top-level testbench shim that maps a MiSTer-style controller bus to the new wrapper.** Once the wrapper rewrite lands and matches the connector, this shim is mostly trivial — connect controller pins straight through. Without the wrapper rewrite, the shim has to fake out DQM-from-A and ChipSel.
- [ ] **Bring-up target order**, easiest → hardest: (1) `MemTest_MiSTer` — deliberate characterization tool, minimal abstraction. (2) A representative BL=1 CL=2 console core (`NES_MiSTer` or `Genesis_MiSTer`). (3) A full-page-burst core (Saturn/MegaCD). (4) `jtframe_sdram` as its own track. (Note: `Jaguar_MiSTer` / `Arcade-Darius_MiSTer` self-refresh paths can't be exercised through the XSDS connector since CKE is tied high — they're chip-level standalone tests, not XSDS regressions.)

## Bugs

- [x] ~~**Sequential burst column wrap is wrong for BL ∈ {2, 4, 8}.**~~ Fixed: `next_col` sequential branch now uses `(base | offset) & (COLS - 1)` with `base = start_col & ~(len-1)` and `offset = (start_col + index) & (len-1)`, mirroring the interleaved branch but with `+` instead of `^`. Wraps inside the BL-aligned block per JEDEC; collapses to the page-wrap formula at `len == FULL_PAGE_LEN`.

## Missing timing checks (high value for controller tuning)

These are the rules MiSTer-style controllers most commonly trip:

- [x] ~~**tWTR** — WRITE-to-READ recovery, same bank.~~ Added: `tWTR_MIN` parameter (default 7.5 ns ≈ 1 tCK at the -6/-7 grade) and a `check_time_min` against `last_write[bank]` at the top of `do_read`. As part of this fix, `last_write[bank]` is now stamped inside `consume_write_data` on every data cycle instead of once at the WRITE command, so tWR (write-to-precharge) and tWTR both measure from the last DQ input — correct for BL > 1.
- [ ] **tIS / tIH** — input setup/hold on Cs/Ras/Cas/We/Addr/Ba/DQM around `posedge Clk`. `tIS_MIN` parameter exists at `xsds_128mbyte_sdram_model.sv:181` but is only used in a tXSR derivation, never as an actual input-side check.
- [ ] **tDS / tDH** — DQ setup/hold during writes. Not modeled.
- [ ] **tAC / tOH / tHZ / tLZ** — read DQ output timing. Model currently drives DQ exactly on the clock edge with zero delay. Biggest IO-side gap: controllers can pass here and still fail closure on real silicon because the read-data window doesn't match.
- [ ] **tXP / tCKS** — power-down exit timing and CKE setup before SREF/PD entry. Not modeled. **Note**: CKE is tied to VCC on the XSDS board, so this can never trigger for the XSDS use case. Only relevant for non-XSDS standalone use of the chip model. Lower priority than other timing checks.
- [ ] **tCCD** — column-to-column command spacing. Not enforced.

## Behavioral subtleties that diverge from real silicon

- [ ] **Clock-suspend during a read burst Hi-Z's DQ.** `xsds_128mbyte_sdram_model.sv:1102-1103` sets `dq_oe=0` on CKE-low while a read burst is active. Real chips hold the current output until CKE returns. Controllers that toggle CKE mid-burst will see different behavior here vs. silicon.
- [ ] **Auto-precharge timing fires after the last burst output.** Real chips trigger the implied PRECHARGE earlier (≈BL−CL) so a same-bank ACT can come sooner. The model's later trigger means an ACT-after-AP that's legal on silicon may trip tRP here. Conservative direction — good for catching aggressive controllers, but document or fix.
- [ ] **Mode register decoded to defaults at time 0.** Real silicon has it undefined until MRS. The init checker prevents anyone from seeing the defaults today, so cosmetic, but a tester who disables the init checker silently gets BL=1/CL=3 instead of an error.
- [ ] **X-propagation on commands.** `decode_cmd` casts to `bit`, so an X on Cs_n/Ras_n/Cas_n/We_n collapses to a defined command. Real chips would do something undefined. Useful X-prop bugs in controllers can be hidden. Add an explicit "any command-input X while CKE=1" → error path.

## Module-wrapper gaps (XSDS-specific)

- [ ] **No aggregate refresh status across the two chips.** Each chip independently tracks 8192/64 ms; if a controller refreshes only one Cs1_n state, only that chip's checker fires. Add a `module_refresh_status()` task that reports both chips at end-of-test so testbenches can assert "all good."
- [x] ~~Bus-contention warning is combinational and posts continuously while both selects assert.~~ Resolved by the wrapper rewrite — `chip0_cs_n = Cs1_n` and `chip1_cs_n = ~Cs1_n` make both-selected structurally impossible. The warning was removed.
- [x] ~~No ChipSel-vs-command timing relationship checked.~~ Obsolete: there is no separate `ChipSel`. `Cs1_n` flows directly into the chip-level command-decode pipeline, so any setup/hold or mid-burst-flip issues are caught by the chip model's own checks.

## Testbench affordances missing

- [ ] **`dump_memory(filename)` / `load_memory(filename)` tasks.** Currently only `poke`/`peek` exist. MiSTer core tests need to seed SDRAM with a ROM image at t=0 and snapshot state between runs.
- [ ] **Global error counter readable from the testbench.** `$error` bumps the simulator's count, but there's no "did this chip see ≥1 violation" boolean a TB can assert on at end-of-test.
- [ ] **`dump_state()` task** that prints all bank/burst/mode-register state for post-mortem after a failure.

## Open-simulator coverage

- [ ] **Verify Verilator build.** Should work on 4.220+ (queues, associative arrays, `parameter realtime`). Confirm. The `inout wire [15:0] Dq` may need `--timing` or careful tri-state handling at the testbench top depending on TB style.
- [ ] **CI smoke test under Verilator** with `--lint-only` so regressions on Verilator compatibility are caught fast.
- [ ] **Decide on GHDL strategy.** GHDL is VHDL-only; using this model with GHDL needs either mixed-language sim (fragile) or a VHDL port of the model (real project). Pick a direction or drop GHDL from the stated goals.

## Smaller cleanup

- [ ] `last_self_refresh_exit` uses `tRC + tIS` as the post-SREF lockout. Datasheet calls this tXSR explicitly (typ ~70 ns). Add an explicit `tXSR_MIN` parameter rather than deriving.
- [ ] `check_init_before_normal_cmd` counts init refreshes when `init_seen_precharge_all || init_seen_mrs` is true. JEDEC ordering is PRE-ALL → 2 AREF → MRS; the looser gate hides ordering bugs. Tighten to require PRECHARGE_ALL before counting.

## Lower priority based on corpus survey (don't drop, don't prioritize)

- [ ] **Interleaved-burst code path is dead in practice.** Zero of the 91 reference controllers use interleaved burst type — they're all sequential. Don't delete the interleaved support (real chips support it, and a custom test could exercise it), but don't sink optimization or correctness work into it ahead of items above.
