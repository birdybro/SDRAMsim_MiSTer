`timescale 1ns/1ps

// =============================================================================
// MemTest_MiSTer bring-up testbench against the AS4C32M16SB chip model
// =============================================================================
// First bring-up target in the sequence agreed in MEMORY: MemTest is the
// deliberate characterization tool with minimal abstraction and is in fact
// already XSDS-native:
//
//   - DRAM_CS_N is driven from the high address bit (addr[23]), so commands
//     route to chip 0 (CS=0) or chip 1 (CS=1) based on the sweep address.
//   - DQM is bonded to ADDR[12:11] just like the XSDS schematic.
//   - Distributed refresh alternates CS so both chips get AUTO REFRESH.
//
// As a result MemTest does NOT use xsds_cs1_adapter (which would force NOP
// encoding whenever DRAM_CS_N=1 and suppress every command bound for chip 1).
// MemTest's DRAM_CS_N wires directly to the chip-level CS routing instead.
//
// Scope of this TB:
//   - Hold rst_n through the 200 us power-up window the chip model enforces.
//   - Release rst_n and let MemTest run its init sequence on both chips.
//   - Let it sweep for ~50 us beyond init (a few dozen word transactions),
//     then $finish and report violation counts.
//   - Pass = zero violations across both chips.
//
// This is a sanity / lint-bringup check, not a full functional sweep — the
// full sweep at sz=0 chip=0 is 4M word transactions and would take many
// minutes of wall time at TCK = 10 ns. Once this passes we can extend.
//
// Run via verilator/Makefile:
//   make -C verilator memtest
// =============================================================================

module xsds_tb_memtest;

    localparam realtime TCK = 10.0;

    logic Clk = 1'b0;
    always #(TCK/2.0) Clk = ~Clk;

    // -------------------------------------------------------------------------
    // MemTest interface
    // -------------------------------------------------------------------------
    logic        rst_n = 1'b0;
    logic        start = 1'b0;
    logic        rnw   = 1'b0;
    logic [15:0] wdat  = 16'h0000;
    logic [1:0]  sz    = 2'd0;
    logic [1:0]  chip  = 2'd0;

    wire         done;
    wire         ready;
    wire  [15:0] rdat;

    // -------------------------------------------------------------------------
    // SDRAM bus (shared between MemTest's outputs and the chip models)
    // -------------------------------------------------------------------------
    wire        DRAM_CLK;
    wire        DRAM_LDQM, DRAM_UDQM;  // unused — chip uses ADDR[12:11] directly
    wire        DRAM_WE_N;
    wire        DRAM_CAS_N;
    wire        DRAM_RAS_N;
    wire        DRAM_CS_N;
    wire        DRAM_BA_0, DRAM_BA_1;
    wire [12:0] DRAM_ADDR;
    wire [15:0] DRAM_DQ;

    // MemTest's controller.
    sdram u_memtest (
        .clk      (Clk),
        .rst_n    (rst_n),
        .start    (start),
        .done     (done),
        .rnw      (rnw),
        .ready    (ready),
        .wdat     (wdat),
        .rdat     (rdat),
        .sz       (sz),
        .chip     (chip),
        .DRAM_CLK (DRAM_CLK),
        .DRAM_LDQM(DRAM_LDQM),
        .DRAM_UDQM(DRAM_UDQM),
        .DRAM_WE_N(DRAM_WE_N),
        .DRAM_CAS_N(DRAM_CAS_N),
        .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_CS_N(DRAM_CS_N),
        .DRAM_BA_0(DRAM_BA_0),
        .DRAM_BA_1(DRAM_BA_1),
        .DRAM_DQ  (DRAM_DQ),
        .DRAM_ADDR(DRAM_ADDR)
    );

    // MemTest does not reset its cmd / cs / sdaddr pipeline in the rst_n
    // block — only initstate and init_done. At the very first posedge the
    // cmd register is at its initial value (0 in Verilator 2-state mode),
    // which decodes as CMD_LOAD_MODE and would trip the chip's 200 us
    // power-up check. Gate the command bus to NOP encoding while rst_n is
    // low so the chip sees a clean idle bus until MemTest's pipeline has
    // settled and the power-up window has elapsed.
    wire eff_ras_n = rst_n ? DRAM_RAS_N : 1'b1;
    wire eff_cas_n = rst_n ? DRAM_CAS_N : 1'b1;
    wire eff_we_n  = rst_n ? DRAM_WE_N  : 1'b1;

    // CS routing: chip 0 takes DRAM_CS_N directly, chip 1 takes the
    // inverted DRAM_CS_N — same pattern as the wrapper's LVC1G04 inverter.
    // CS value doesn't matter during reset because the gated RAS/CAS/WE
    // above force NOP regardless of which chip is "selected".
    wire chip0_cs_n =  DRAM_CS_N;
    wire chip1_cs_n = ~DRAM_CS_N;

    // DQM bonded to ADDR[12:11], matching XSDS board and MemTest's own
    // assignment. CKE tied high (XSDS connector convention).
    wire chip_cke  = 1'b1;
    wire chip_ldqm = DRAM_ADDR[11];
    wire chip_udqm = DRAM_ADDR[12];

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_MEMTEST_CHIP0_AS4C32M16SB")
    ) u_chip0 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip0_cs_n),
        .Ras_n (eff_ras_n),
        .Cas_n (eff_cas_n),
        .We_n  (eff_we_n),
        .Ba    ({DRAM_BA_1, DRAM_BA_0}),
        .Addr  (DRAM_ADDR),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (DRAM_DQ)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_MEMTEST_CHIP1_AS4C32M16SB")
    ) u_chip1 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip1_cs_n),
        .Ras_n (eff_ras_n),
        .Cas_n (eff_cas_n),
        .We_n  (eff_we_n),
        .Ba    ({DRAM_BA_1, DRAM_BA_0}),
        .Addr  (DRAM_ADDR),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (DRAM_DQ)
    );

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin : stim_proc
        // Hold reset through the 200 us power-up window. The chip model
        // errors on any non-NOP command before $realtime >= 200 us.
        rst_n = 1'b0;
        #(200_000);
        @(negedge Clk);
        rst_n = 1'b1;

        // Let MemTest init both chips and start sweeping. ~50 us is many
        // dozens of word transactions — enough to exercise refresh and
        // both chip-select states without taking minutes of wall time.
        #(50_000);

        // End-of-test report. The pass criterion is zero recorded
        // violations on either chip.
        u_chip0.report_refresh_status();
        u_chip1.report_refresh_status();
        u_chip0.dump_state();
        u_chip1.dump_state();
        $display("ERRORS:   %0d (chip0=%0d chip1=%0d)",
                 u_chip0.error_count + u_chip1.error_count,
                 u_chip0.error_count, u_chip1.error_count);
        $display("WARNINGS: %0d (chip0=%0d chip1=%0d)",
                 u_chip0.warning_count + u_chip1.warning_count,
                 u_chip0.warning_count, u_chip1.warning_count);

        if ((u_chip0.error_count + u_chip1.error_count) != 0) begin
            $fatal(1, "xsds_tb_memtest: %0d violations across both chips",
                   u_chip0.error_count + u_chip1.error_count);
        end

        $display("xsds_tb_memtest: PASS");
        $finish;
    end

endmodule
