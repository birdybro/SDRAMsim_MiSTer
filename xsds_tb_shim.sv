`timescale 1ns/1ps

// =============================================================================
// XSDS testbench shim
// =============================================================================
// Self-contained smoke test that wires the CS1-aware adapter to two
// AS4C32M16SB chip-model instances and exercises a minimal init / write /
// read / refresh sequence on BOTH physical chips. Serves two purposes:
//
//   1. Sanity check: confirms the chip model + adapter pair is internally
//      consistent end-to-end before a real controller is plugged in. Pass
//      criterion: every readback matches and zero violations are recorded.
//
//   2. Starting template: shows the wiring pattern (clock, reset wait,
//      adapter instantiation, DQ shared tristate, end-of-test reporting)
//      that a real-controller bring-up should follow.
//
// About the wrapper: the production interface is
// `xsds_128mbyte_sdram_model`, which exposes the 40-pin XSDS connector and
// internally instantiates the same two chips this TB uses. Verilator does
// not currently support the wrapper's inout pass-through under simulation
// (it works fine for lint with --bbox-unsup), so this TB instantiates the
// chips directly with the same CS-inverter pattern the wrapper applies.
// Commercial simulators (ModelSim / Questa / VCS / Xcelium) can drive the
// wrapper directly using the same adapter + stim pattern below.
//
// Bring-up target order (memory notes):
//   MemTest_MiSTer first, then a BL=1 CL=2 console core (NES or Genesis),
//   then a full-page burst core (Saturn or MegaCD), then jtframe_sdram.
//   NeoGeo is the load-bearing case for the adapter once it's available
//   in the corpus.
//
// Run under Verilator (see verilator/Makefile smoke target).
//
// Simulation-only.
// =============================================================================

module xsds_tb_shim;

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    // 10 ns period -> 100 MHz, well within the -6TIN grade's tCK_CL3_MIN of
    // 6 ns and tCK_CL2_MIN of 10 ns.
    localparam realtime TCK = 10.0;

    logic Clk = 1'b0;
    always #(TCK/2.0) Clk = ~Clk;

    // -------------------------------------------------------------------------
    // Controller-side stimulus bus (the testbench drives these directly here;
    // in a real bring-up these would be driven by the DUT controller).
    // -------------------------------------------------------------------------
    // Initialize at declaration so the chip's X-prop check doesn't trip on
    // the first posedge before the stim_proc initial block has run.
    logic        ctrl_cs_n   = 1'b0;
    logic        ctrl_ras_n  = 1'b1;
    logic        ctrl_cas_n  = 1'b1;
    logic        ctrl_we_n   = 1'b1;
    logic [1:0]  ctrl_ba     = 2'b00;
    logic [12:0] ctrl_addr   = 13'h0000;
    logic        ctrl_chip   = 1'b0;

    // DQ is a shared tristate bus. The model drives it on reads, the TB
    // drives it on writes, both go Hi-Z otherwise.
    wire  [15:0] Dq;
    logic [15:0] tb_dq_drive = 16'h0000;
    logic        tb_dq_oe    = 1'b0;
    assign Dq = tb_dq_oe ? tb_dq_drive : 16'hzzzz;

    // -------------------------------------------------------------------------
    // Adapter + model
    // -------------------------------------------------------------------------
    wire        xsds_cs1_n;
    wire        xsds_ras_n;
    wire        xsds_cas_n;
    wire        xsds_we_n;
    wire [1:0]  xsds_ba;
    wire [12:0] xsds_addr;

    xsds_cs1_adapter u_adapter (
        .ctrl_cs_n  (ctrl_cs_n),
        .ctrl_ras_n (ctrl_ras_n),
        .ctrl_cas_n (ctrl_cas_n),
        .ctrl_we_n  (ctrl_we_n),
        .ctrl_ba    (ctrl_ba),
        .ctrl_addr  (ctrl_addr),
        .ctrl_chip  (ctrl_chip),
        .xsds_cs1_n (xsds_cs1_n),
        .xsds_ras_n (xsds_ras_n),
        .xsds_cas_n (xsds_cas_n),
        .xsds_we_n  (xsds_we_n),
        .xsds_ba    (xsds_ba),
        .xsds_addr  (xsds_addr)
    );

    // CS routing mirrors the wrapper: chip 0 takes Cs1_n directly, chip 1
    // takes the inverted Cs1_n. DQM is bonded to Addr[11] / Addr[12] just
    // like the XSDS schematic does. CKE is tied to VCC.
    wire chip_cke  = 1'b1;
    wire chip_ldqm = xsds_addr[11];
    wire chip_udqm = xsds_addr[12];
    wire chip0_cs_n =  xsds_cs1_n;
    wire chip1_cs_n = ~xsds_cs1_n;

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_CHIP0_AS4C32M16SB")
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
        .Dq    (Dq)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_CHIP1_AS4C32M16SB")
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
        .Dq    (Dq)
    );

    // -------------------------------------------------------------------------
    // SDRAM command encodings (RAS/CAS/WE pattern, with CS=0 implicit)
    // -------------------------------------------------------------------------
    localparam logic [2:0] CMD_NOP  = 3'b111;
    localparam logic [2:0] CMD_ACT  = 3'b011;
    localparam logic [2:0] CMD_READ = 3'b101;
    localparam logic [2:0] CMD_WRIT = 3'b100;
    localparam logic [2:0] CMD_PRE  = 3'b010;
    localparam logic [2:0] CMD_AREF = 3'b001;
    localparam logic [2:0] CMD_MRS  = 3'b000;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic idle_for(input int n);
        begin
            for (int i = 0; i < n; i++) @(posedge Clk);
        end
    endtask

    task automatic drive_idle();
        begin
            ctrl_cs_n  = 1'b0;
            ctrl_ras_n = 1'b1;
            ctrl_cas_n = 1'b1;
            ctrl_we_n  = 1'b1;
            ctrl_ba    = 2'b00;
            ctrl_addr  = 13'h0000;
            tb_dq_oe   = 1'b0;
        end
    endtask

    // Drive a single-cycle command onto the bus. Signals are set on the
    // negedge so they are stable when the chip samples on the next posedge.
    // Consumes two negedges: one to drive the command, one to restore NOP
    // afterwards so subsequent idle_for() cycles do not re-fire it.
    task automatic issue_cmd(
        input logic [2:0]  cmd,
        input logic [1:0]  ba,
        input logic [12:0] addr
    );
        begin
            @(negedge Clk);
            ctrl_cs_n  = 1'b0;
            ctrl_ras_n = cmd[2];
            ctrl_cas_n = cmd[1];
            ctrl_we_n  = cmd[0];
            ctrl_ba    = ba;
            ctrl_addr  = addr;

            @(negedge Clk);
            // Chip has sampled the command on the posedge between the two
            // negedges. Restore NOP encoding for the next posedge.
            ctrl_ras_n = 1'b1;
            ctrl_cas_n = 1'b1;
            ctrl_we_n  = 1'b1;
        end
    endtask

    // Power-up + per-chip init: 200 us stable -> PRECHARGE ALL -> 2x AUTO
    // REFRESH -> MRS. Run twice (chip=0 then chip=1) so both physical chips
    // see their own init sequence.
    task automatic init_chip(input bit chip);
        begin
            ctrl_chip = chip;

            // PRECHARGE ALL (A10=1)
            issue_cmd(CMD_PRE, 2'b00, 13'h0400);
            idle_for(2);
            drive_idle();

            // AUTO REFRESH x 2
            issue_cmd(CMD_AREF, 2'b00, 13'h0000);
            idle_for(6);
            drive_idle();
            issue_cmd(CMD_AREF, 2'b00, 13'h0000);
            idle_for(6);
            drive_idle();

            // MRS: BL=1 (A2:A0=000), sequential, CL=2 (A6:A4=010),
            // single-bit write (A9=0), reserved=0.
            issue_cmd(CMD_MRS, 2'b00, 13'h0020);
            idle_for(2);
            drive_idle();
        end
    endtask

    // ACT bank/row -> WRITE col with data -> PRECHARGE.
    task automatic write_word(
        input bit          chip,
        input logic [1:0]  ba,
        input logic [12:0] row,
        input logic [9:0]  col,
        input logic [15:0] data
    );
        begin
            ctrl_chip = chip;

            // ACT
            issue_cmd(CMD_ACT, ba, row);
            idle_for(2);  // tRCD

            // WRITE (A10=0 -> no auto-precharge). Drive Dq on the same cycle.
            @(negedge Clk);
            ctrl_cs_n   = 1'b0;
            ctrl_ras_n  = CMD_WRIT[2];
            ctrl_cas_n  = CMD_WRIT[1];
            ctrl_we_n   = CMD_WRIT[0];
            ctrl_ba     = ba;
            ctrl_addr   = {3'b000, col};
            tb_dq_drive = data;
            tb_dq_oe    = 1'b1;

            @(negedge Clk);
            // Chip has sampled the WRITE + Dq on the posedge between.
            ctrl_ras_n = 1'b1;
            ctrl_cas_n = 1'b1;
            ctrl_we_n  = 1'b1;
            tb_dq_oe   = 1'b0;

            idle_for(2);  // tWR

            // PRECHARGE this bank.
            issue_cmd(CMD_PRE, ba, 13'h0000);
            idle_for(2);  // tRP
        end
    endtask

    // ACT bank/row -> READ col -> capture data after CL=2 -> PRECHARGE.
    task automatic read_word(
        input  bit          chip,
        input  logic [1:0]  ba,
        input  logic [12:0] row,
        input  logic [9:0]  col,
        output logic [15:0] data
    );
        begin
            ctrl_chip = chip;

            issue_cmd(CMD_ACT, ba, row);
            idle_for(2);  // tRCD

            issue_cmd(CMD_READ, ba, {3'b000, col});

            // CL=2 means data appears on Dq tAC_MAX after the second posedge
            // following the READ sample. issue_cmd already passed through the
            // READ sample posedge, so advance two more posedges, then wait
            // past tAC_MAX (~5.4 ns) before sampling.
            @(posedge Clk);
            @(posedge Clk);
            #7;
            data = Dq;

            idle_for(1);

            issue_cmd(CMD_PRE, ba, 13'h0000);
            idle_for(2);  // tRP
        end
    endtask

    // Issue an AUTO REFRESH against a chip. Required by both chips on a
    // distributed-refresh schedule (tREFI = 7.8 us per chip).
    task automatic refresh_chip(input bit chip);
        begin
            ctrl_chip = chip;
            issue_cmd(CMD_AREF, 2'b00, 13'h0000);
            idle_for(6);
            drive_idle();
        end
    endtask

    // -------------------------------------------------------------------------
    // Smoke-test stimulus
    // -------------------------------------------------------------------------
    logic [15:0] readback;

    initial begin : stim_proc
        // Safe initial state for everything the TB drives.
        ctrl_cs_n   = 1'b0;
        ctrl_ras_n  = 1'b1;
        ctrl_cas_n  = 1'b1;
        ctrl_we_n   = 1'b1;
        ctrl_ba     = 2'b00;
        ctrl_addr   = 13'h0000;
        ctrl_chip   = 1'b0;
        tb_dq_drive = 16'h0000;
        tb_dq_oe    = 1'b0;

        // Power-up stable wait (chip model requires 200 us before any
        // normal commands; CKE is tied to VCC internally on the wrapper).
        #(200_000);

        // Init both chips.
        init_chip(1'b0);
        init_chip(1'b1);

        // A couple of distributed refreshes against each chip just to make
        // sure both refresh trackers tick.
        refresh_chip(1'b0);
        refresh_chip(1'b1);

        // Write + read on chip 0.
        write_word(1'b0, 2'b00, 13'h0001, 10'h003, 16'hCAFE);
        read_word (1'b0, 2'b00, 13'h0001, 10'h003, readback);
        if (readback !== 16'hCAFE) begin
            $error("chip0 readback mismatch: got %04h, expected CAFE", readback);
        end else begin
            $display("chip0 readback OK: %04h", readback);
        end

        // Write + read on chip 1 (the bit-25 territory the corpus never
        // touches without this adapter).
        write_word(1'b1, 2'b01, 13'h0007, 10'h012, 16'hBEEF);
        read_word (1'b1, 2'b01, 13'h0007, 10'h012, readback);
        if (readback !== 16'hBEEF) begin
            $error("chip1 readback mismatch: got %04h, expected BEEF", readback);
        end else begin
            $display("chip1 readback OK: %04h", readback);
        end

        // End-of-test report. Bypassing the wrapper means calling the
        // per-chip helpers directly. Sum violations across both chips.
        u_chip0.report_refresh_status();
        u_chip1.report_refresh_status();
        $display("ERRORS:   %0d (chip0=%0d chip1=%0d)",
                 u_chip0.error_count + u_chip1.error_count,
                 u_chip0.error_count, u_chip1.error_count);
        $display("WARNINGS: %0d (chip0=%0d chip1=%0d)",
                 u_chip0.warning_count + u_chip1.warning_count,
                 u_chip0.warning_count, u_chip1.warning_count);

        if ((u_chip0.error_count + u_chip1.error_count) != 0) begin
            $fatal(1, "xsds_tb_shim: model reported %0d violations",
                   u_chip0.error_count + u_chip1.error_count);
        end

        $display("xsds_tb_shim: PASS");
        $finish;
    end

endmodule
