# SDRAM Controller Guide — XSDS module for MiSTer

This document is for developers writing or adapting an SDRAM controller to drive the XSDS 128 MB module on the MiSTer FPGA platform. It synthesizes:

- The XSDS v3.0 schematic (`ref/sdram_xsds_3.0.pdf`)
- The AS4C32M16SB-6TIN datasheet (`ref/AllianceMemory_512M_SDRAM_Bdie_AS4C32M16SB-7TXN-6TIN-7BIN_Rev1.2_March2020.pdf`)
- Patterns and pitfalls observed across ~91 existing MiSTer SDRAM controllers (`ref/MiSTer SDRAM Controller Modules/`)

For verification, point your testbench at `xsds_128mbyte_sdram_model.sv` — the strict simulation model in this repo will flag protocol/timing violations as `$error`.

This document is **not** a tutorial on SDRAM in general. It assumes you understand bank/row/col addressing, mode register concepts, and clock-edge synchronous design. If you don't, read the AS4C32M16SB datasheet first.

---

## At a glance

| | |
|---|---|
| Module capacity | 128 MB (1024 Mbit) |
| Physical chips | 2 × AS4C32M16SB-6TIN |
| Per chip | 64 MB / 512 Mbit, 4 banks × 8192 rows × 1024 cols × 16 bits |
| Connector | 40-pin header (P1) |
| Bus width | 16 bits (DQ[15:0]) |
| Speed grade | -6TIN: up to 166 MHz at CL=3, up to 100 MHz at CL=2 |
| Refresh | 8192 cycles per 64 ms per chip; both chips independently |

## The 40-pin connector

What the connector exposes:

- `DQ[15:0]` — bidirectional data
- `A[12:0]` — address (also carries DQM, see below)
- `BA[1:0]` — bank
- `CLK`, `RAS#`, `CAS#`, `WE#` — clock and command
- `CS1` — single chip-select (see "CS1 is the high address bit" below)
- `VCC`, `GND`

What the connector does **not** expose (managed on the board):

- `CKE` — both chips' CKE pins are tied to VCC permanently
- `DQML` / `DQMH` — both chips' DQM pins are tied to A11 / A12 at the connector
- `CS2` — internal-only net, generated as `~CS1` via an LVC1G04 inverter (U3)

## Three XSDS-specific quirks you must know

### 1. CKE is hardwired high

The chips' CKE pins are tied to VCC. **Power-down, self-refresh, and clock-suspend modes are physically impossible on this module.** Do not implement them — there is no path to drive CKE low.

Practical implications:

- The init sequence's "raise CKE" step is a no-op. Just wait the 200 µs power-up time.
- You cannot reduce power with self-refresh.
- You cannot pause memory traffic by toggling CKE; use NOPs instead.

### 2. DQM is driven via A[11] and A[12]

The chip's DQML and DQMH pins are physically wired to A11 and A12 at the connector. The controller drives DQM by setting those address bits during the relevant command cycle:

```sv
// The MiSTer-standard DQM pattern — appears in ~80 of the ~91 reference controllers
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
```

Notes:

- During READ/WRITE, A[9:0] is the column; A11 is unused as column; A10 is auto-precharge. **A11 and A12 are free during R/W cycles to carry DQM.**
- During ACT, A[12:0] is the row. DQM as such doesn't matter on an ACT cycle (no data transfer), but whatever you put on A[11:12] then is just row bits.
- During PRE, A10 is the all-banks bit; A[12:11] are reserved/don't-care.
- During MRS, A[12:11] should be `00` (per the datasheet); don't drive DQM there.
- For reads, DQM input has a **2-cycle output-mask latency**: drive DQM two clocks before the data clock you want to mask. For writes, DQM is captured with the write data (no latency).

### 3. CS1 is the high address bit, not "deselect"

The connector exposes only one chip-select line, `CS1` (P1.33). On the board, an LVC1G04 inverter generates `CS2 = ~CS1`, so:

- `CS1 = 0`: chip 1 (lower 64 MB) decodes commands; chip 2 sees CS=1 and ignores everything.
- `CS1 = 1`: chip 1 ignores; chip 2 (upper 64 MB) decodes commands.
- **There is no state where both chips ignore commands.** "Deselect both" doesn't exist on this hardware.

Implications for your controller:

- **Treat `CS1` as the high chip-select address bit.** Drive `CS1=0` for the lower 64 MB, `CS1=1` for the upper 64 MB.
- **Never use `CS1` as a "deselect" signal.** If you flip `CS1` to "do nothing," whatever's on RAS/CAS/WE is being decoded by the *other* chip. To idle, hold `CS1` at a chosen value and drive `RAS=CAS=WE=1` (NOP / Command Inhibit). The unselected chip is permanently in DESL state because it sees CS=1 — RAS/CAS/WE are irrelevant for that chip.
- **You must refresh both chips.** Each chip independently tracks its own 8192-refresh-per-64ms requirement. Issue AREF cycles against `CS1=0` *and* `CS1=1`.
- **Existing MiSTer controllers (which keep `CS=0` always and use NOP for idle) only ever address chip 1 — the lower 64 MB.** They work, but they only see half the module.

### Address mapping (byte address → SDRAM signals)

For a 27-bit byte address (= 128 MB):

| Bits | Field | Width |
|---|---|---|
| [0] | byte-in-word (drives DQM via A[11]/A[12]) | 1 |
| [10:1] | column A[9:0] | 10 |
| [12:11] | bank BA[1:0] | 2 |
| [25:13] | row A[12:0] | 13 |
| [26] | **CS1** (high chip-select bit) | 1 |

For a 26-bit halfword (16-bit) address, drop bit [0]; drive DQM separately based on which byte(s) you're masking.

## Initialization sequence

Required after power-up. The simulation model with `STRICT_TIMING=1` enforces this exactly.

1. **Wait ≥ 200 µs after VCC is stable.** Hold all command inputs in NOP-equivalent state (`CS1=0`, `RAS=CAS=WE=1`).
2. **PRECHARGE ALL** (`A10=1`). Issue against both chips: once with `CS1=0`, once with `CS1=1`.
3. **AUTO REFRESH × 2 (minimum, datasheet)**. Most controllers do 8 to be safe. Issue against both chips. Honor `tRFC` (≥ 60 ns) between refreshes to the same chip.
4. **MODE REGISTER SET**. Load BL, CL, burst type, write-burst mode. Issue against both chips. Honor `tMRD` (≥ 12 ns / typically 2 cycles) before the next command.
5. Now ACT/READ/WRITE are legal.

**Common init mistakes:**

- Skipping the 200 µs wait — real chips have undefined behavior; the model fires `$error` if you issue commands too early.
- Initializing only chip 1 because the controller never drives `CS1=1` — chip 2's mode register stays at undefined defaults; the first command to the upper 64 MB silently misbehaves.
- Issuing the next command immediately after MRS — `tMRD` is 12 ns, which is ≥ 2 cycles at every reasonable MiSTer clock. Insert at least one NOP.

## Mode register encoding

The mode register is a 13-bit field (A[12:0]) latched during MRS:

```
A[12:11] = 00            // reserved (must be 00)
A[10]    = 0             // operating mode = standard (only valid value)
A[9]     = 0 or 1        // write burst length: 0=burst (matches read BL), 1=single
A[8:7]   = 00            // test mode (must be 00)
A[6:4]   = CAS latency:  010 = CL2,  011 = CL3
A[3]     = 0 or 1        // burst type: 0=sequential, 1=interleaved
A[2:0]   = burst length: 000=1, 001=2, 010=4, 011=8, 111=full-page
```

Typical MiSTer settings (from the corpus):

| Field | Common value | Why |
|---|---|---|
| BL | 1 (`3'b000`) | Single-word access — simplest controller, fast enough for most cores |
| BT | sequential (`0`) | All ~91 corpus controllers use sequential. Interleaved is unused in practice. |
| CL | 2 if SDRAM clock ≤ 100 MHz, 3 above | tCK_min = 10 ns at CL2, 6 ns at CL3 on the -6TIN grade |
| WBL | burst (`0`) | Only relevant when BL > 1 |
| OP mode | standard (`0`) | Only valid value |

The most common MiSTer pattern (CL=2, BL=1, sequential, write-burst):

```sv
localparam [12:0] MODE = 13'b000_0_00_010_0_000;
//                         ^   ^ ^   ^   ^ ^
//                       res WBL OP  CL  BT BL
```

If you use BL=2/4/8: **sequential bursts wrap inside the BL-aligned column block**, not at the page boundary. A BL=4 burst starting at col 6 produces 6, 7, 4, 5 — not 6, 7, 8, 9. Make sure your data path agrees. (Note: as of this writing, the simulation model has a bug here — see TASKS.md. Real silicon behaves as described.)

## Command summary

| Command | CS# | RAS# | CAS# | WE# | Notes |
|---|---|---|---|---|---|
| Command Inhibit / DESL | 1 | × | × | × | Chip ignores everything |
| NOP | 0 | 1 | 1 | 1 | "I'm here, doing nothing" — equivalent to DESL functionally |
| ACT | 0 | 0 | 1 | 1 | A=row, BA=bank |
| READ | 0 | 1 | 0 | 1 | A[9:0]=col, A[10]=auto-precharge |
| WRITE | 0 | 1 | 0 | 0 | A[9:0]=col, A[10]=auto-precharge |
| BURST STOP | 0 | 1 | 1 | 0 | Terminates current burst |
| PRECHARGE | 0 | 0 | 1 | 0 | A[10]=0: bank in BA; A[10]=1: all banks |
| AUTO REFRESH | 0 | 0 | 0 | 1 | All banks must be idle |
| MODE REG SET | 0 | 0 | 0 | 0 | All banks must be idle; A[12:0]=mode value |

## AC timing for AS4C32M16SB-6TIN

| Symbol | Min | Notes |
|---|---|---|
| tCK (CL=3) | 6.0 ns | up to ~166 MHz |
| tCK (CL=2) | 10.0 ns | up to 100 MHz |
| tCH | 2.0 ns | clock high width |
| tCL | 2.0 ns | clock low width |
| tRC | 60 ns | ACT-to-ACT same bank |
| tRFC | 60 ns | refresh cycle / refresh-to-command |
| tRCD | 18 ns | ACT-to-READ/WRITE |
| tRP | 18 ns | PRE-to-ACT same bank |
| tRRD | 12 ns | ACT-to-ACT different bank |
| tMRD | 12 ns | MRS-to-next-command (typically 2 clocks) |
| tRAS (min) | 42 ns | row open time, lower bound |
| tRAS (max) | 120 µs | row open time, upper bound — beyond this, data lost |
| tWR | 12 ns | last-write-data to PRE |
| tIS / tIH | 1.5 / 1.0 ns | input setup / hold around CLK |
| tREFI (target) | 7.8 µs | average AREF interval (= 64 ms / 8192) |

At common MiSTer SDRAM clock rates, rounding *up*:

| | 80 MHz (12.5 ns) | 100 MHz (10 ns) | 133 MHz (7.5 ns) | 166 MHz (6 ns) |
|---|---|---|---|---|
| CL | 2 | 2 | 3 | 3 |
| tRCD cycles | 2 | 2 | 3 | 3 |
| tRP cycles | 2 | 2 | 3 | 3 |
| tRC cycles | 5 | 6 | 8 | 10 |
| tRFC cycles | 5 | 6 | 8 | 10 |
| tRRD cycles | 1 | 2 | 2 | 2 |
| tMRD cycles | 1 | 2 | 2 | 2 |
| tRAS_min cycles | 4 | 5 | 6 | 7 |
| tWR cycles | 1 | 2 | 2 | 2 |
| tREFI cycles | 624 | 780 | 1040 | 1300 |

Build your state machine around these counts. If a count rounds to 1 cycle (e.g., tRRD or tWR at 80 MHz), be cautious — at exactly 1 cycle the `tIS`/`tIH` setup margin gets thin; designers often use 2 even when the math says 1.

## Refresh strategy

Each chip needs 8192 AUTO REFRESH commands per 64 ms = one every ~7.8 µs on average. Two patterns:

**Distributed refresh (most common in MiSTer cores).** Insert one AREF every ~7.8 µs into your normal command stream. Pros: low latency jitter, predictable bandwidth impact. Cons: slightly more state in the controller (refresh counter, arbiter).

**Burst refresh.** Every 64 ms, do all 8192 AREFs back-to-back, then go idle. Pros: simpler timer. Cons: 8192 × tRFC ≈ 500 µs of memory unavailability — visible to a video core. Most MiSTer cores avoid this.

**For the XSDS, do your chosen scheme twice — once for each chip.** The simplest pattern: each refresh tick, issue AREF against `CS1=0` then immediately AREF against `CS1=1`, separated by `tRFC`. Or alternate: tick N goes to chip 1, tick N+1 to chip 2.

**Common refresh mistakes:**

- Refreshing only one chip — model's per-chip refresh tracker fires after ~64 ms.
- Letting tREFI drift past 7.8 µs under heavy load — eventually the 8192-in-64ms window fails. Refresh has to win arbitration eventually.
- Issuing ACT before `tRFC` after AREF — the chip is still recovering. The model checks this.
- Letting a row stay open longer than `tRAS_max` (120 µs) — row data is lost on real silicon. The model checks this.

## Common pitfalls

These are the bugs that show up most often in early bring-up or in the corpus:

- **tRCD violation by exactly one cycle.** Designers round timing constants down. At 100 MHz, tRCD = 18 ns rounds *up* to 2 cycles, not 1 — issuing READ/WRITE the cycle after ACT is illegal.
- **tWR violation on auto-precharge writes.** With A10=1 on a WRITE, the chip starts the implicit PRE `tWR` after the *last* write data. Many controllers issue ACT to the next row too quickly.
- **Forgetting tRFC after refresh.** AREF locks the bus for tRFC (~60 ns / 6 cycles at 100 MHz). Issuing ACT immediately after AREF trips this.
- **Mode register set with banks active.** MRS requires all banks idle. PRE-ALL first.
- **DQM driven on the wrong cycle.** Writes: DQM captured *with* the write data. Reads: DQM input controls output enable two clocks *later*. Off-by-one masks the wrong word.
- **CS1 toggled to "idle"** (XSDS-specific). See section above. The unselected chip will silently execute whatever's on RAS/CAS/WE.
- **Half the module unused** (XSDS-specific). If your controller never drives `CS1=1`, you're addressing only the lower 64 MB. Audit your address-mapping logic.
- **Refresh interval drifts past tREFI under heavy load.** If your controller priority-queues normal access over refresh, watch the average gap. The model warns when the gap exceeds tREFI.
- **CL set to 2 at clock > 100 MHz.** Datasheet says no; the model checks it via `tCK_CL2_MIN`.
- **MRS reserved bits not zero.** A[12:11]=00, A[10]=0, A[8:7]=00. The model warns.

## Verification with the simulation model

`xsds_128mbyte_sdram_model.sv` is a behavioral simulation model with strict timing/protocol checks. Use it inside your core's testbench so your full memory path is exercised, not just the controller in isolation.

Recommended flow:

1. Instantiate at testbench top alongside your core. Connect connector signals (DQ, A, BA, CLK, RAS#, CAS#, WE#, CS1) directly. (As of this writing, the wrapper module is being updated to match the connector exactly — until that lands, see `README.md` for the current port list and supply CKE / DQM / ChipSel from your testbench.)
2. Use defaults: `STRICT_TIMING=1` (`$error` on violation), `DEBUG=0` (turn on for command-by-command tracing during triage).
3. Test helpers:
   - `poke(bank, row, col, value)` — seed a memory cell at t=0.
   - `peek(bank, row, col, value)` — read a cell from the testbench (out-of-band).
   - `clear_memory()` — reset the backing store.
   - `report_refresh_status()` — call at end-of-test to assert refresh health.

If the model fires `$error`, treat it as if real silicon failed — investigate, don't suppress. The model has known gaps documented in `TASKS.md` (notably tWTR, full IO timing, and a few others); a clean model run is necessary but not sufficient for hardware confidence.

## Reference controllers

The `ref/MiSTer SDRAM Controller Modules/` folder contains ~91 community SDRAM controllers from real MiSTer cores. Recommended reading order for new authors:

- `MemTest_MiSTer/rtl/sdram.v` — minimal, characterization-tool style. Easiest to follow.
- `NES_MiSTer/rtl/sdram.sv` — Sorgelig template, BL=1 / CL=2, 3-channel arbitration. Good baseline.
- `Genesis_MiSTer/rtl/sdram.sv` — Sorgelig template, 3-channel 16-bit. Slightly more sophisticated.
- `Saturn_MiSTer/rtl/sdram1.sv` — full-page bursts, CL=3, ~100 MHz. Useful when you outgrow BL=1.
- `jtframe_sdram/` — separate community library with cache + burst FSMs. Larger learning curve, but a strong template once you need a cache layer.

**None of these address the full 128 MB of the XSDS module** — they all keep `CS=0` always, so they only see chip 1. To use the full module, you'll need to extend whichever you start from with `CS1`-aware addressing.

## Pre-deploy checklist

Before running your controller against real hardware, run this checklist against the simulation model:

- [ ] 200 µs power-up wait observed before any command.
- [ ] PRECHARGE ALL → ≥ 2 AUTO REFRESH → MRS init sequence completes against both `CS1=0` and `CS1=1`.
- [ ] Mode register reserved bits (A[12:11], A[10], A[8:7]) all zero.
- [ ] CL field matches your SDRAM clock period (CL=2 only ≤ 100 MHz).
- [ ] DQM driven on A[11:12]; the testbench is wired so `Ldqm = A[11]`, `Udqm = A[12]`.
- [ ] All idle cycles drive `RAS=CAS=WE=1` regardless of `CS1` value.
- [ ] Refreshes issued against both chips; refresh interval ≤ tREFI under realistic load.
- [ ] Both halves of the module exercised (or you've documented that the upper 64 MB is intentionally unused).
- [ ] No tRAS_max violations (rows closed within 120 µs of opening).
- [ ] Clean simulation run with `STRICT_TIMING=1` and your worst-case test pattern.

## Further reading

- AS4C32M16SB datasheet (`ref/AllianceMemory_512M_SDRAM_Bdie_AS4C32M16SB-7TXN-6TIN-7BIN_Rev1.2_March2020.pdf`) — protocol detail, full timing tables, init sequence, errata.
- XSDS schematic (`ref/sdram_xsds_3.0.pdf`) — pinout, the LVC1G04 inverter wiring, decoupling.
- Simulation model (`xsds_128mbyte_sdram_model.sv`) — the strict model; useful as "spec by example" of what's expected.
- Project task list (`TASKS.md`) — known gaps in the model itself; consult before assuming the model is fully accurate on a corner case.
- `CLAUDE.md` — repo-level architectural notes.
