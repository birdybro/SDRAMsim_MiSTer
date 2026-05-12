# SDRAMsim_MiSTer

Simulation model for the **XSDS RAM module addon board** for the MiSTer
FPGA project — a two-chip 128 MB SDR SDRAM module that plugs into a MiSTer
host. Strict-by-default timing checks against the AS4C32M16SB-6TIN
datasheet, the chip the board uses; portable across Verilator and
commercial simulators.

## Files

- `xsds_128mbyte_sdram_model.sv` — the model itself. Contains the chip-level
  behavioral model (`as4c32m16sb_6tin_chip_model`) and the XSDS module
  wrapper (`xsds_128mbyte_sdram_model`).
- `xsds_cs1_adapter.sv` — purely combinational shim that adapts a typical
  single-CS-tied-low MiSTer controller to the XSDS bus. Lets unmodified
  controllers stay untouched while still being able to address the full
  128 MB through a 1-bit `ctrl_chip` signal.
- `xsds_tb_shim.sv`, `xsds_tb_memtest.sv`, `xsds_tb_neogeo.sv`,
  `xsds_tb_nes.sv`, `xsds_tb_saturn.sv` — bring-up testbenches. The `_shim`
  one drives synthetic stim; the others drive real MiSTer-core SDRAM
  controllers (pulled into `ref/MiSTer SDRAM Controller Modules/`) against
  the chip model. Saturn is the first CL=3 target; the rest are CL=2.
- `verilator/` — Verilator-specific Makefile + lint stub +
  `altddio_out_stub.sv` (sim-only stand-in for the Altera vendor IP MiSTer
  cores use to derive `DRAM_CLK`).
- `CONTROLLER_GUIDE.md` — protocol/timing rules a controller must follow.
- `TASKS.md` — gap list and what's been landed so far.
- `CLAUDE.md` — internal architecture / design notes.
- `ref/` — datasheets, vendor BFM models, and the MiSTer controller corpus.

## Example instantiation

The wrapper port list matches the XSDS v3.0 40-pin connector exactly. CKE,
DQM, and the second chip-select are managed on the board (CKE tied to VCC,
DQM tied to `Addr[11]`/`Addr[12]`, `CS2 = ~CS1` via on-board inverter), so
the wrapper doesn't expose them — it synthesizes them internally.

```sv
xsds_128mbyte_sdram_model #(
    .DEBUG               (1'b0),
    .STRICT_TIMING       (1'b1),
    .WARN_TREFI          (1'b1),
    .INIT_UNWRITTEN_TO_X (1'b1)
) u_sdram_module (
    .Clk   (sdram_clk),

    // Connector pin P1.33. Acts as the high address bit:
    //   0 = lower 64 MB (chip 0), 1 = upper 64 MB (chip 1).
    // Drive {Ras_n, Cas_n, We_n} = 3'b111 (NOP) for idle cycles regardless
    // of Cs1_n; the hardware cannot deselect both chips.
    .Cs1_n (sdram_cs1_n),

    .Ras_n (sdram_ras_n),
    .Cas_n (sdram_cas_n),
    .We_n  (sdram_we_n),
    .Ba    (sdram_ba),

    // Addr[11] and Addr[12] also carry DQML / DQMH per board-level tie.
    .Addr  (sdram_addr[12:0]),

    .Dq    (sdram_dq)
);
```

For tied-low controllers (the corpus convention — `SDRAM_nCS = 0` always),
wrap the controller through `xsds_cs1_adapter` so the upper 64 MB stays
reachable via a separate `ctrl_chip` signal:

```sv
xsds_cs1_adapter u_adapter (
    .ctrl_cs_n  (ctrl_sdram_nCS),  // typically 1'b0
    .ctrl_ras_n (ctrl_sdram_nRAS),
    .ctrl_cas_n (ctrl_sdram_nCAS),
    .ctrl_we_n  (ctrl_sdram_nWE),
    .ctrl_ba    (ctrl_sdram_BA),
    .ctrl_addr  (ctrl_sdram_A),

    // 0 = lower 64 MB, 1 = upper 64 MB. Tie to 1'b0 if the controller
    // is unmodified and you only need the lower 64 MB.
    .ctrl_chip  (ctrl_chip_select),

    .xsds_cs1_n (sdram_cs1_n),
    .xsds_ras_n (sdram_ras_n),
    .xsds_cas_n (sdram_cas_n),
    .xsds_we_n  (sdram_we_n),
    .xsds_ba    (sdram_ba),
    .xsds_addr  (sdram_addr)
);
```

DQ is wired directly between the controller and the wrapper — the adapter
only mediates the command bus.

## Running under Verilator

A small Makefile in `verilator/` exposes:

| target | description |
|--------|-------------|
| `make -C verilator lint`    | lint the model under Verilator (no warnings, no errors) |
| `make -C verilator smoke`   | build & run the synthetic-stim adapter+chip TB |
| `make -C verilator memtest` | build & run `MemTest_MiSTer`'s SDRAM controller against the chip model |
| `make -C verilator neogeo`  | build & run `NeoGeo_MiSTer`'s SDRAM controller (the load-bearing case for chip-2 coverage) |
| `make -C verilator nes`     | build & run `NES_MiSTer`'s SDRAM controller through the adapter |
| `make -C verilator saturn`  | build & run `Saturn_MiSTer`'s SDRAM controller (first CL=3 bring-up) |

All four pass clean as of this writing. Verilator-side caveats: tristate at
top-level ports is unsupported (the smoke / bring-up TBs hide DQ inside
the top), and the `--timing` + `--bbox-unsup` flags are needed (already
wired up in the Makefile). Commercial simulators (ModelSim / Questa /
VCS / Xcelium) handle the SystemVerilog model directly without these
workarounds.

For the protocol/timing rules a controller must follow, see
`CONTROLLER_GUIDE.md`.
