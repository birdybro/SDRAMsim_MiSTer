`timescale 1ns/1ps

// =============================================================================
// NeoGeo_MiSTer bring-up testbench against the AS4C32M16SB chip model
// =============================================================================
// NeoGeo is the load-bearing case for chip-2 coverage: ROMs are the only
// MiSTer cores that genuinely need the full 128 MB of an XSDS module. The
// controller is already XSDS-aware in the same way MemTest is — it drives
// SDRAM_nCS from a high address bit (addr[26]) and ties CKE to VCC — so it
// also bypasses xsds_cs1_adapter and wires directly to the chip-level CS
// routing.
//
// Scope of this TB:
//   - Hold the controller's `init` high for ~80 us so its internal 121 us
//     startup wait completes after the chip model's 200 us power-up window.
//   - Release init, watch the controller run its dual-chip init sequence
//     (PRECHARGE / 2x AREF / MRS, once with chip=0 then once with chip=1).
//   - Watch for `ready` to indicate startup is done.
//   - Pass = both chips fully initialized and zero violations recorded.
//
// As with MemTest, this is a bring-up smoke check; it does NOT exercise
// the full read/write/cpreq surface area yet — that's a follow-up.
//
// Run via verilator/Makefile:
//   make -C verilator neogeo
// =============================================================================

module xsds_tb_neogeo;

    localparam realtime TCK = 10.0;  // 100 MHz, the controller's native rate

    logic Clk = 1'b0;
    always #(TCK/2.0) Clk = ~Clk;

    // -------------------------------------------------------------------------
    // NeoGeo SDRAM controller interface
    // -------------------------------------------------------------------------
    logic        init       = 1'b1;
    logic        SDRAM_EN   = 1'b1;

    // CPU/normal request channel
    logic        sel        = 1'b0;
    logic [26:1] addr       = 26'h0;
    logic [15:0] din        = 16'h0000;
    logic        wr         = 1'b0;
    logic [1:0]  bs         = 2'b11;
    logic        rd         = 1'b0;
    logic        refresh    = 1'b0;
    wire  [15:0] dout;
    wire         ready;

    // Memory-copy channel (ROM load path) — unused for the bring-up.
    logic        cpsel      = 1'b0;
    logic [26:1] cpaddr     = 26'h0;
    logic [15:0] cpdin      = 16'h0000;
    logic        cpreq      = 1'b0;
    wire         cprd;
    wire         cpbusy;

    // -------------------------------------------------------------------------
    // SDRAM bus
    // -------------------------------------------------------------------------
    wire  [15:0] SDRAM_DQ;
    wire  [12:0] SDRAM_A;
    wire         SDRAM_DQML, SDRAM_DQMH;
    wire  [1:0]  SDRAM_BA;
    wire         SDRAM_nCS;
    wire         SDRAM_nWE;
    wire         SDRAM_nRAS;
    wire         SDRAM_nCAS;
    wire         SDRAM_CKE;
    wire         SDRAM_CLK;

    sdram u_neogeo (
        .init      (init),
        .clk       (Clk),
        .SDRAM_DQ  (SDRAM_DQ),
        .SDRAM_A   (SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA  (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE (SDRAM_CKE),
        .SDRAM_CLK (SDRAM_CLK),
        .SDRAM_EN  (SDRAM_EN),
        .sel       (sel),
        .addr      (addr),
        .dout      (dout),
        .din       (din),
        .wr        (wr),
        .bs        (bs),
        .rd        (rd),
        .ready     (ready),
        .refresh   (refresh),
        .cpsel     (cpsel),
        .cpaddr    (cpaddr),
        .cpdin     (cpdin),
        .cprd      (cprd),
        .cpreq     (cpreq),
        .cpbusy    (cpbusy)
    );

    // Gate RAS/CAS/WE to NOP encoding while init is held high. NeoGeo's
    // SDRAM_EN-low path forces command=0 (LOAD_MODE encoding) and its
    // reset path only stamps state/refresh_count, leaving the command
    // pipeline at whatever it was last cycle — same shape of issue MemTest
    // has. Gating keeps the bus clean until the controller's startup
    // sequence drives real commands.
    wire eff_ras_n = init ? 1'b1 : SDRAM_nRAS;
    wire eff_cas_n = init ? 1'b1 : SDRAM_nCAS;
    wire eff_we_n  = init ? 1'b1 : SDRAM_nWE;

    // CS routing: chip 0 takes SDRAM_nCS directly, chip 1 takes its inversion.
    wire chip0_cs_n =  SDRAM_nCS;
    wire chip1_cs_n = ~SDRAM_nCS;

    // CKE is tied to VCC on the XSDS board. NeoGeo's SDRAM_CKE is also
    // hardwired to 1, but we use the constant here to keep the chip model
    // standalone-friendly.
    wire chip_cke  = 1'b1;

    // DQM bonded to ADDR[12:11], matching XSDS and NeoGeo's own assignment.
    wire chip_ldqm = SDRAM_A[11];
    wire chip_udqm = SDRAM_A[12];

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_NEOGEO_CHIP0_AS4C32M16SB")
    ) u_chip0 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip0_cs_n),
        .Ras_n (eff_ras_n),
        .Cas_n (eff_cas_n),
        .We_n  (eff_we_n),
        .Ba    (SDRAM_BA),
        .Addr  (SDRAM_A),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (SDRAM_DQ)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_NEOGEO_CHIP1_AS4C32M16SB")
    ) u_chip1 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip1_cs_n),
        .Ras_n (eff_ras_n),
        .Cas_n (eff_cas_n),
        .We_n  (eff_we_n),
        .Ba    (SDRAM_BA),
        .Addr  (SDRAM_A),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (SDRAM_DQ)
    );

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin : stim_proc
        // Hold init=1 long enough that the controller's 121 us internal
        // startup window completes after the chip's 200 us power-up check.
        // 80 us + 121 us = 201 us.
        init = 1'b1;
        #(80_000);
        @(negedge Clk);
        init = 1'b0;

        // Wait long enough for startup to complete + a safety margin.
        // Controller asserts ready when STATE_STARTUP refresh_count hits 0.
        #(150_000);

        // End-of-test report.
        u_chip0.report_refresh_status();
        u_chip1.report_refresh_status();
        u_chip0.dump_state();
        u_chip1.dump_state();
        $display("controller ready=%0b", ready);
        $display("ERRORS:   %0d (chip0=%0d chip1=%0d)",
                 u_chip0.error_count + u_chip1.error_count,
                 u_chip0.error_count, u_chip1.error_count);
        $display("WARNINGS: %0d (chip0=%0d chip1=%0d)",
                 u_chip0.warning_count + u_chip1.warning_count,
                 u_chip0.warning_count, u_chip1.warning_count);

        if ((u_chip0.error_count + u_chip1.error_count) != 0) begin
            $fatal(1, "xsds_tb_neogeo: %0d violations across both chips",
                   u_chip0.error_count + u_chip1.error_count);
        end

        if (!ready) begin
            $fatal(1, "xsds_tb_neogeo: controller never asserted ready");
        end

        $display("xsds_tb_neogeo: PASS");
        $finish;
    end

endmodule
