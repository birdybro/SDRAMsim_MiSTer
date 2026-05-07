# SDRAMsim_MiSTer
SDRAM simulator for MiSTer FPGA (wip)

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

For the protocol/timing rules a controller must follow, see
`CONTROLLER_GUIDE.md`.
