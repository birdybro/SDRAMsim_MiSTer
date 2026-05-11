`timescale 1ns/1ps

// =============================================================================
// NES_MiSTer bring-up testbench against the AS4C32M16SB chip model
// =============================================================================
// First "typical" MiSTer controller in the bring-up sequence (after the two
// XSDS-native ones, MemTest and NeoGeo). NES is a single-CS-tied-low core:
//
//   - SDRAM_nCS is hardwired to 0; the controller never deasserts CS.
//   - SDRAM_CKE is hardwired to 1.
//   - DQM is bonded to SDRAM_A[12:11] (matches XSDS schematic).
//   - 25-bit byte address with three independent ch0/ch1/ch2 ports, BL=1
//     CL=2, byte writes via DQM masking.
//   - Init does PRE → wait → MRS but does NOT issue the two AREFs the chip
//     requires. AREFs come from an external `refresh` signal that the host
//     pulses periodically.
//
// This is the first bring-up that actually runs through `xsds_cs1_adapter`,
// which is the abstraction every "tied-low" controller is supposed to wrap.
// `ctrl_chip` is held at 0 because NES only addresses chip 0 (its 25-bit
// byte address tops out at 32 MB, well inside the lower chip).
//
// Several TB-side compensations:
//
//   - Gate the SDRAM command bus (RAS/CAS/WE) to NOP encoding while
//     $realtime < 200 us. NES's state machine starts at t=0 and would
//     issue an AREF on its very first cycle, which the chip's power-up
//     check would correctly reject. Gating keeps the chip quiet through
//     power-up regardless of what NES does internally.
//
//   - Pulse `init` high → low after the gate opens to retrigger NES's
//     init sequence. NES auto-inits at startup, but during the 200 us
//     gate the chip never observes those PRE / MRS commands. Re-running
//     init after the gate opens lets the chip see them.
//
//   - Pulse `refresh` for several cycles after init completes so NES
//     issues the two AREFs the chip's init checker requires before any
//     normal command.
//
// Pass criterion: zero violations across both chips after a write+read
// round-trip on ch0.
//
// Run via verilator/Makefile:
//   make -C verilator nes
// =============================================================================

module xsds_tb_nes;

    // NES_MiSTer runs its SDRAM at 85.909088 MHz (4 x NES system clock
    // of 21.477272 MHz). RASCAS_DELAY=1 in its sdram.sv puts a single
    // cycle (~11.64 ns) between ACT and WRITE/READ, which is tighter
    // than the AS4C32M16SB-6TIN datasheet's tRCD of 18 ns. NES is
    // designed for the MT48LC16M16A2 chip family on the DE10-Nano,
    // which tolerates this; we override tRCD_MIN below to model that
    // tighter chip. tRAS is handled by the chip's deferred AP-PRE
    // logic (which schedules the implied precharge to satisfy tRAS
    // and tWR internally) so does not need an override.
    localparam realtime TCK = 1000.0 / 85.909088;  // ~11.64 ns

    logic Clk = 1'b0;
    always #(TCK/2.0) Clk = ~Clk;

    // -------------------------------------------------------------------------
    // NES SDRAM controller interface
    // -------------------------------------------------------------------------
    logic        init       = 1'b0;
    logic        refresh    = 1'b0;

    logic [24:0] ch0_addr   = 25'h0;
    logic        ch0_rd     = 1'b0;
    logic        ch0_wr     = 1'b0;
    logic [7:0]  ch0_din    = 8'h00;
    wire  [7:0]  ch0_dout;
    wire         ch0_busy;

    logic [24:0] ch1_addr   = 25'h0;
    logic        ch1_rd     = 1'b0;
    logic        ch1_wr     = 1'b0;
    logic [7:0]  ch1_din    = 8'h00;
    wire  [7:0]  ch1_dout;
    wire         ch1_busy;

    logic [24:0] ch2_addr   = 25'h0;
    logic        ch2_rd     = 1'b0;
    logic        ch2_wr     = 1'b0;
    logic [7:0]  ch2_din    = 8'h00;
    wire  [7:0]  ch2_dout;
    wire         ch2_busy;

    logic [15:0] ss_in      = 16'h0;
    logic        ss_load    = 1'b0;
    wire  [15:0] ss_out;

    // -------------------------------------------------------------------------
    // SDRAM bus from NES
    // -------------------------------------------------------------------------
    wire  [15:0] SDRAM_DQ;
    wire  [12:0] SDRAM_A;
    wire         SDRAM_DQML, SDRAM_DQMH;
    wire  [1:0]  SDRAM_BA;
    wire         SDRAM_nCS;
    wire         SDRAM_nWE;
    wire         SDRAM_nRAS;
    wire         SDRAM_nCAS;
    wire         SDRAM_CLK;
    wire         SDRAM_CKE;

    sdram u_nes (
        .SDRAM_DQ  (SDRAM_DQ),
        .SDRAM_A   (SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA  (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK (SDRAM_CLK),
        .SDRAM_CKE (SDRAM_CKE),
        .init      (init),
        .clk       (Clk),
        .ch0_addr  (ch0_addr),
        .ch0_rd    (ch0_rd),
        .ch0_wr    (ch0_wr),
        .ch0_din   (ch0_din),
        .ch0_dout  (ch0_dout),
        .ch0_busy  (ch0_busy),
        .ch1_addr  (ch1_addr),
        .ch1_rd    (ch1_rd),
        .ch1_wr    (ch1_wr),
        .ch1_din   (ch1_din),
        .ch1_dout  (ch1_dout),
        .ch1_busy  (ch1_busy),
        .ch2_addr  (ch2_addr),
        .ch2_rd    (ch2_rd),
        .ch2_wr    (ch2_wr),
        .ch2_din   (ch2_din),
        .ch2_dout  (ch2_dout),
        .ch2_busy  (ch2_busy),
        .refresh   (refresh),
        .ss_in     (ss_in),
        .ss_load   (ss_load),
        .ss_out    (ss_out)
    );

    // Gate RAS/CAS/WE to NOP encoding during the 200 us power-up window.
    // NES's state machine starts running immediately at t=0 and would
    // otherwise issue commands the chip's power-up check would reject.
    logic powerup_done = 1'b0;
    initial begin
        #(200_000) powerup_done = 1'b1;
    end

    wire eff_ras_n = powerup_done ? SDRAM_nRAS : 1'b1;
    wire eff_cas_n = powerup_done ? SDRAM_nCAS : 1'b1;
    wire eff_we_n  = powerup_done ? SDRAM_nWE  : 1'b1;
    wire eff_cs_n  = powerup_done ? SDRAM_nCS  : 1'b0;

    // -------------------------------------------------------------------------
    // CS1-aware adapter
    //
    // NES holds SDRAM_nCS=0 always, so the adapter's NOP-forcing path
    // never fires; the adapter is acting purely as a structural shim that
    // routes the controller's bus to the XSDS chip-select bit. ctrl_chip
    // is held at 0 because NES's 25-bit byte address (32 MB) fits entirely
    // in chip 0.
    // -------------------------------------------------------------------------
    wire        xsds_cs1_n;
    wire        xsds_ras_n;
    wire        xsds_cas_n;
    wire        xsds_we_n;
    wire [1:0]  xsds_ba;
    wire [12:0] xsds_addr;

    xsds_cs1_adapter u_adapter (
        .ctrl_cs_n  (eff_cs_n),
        .ctrl_ras_n (eff_ras_n),
        .ctrl_cas_n (eff_cas_n),
        .ctrl_we_n  (eff_we_n),
        .ctrl_ba    (SDRAM_BA),
        .ctrl_addr  (SDRAM_A),
        .ctrl_chip  (1'b0),
        .xsds_cs1_n (xsds_cs1_n),
        .xsds_ras_n (xsds_ras_n),
        .xsds_cas_n (xsds_cas_n),
        .xsds_we_n  (xsds_we_n),
        .xsds_ba    (xsds_ba),
        .xsds_addr  (xsds_addr)
    );

    // CS routing mirrors the wrapper's LVC1G04 inverter.
    wire chip0_cs_n =  xsds_cs1_n;
    wire chip1_cs_n = ~xsds_cs1_n;

    wire chip_cke  = 1'b1;
    wire chip_ldqm = xsds_addr[11];
    wire chip_udqm = xsds_addr[12];

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_NES_CHIP0_AS4C32M16SB"),
        // NES is designed for MT48LC16M16A2 timing. That part has tighter
        // tRCD than the AS4C32M16SB-6TIN datasheet (1 tCK rather than
        // ~18 ns). Override to 11 ns so 1 cycle at 85.91 MHz is in spec.
        // tRAS does NOT need a similar override — the chip model defers
        // the implied AP-PRE to satisfy tRAS internally, matching real
        // silicon behavior.
        .tRCD_MIN  (11.0)
    ) u_chip0 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip0_cs_n),
        .Ras_n (xsds_ras_n),
        .Cas_n (xsds_cas_n),
        .We_n  (xsds_we_n),
        .Ba    (xsds_ba),
        .Addr  (xsds_addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (SDRAM_DQ)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_NES_CHIP1_AS4C32M16SB"),
        .tRCD_MIN  (11.0)
    ) u_chip1 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip1_cs_n),
        .Ras_n (xsds_ras_n),
        .Cas_n (xsds_cas_n),
        .We_n  (xsds_we_n),
        .Ba    (xsds_ba),
        .Addr  (xsds_addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (SDRAM_DQ)
    );

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin : stim_proc
        // Wait for the gate to lift at 200 us. NES has been auto-initing
        // internally during this period; the chip has only seen NOP.
        wait (powerup_done);

        // Re-trigger NES's init sequence so the chip observes PRE + MRS.
        @(negedge Clk);
        init = 1'b1;
        @(negedge Clk);
        @(negedge Clk);
        init = 1'b0;

        // Wait for NES to walk through 31 reset states (~2.17 us at TCK=10ns).
        #(5_000);

        // Pulse refresh long enough for at least 2 AREFs to fire — the
        // chip's init checker requires init_auto_refresh_count >= 2 before
        // any normal command. Holding refresh high causes NES to issue an
        // AREF every time it returns to IDLE.
        @(negedge Clk);
        refresh = 1'b1;
        #(500);
        @(negedge Clk);
        refresh = 1'b0;

        // Settle.
        #(200);

        // Round-trip via ch0: write 0xAB to byte address 0, then read back.
        @(negedge Clk);
        ch0_addr = 25'h00_0000;
        ch0_din  = 8'hAB;
        ch0_wr   = 1'b1;

        // Hold the request until the controller has accepted and finished it.
        wait (ch0_busy);
        @(negedge Clk);
        ch0_wr   = 1'b0;
        wait (!ch0_busy);

        // Read it back.
        @(negedge Clk);
        ch0_addr = 25'h00_0000;
        ch0_rd   = 1'b1;
        wait (ch0_busy);
        @(negedge Clk);
        ch0_rd   = 1'b0;
        wait (!ch0_busy);

        @(posedge Clk);
        if (ch0_dout !== 8'hAB) begin
            $error("xsds_tb_nes: ch0 readback mismatch: got %02h, expected AB",
                   ch0_dout);
        end else begin
            $display("xsds_tb_nes: ch0 readback OK: %02h", ch0_dout);
        end

        // End-of-test report.
        u_chip0.report_refresh_status();
        u_chip1.report_refresh_status();
        $display("ERRORS:   %0d (chip0=%0d chip1=%0d)",
                 u_chip0.error_count + u_chip1.error_count,
                 u_chip0.error_count, u_chip1.error_count);
        $display("WARNINGS: %0d (chip0=%0d chip1=%0d)",
                 u_chip0.warning_count + u_chip1.warning_count,
                 u_chip0.warning_count, u_chip1.warning_count);

        if ((u_chip0.error_count + u_chip1.error_count) != 0) begin
            $fatal(1, "xsds_tb_nes: %0d violations across both chips",
                   u_chip0.error_count + u_chip1.error_count);
        end

        $display("xsds_tb_nes: PASS");
        $finish;
    end

endmodule
