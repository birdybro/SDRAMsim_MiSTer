# SDRAMsim_MiSTer
SDRAM simulator for MiSTer FPGA (wip)

## Example instantiation

```sv
xsds_128mbyte_sdram_model #(
    .DEBUG(1'b0),
    .STRICT_TIMING(1'b1),
    .CHIPSEL_ACTIVE_FOR_CHIP1(1'b1)
) u_sdram_module (
    .Clk     (sdram_clk),
    .Cke     (sdram_cke),
    .Cs_n    (sdram_cs_n),

    // Connect this to the schematic/controller signal that selects the
    // lower/upper 64 MB physical SDRAM chip.
    .ChipSel (sdram_chip_sel),

    .Ras_n   (sdram_ras_n),
    .Cas_n   (sdram_cas_n),
    .We_n    (sdram_we_n),
    .Ba      (sdram_ba),
    .Addr    (sdram_addr[12:0]),
    .Ldqm    (sdram_ldqm),
    .Udqm    (sdram_udqm),
    .Dq      (sdram_dq)
);
```
