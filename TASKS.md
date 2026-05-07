# TASKS

Gap list for `xsds_128mbyte_sdram_model.sv`, derived from an audit against the AS4C32M16SB datasheet and the project goals stated in `CLAUDE.md` (controller tuning + open-simulator coverage). Items are ordered by impact on those goals, not by implementation effort.

## Bugs

- [ ] **Sequential burst column wrap is wrong for BL ∈ {2, 4, 8}.** `next_col` at `xsds_128mbyte_sdram_model.sv:467` does `(start_col + index) & (COLS - 1)` on the sequential branch, which wraps at the page boundary (1024) regardless of burst length. JEDEC SDR sequential bursts wrap inside the BL-aligned block — a BL=4 burst starting at col 6 should produce 6,7,4,5, but the model produces 6,7,8,9.
  - Fix: keep base/offset like the interleaved branch but use `+` instead of `^`:
    ```sv
    low_mask = len - 1;
    base     = start_col & ~low_mask;
    offset   = (start_col + index) & low_mask;
    next_col = (base | offset) & (COLS - 1);
    ```
  - Collapses to the existing page-wrap formula when `len == FULL_PAGE_LEN`, so full-page bursts remain correct.

## Missing timing checks (high value for controller tuning)

These are the rules MiSTer-style controllers most commonly trip:

- [ ] **tWTR** — WRITE-to-READ recovery, same bank. `last_write[bank]` is stamped but only consulted by tWR (write-to-precharge). Add a `check_time_min` against `last_write[bank]` in `do_read`.
- [ ] **tIS / tIH** — input setup/hold on Cs/Ras/Cas/We/Addr/Ba/DQM around `posedge Clk`. `tIS_MIN` parameter exists at `xsds_128mbyte_sdram_model.sv:181` but is only used in a tXSR derivation, never as an actual input-side check.
- [ ] **tDS / tDH** — DQ setup/hold during writes. Not modeled.
- [ ] **tAC / tOH / tHZ / tLZ** — read DQ output timing. Model currently drives DQ exactly on the clock edge with zero delay. Biggest IO-side gap: controllers can pass here and still fail closure on real silicon because the read-data window doesn't match.
- [ ] **tXP / tCKS** — power-down exit timing and CKE setup before SREF/PD entry. Not modeled.
- [ ] **tCCD** — column-to-column command spacing. Not enforced.

## Behavioral subtleties that diverge from real silicon

- [ ] **Clock-suspend during a read burst Hi-Z's DQ.** `xsds_128mbyte_sdram_model.sv:1102-1103` sets `dq_oe=0` on CKE-low while a read burst is active. Real chips hold the current output until CKE returns. Controllers that toggle CKE mid-burst will see different behavior here vs. silicon.
- [ ] **Auto-precharge timing fires after the last burst output.** Real chips trigger the implied PRECHARGE earlier (≈BL−CL) so a same-bank ACT can come sooner. The model's later trigger means an ACT-after-AP that's legal on silicon may trip tRP here. Conservative direction — good for catching aggressive controllers, but document or fix.
- [ ] **Mode register decoded to defaults at time 0.** Real silicon has it undefined until MRS. The init checker prevents anyone from seeing the defaults today, so cosmetic, but a tester who disables the init checker silently gets BL=1/CL=3 instead of an error.
- [ ] **X-propagation on commands.** `decode_cmd` casts to `bit`, so an X on Cs_n/Ras_n/Cas_n/We_n collapses to a defined command. Real chips would do something undefined. Useful X-prop bugs in controllers can be hidden. Add an explicit "any command-input X while CKE=1" → error path.

## Module-wrapper gaps (XSDS-specific)

- [ ] **No aggregate refresh status across the two chips.** Each chip independently tracks 8192/64 ms; if a controller refreshes only one ChipSel state, only that chip's checker fires. Add a `module_refresh_status()` task that reports both chips at end-of-test so testbenches can assert "all good."
- [ ] **Bus-contention warning is combinational** and posts continuously while both selects assert. Convert to edge-triggered (once per event) so the log isn't flooded.
- [ ] **No ChipSel-vs-command timing relationship checked** — ChipSel changing mid-burst during a same-cycle command isn't flagged. Lower priority; revisit if a real bug surfaces.

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
