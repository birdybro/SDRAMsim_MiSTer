`timescale 1ns/1ps

// =============================================================================
// PSX_MiSTer bring-up testbench against the AS4C32M16SB chip model
// =============================================================================
// First **BL=2** controller in the bring-up sequence (everything prior was
// either BL=1 — NES, Saturn — or BL=4 — MemTest, NeoGeo). PSX's mode register
// programs BURST_CODE=3'b001, and its read pipeline drains two 16-bit words
// per CAS through the shift-register `data_ready_delayN[]` arrays.
//
// PSX_MiSTer/rtl/sdram.sv is XSDS-native in the same way Saturn/NeoGeo/MemTest
// are:
//   - `assign SDRAM_nCS = chip;` where `chip <= addrN[26]` for each request,
//     so the controller drives the chip-select bit directly from the high
//     address bit. No xsds_cs1_adapter needed.
//   - `assign SDRAM_CKE = 1;` (CKE hardwired high internally).
//   - `assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];` (DQM already
//     bonded to A[12:11], matching the XSDS routing).
//   - CL=2, BL=2 sequential, NO_WRITE_BURST=1.
//   - At 100 MHz the controller's ACT→CAS spacing is 2 cycles = 20 ns,
//     comfortably above -6TIN's tRCD of 18 ns. No tRCD override needed.
//   - Init AREFs spaced 8 cycles = 80 ns apart, above tRFC=60 ns. No
//     tRFC override needed (unlike Saturn's init→normal transition).
//
// PSX uses a dual-clock-domain interface: `clk` is the 100 MHz SDRAM
// clock; `clk_base` is a 33.33 MHz (clk/3) "system" clock used for the
// request handshakes (`chN_ready` is registered in clk_base). The TB
// generates both.
//
// PSX has three request channels:
//   - ch1: 128-bit reads / 16-bit writes (CPU, with DMA + cache variants).
//   - ch2: 32-bit reads / writes with byte enables.
//   - ch3: 32-bit reads / writes with byte enables.
//
// ch3 is used for the round-trip — simplest 32-bit path, no DMA/cache
// state-machine coupling. Address layout: `chN_addr[26]` = chip select,
// `chN_addr[25:1]` = bank + row + column word, `chN_addr[0]` = 0 for
// 32-bit access (per the controller's port doc).
//
// Scope of this TB:
//   - 200 us power-up gate forcing RAS/CAS/WE to NOP encoding.
//   - Hold `init=1` through the gate. At t=200 us drop init=0, which
//     triggers PSX's 12101-cycle startup walk (~121 us). The chip
//     observes:
//       chip 0: PRE-ALL → 2 AREFs (8 cycles apart) → MRS
//       chip 1: PRE-ALL → 2 AREFs (8 cycles apart) → MRS
//     followed by STATE_IDLE at ~t=321 us. PSX's init checker
//     requirements are satisfied cleanly without needing helper pulses.
//   - Wait through one distributed-refresh cycle (every 780 cycles =
//     7.8 us at 100 MHz) so each chip has a few AREFs under its belt
//     before the first ACT.
//   - Round-trip on ch3: write 0xCAFEBABE at byte address 0x10, read
//     back, compare.
//
// Pass criterion: zero errors across both chips after the round-trip.
//
// Expected warnings (2 total): one per chip, "AUTO REFRESH interval ~8300
// ns exceeds tREFI target 7800 ns". PSX's distributed refresh path uses
// cycles_per_refresh=780 cycles plus a few cycles of state-machine
// traversal at 100 MHz, putting the per-chip refresh interval right at
// the JEDEC 8192-per-64ms limit. The chip's WARN_TREFI gate fires when an
// individual interval exceeds the strict 7800 ns budget; PSX still meets
// the aggregate 64 ms window check. These are documentation warnings, not
// failures.
//
// Run via verilator/Makefile:
//   make -C verilator psx
// =============================================================================

module xsds_tb_psx;

    // 100 MHz SDRAM clock (PSX_MiSTer's nominal rate per the in-source
    // comment "clock ~100MHz"). Period 10 ns. clk_base is clk/3.
    localparam realtime TCK      = 10.0;
    localparam realtime TCK_BASE = TCK * 3.0;

    logic Clk      = 1'b0;
    always #(TCK/2.0) Clk = ~Clk;

    // clk_base is clk/3, generated as a divider off Clk so they stay
    // phase-coherent (PSX's `clk3xIndex` logic depends on this).
    logic clk_base = 1'b0;
    int   clk_div  = 0;
    always @(posedge Clk) begin
        clk_div <= (clk_div == 2) ? 0 : clk_div + 1;
        if (clk_div == 0) clk_base <= ~clk_base;
    end

    // -------------------------------------------------------------------------
    // PSX SDRAM controller interface
    // -------------------------------------------------------------------------
    logic        init      = 1'b1;
    logic        SDRAM_EN  = 1'b1;
    logic        refreshForce = 1'b0;
    wire         ram_idle;

    // ch1 — unused
    logic [26:0] ch1_addr  = 27'h0;
    wire  [127:0] ch1_dout;
    wire  [31:0]  ch1_dout32;
    logic [15:0] ch1_din   = 16'h0;
    logic        ch1_req   = 1'b0;
    logic        ch1_rnw   = 1'b1;
    logic        ch1_dma   = 1'b0;
    logic [1:0]  ch1_cntDMA= 2'b00;
    logic        ch1_cache = 1'b0;
    wire         ch1_ready;
    wire  [3:0]  cache_wr;
    wire  [31:0] cache_data;
    wire  [7:0]  cache_addr;
    wire         dma_wr;
    wire         dma_reqprocessed;
    wire  [31:0] dma_data;

    // ch2 — unused
    logic [26:0] ch2_addr  = 27'h0;
    wire  [31:0] ch2_dout;
    logic [31:0] ch2_din   = 32'h0;
    logic        ch2_req   = 1'b0;
    logic        ch2_rnw   = 1'b1;
    logic [3:0]  ch2_be    = 4'b1111;
    wire         ch2_ready;

    // ch3 — used for round-trip
    logic [26:0] ch3_addr  = 27'h0;
    wire  [31:0] ch3_dout;
    logic [31:0] ch3_din   = 32'h0;
    logic        ch3_req   = 1'b0;
    logic        ch3_rnw   = 1'b1;
    logic [3:0]  ch3_be    = 4'b1111;
    wire         ch3_ready;

    // DMA FIFO — held empty
    logic [26:0] dmafifo_adr   = 27'h0;
    logic [31:0] dmafifo_data  = 32'h0;
    logic        dmafifo_empty = 1'b1;
    wire         dmafifo_read;

    // -------------------------------------------------------------------------
    // SDRAM bus from PSX.
    //
    // The patched PSX (psx_sdram_for_verilator.sv) splits `inout reg
    // SDRAM_DQ` into three signals — `SDRAM_DQ_OUT` / `SDRAM_DQ_OE` /
    // `SDRAM_DQ_IN` — because Verilator's `--bbox-unsup` flow misbehaves
    // with back-to-back NBAs to a multi-driver tristate (the first write
    // succeeds, but the second write's data is wire-OR'd with the first's
    // stuck value, producing e.g. 0xBABE | 0xCAFE = 0xfafe). The TB
    // re-merges the three signals into a single tristate `SDRAM_DQ`
    // wire here so the chip's `inout Dq` ports see normal tristate
    // semantics.
    // -------------------------------------------------------------------------
    wire  [15:0] SDRAM_DQ_OUT_psx;
    wire         SDRAM_DQ_OE_psx;
    wire  [15:0] SDRAM_DQ;
    assign SDRAM_DQ = SDRAM_DQ_OE_psx ? SDRAM_DQ_OUT_psx : 16'hzzzz;
    wire  [12:0] SDRAM_A;
    wire         SDRAM_DQML;
    wire         SDRAM_DQMH;
    wire  [1:0]  SDRAM_BA;
    wire         SDRAM_nCS;
    wire         SDRAM_nWE;
    wire         SDRAM_nRAS;
    wire         SDRAM_nCAS;
    wire         SDRAM_CKE;
    wire         SDRAM_CLK;

    sdram u_psx (
        .init             (init),
        .clk              (Clk),
        .clk_base         (clk_base),
        .SDRAM_EN         (SDRAM_EN),
        .SDRAM_DQ_OUT     (SDRAM_DQ_OUT_psx),
        .SDRAM_DQ_OE      (SDRAM_DQ_OE_psx),
        .SDRAM_DQ_IN      (SDRAM_DQ),
        .SDRAM_A          (SDRAM_A),
        .SDRAM_DQML       (SDRAM_DQML),
        .SDRAM_DQMH       (SDRAM_DQMH),
        .SDRAM_BA         (SDRAM_BA),
        .SDRAM_nCS        (SDRAM_nCS),
        .SDRAM_nWE        (SDRAM_nWE),
        .SDRAM_nRAS       (SDRAM_nRAS),
        .SDRAM_nCAS       (SDRAM_nCAS),
        .SDRAM_CKE        (SDRAM_CKE),
        .SDRAM_CLK        (SDRAM_CLK),
        .refreshForce     (refreshForce),
        .ram_idle         (ram_idle),
        .ch1_addr         (ch1_addr),
        .ch1_dout         (ch1_dout),
        .ch1_dout32       (ch1_dout32),
        .ch1_din          (ch1_din),
        .ch1_req          (ch1_req),
        .ch1_rnw          (ch1_rnw),
        .ch1_dma          (ch1_dma),
        .ch1_cntDMA       (ch1_cntDMA),
        .ch1_cache        (ch1_cache),
        .ch1_ready        (ch1_ready),
        .cache_wr         (cache_wr),
        .cache_data       (cache_data),
        .cache_addr       (cache_addr),
        .dma_wr           (dma_wr),
        .dma_reqprocessed (dma_reqprocessed),
        .dma_data         (dma_data),
        .ch2_addr         (ch2_addr),
        .ch2_dout         (ch2_dout),
        .ch2_din          (ch2_din),
        .ch2_req          (ch2_req),
        .ch2_rnw          (ch2_rnw),
        .ch2_be           (ch2_be),
        .ch2_ready        (ch2_ready),
        .ch3_addr         (ch3_addr),
        .ch3_dout         (ch3_dout),
        .ch3_din          (ch3_din),
        .ch3_req          (ch3_req),
        .ch3_rnw          (ch3_rnw),
        .ch3_be           (ch3_be),
        .ch3_ready        (ch3_ready),
        .dmafifo_adr      (dmafifo_adr),
        .dmafifo_data     (dmafifo_data),
        .dmafifo_empty    (dmafifo_empty),
        .dmafifo_read     (dmafifo_read)
    );

    // -------------------------------------------------------------------------
    // 200 us power-up gate: force RAS/CAS/WE to NOP encoding while
    // $realtime is inside the chip model's startup window. PSX's startup
    // state machine emits PRE-ALL at ~120 us after init drops; we hold
    // init=1 throughout the gate so the walk doesn't begin until the
    // gate is up.
    // -------------------------------------------------------------------------
    logic powerup_done = 1'b0;
    initial begin
        #(200_000) powerup_done = 1'b1;
    end

    wire eff_ras_n = powerup_done ? SDRAM_nRAS : 1'b1;
    wire eff_cas_n = powerup_done ? SDRAM_nCAS : 1'b1;
    wire eff_we_n  = powerup_done ? SDRAM_nWE  : 1'b1;
    wire eff_cs_n  = SDRAM_nCS;

    // Drop init right at gate lift. PSX's startup walk runs from drop
    // for ~12101 clk cycles ≈ 121 us. PRE-ALL on chip 0 lands at
    // ~+120.4 us, chip 0 MRS at ~+120.5 us, then chip 1 PRE-ALL at
    // ~+120.6 us, chip 1 MRS at ~+120.7 us. STATE_IDLE at ~+121.0 us.
    // The chip's init checker is satisfied by the full PRE-ALL → 2 AREF
    // → MRS sequence PSX emits per chip; no helper pulses needed.
    initial begin
        #(200_000) init = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Chip-level instances. PSX drives SDRAM_nCS from a per-cycle chip-
    // select bit (addr[26]), so chip 0's Cs_n routes from SDRAM_nCS and
    // chip 1's from ~SDRAM_nCS — mirroring the on-board LVC1G04 inverter.
    // -------------------------------------------------------------------------
    wire chip0_cs_n =  eff_cs_n;
    wire chip1_cs_n = ~eff_cs_n;

    wire chip_cke  = 1'b1;
    wire chip_ldqm = SDRAM_A[11];
    wire chip_udqm = SDRAM_A[12];

    // Per-instance Verilator workarounds for the AS4C32M16SB-6TIN model:
    //
    //   tLZ_MIN = 0.0 / tAC_MAX = 0.0
    //     The chip's `dq_oe <= #(tLZ_MIN) 1'b1` and `dq_out <= #(tAC_MAX)
    //     data` intra-NBA delays don't fire in-timestep under Verilator's
    //     --timing + --bbox-unsup, so the first burst word's drive slips
    //     past the next posedge. Zeroing these delays makes the OE/data
    //     NBA commit at end-of-timestep, so the first BL=2 word appears
    //     on the SDRAM_DQ wire at the posedge the controller expects.
    //     Real-silicon tAC/tLZ modeling is preserved on the other
    //     bring-up TBs.
    //
    // (See also: psx_sdram_for_verilator.sv shifts ch3's read-pipeline
    // capture indices by 1 — the chip model's NBA-registered dq_out
    // still appears one posedge later than real silicon's combinational
    // output, and PSX's dq_reg stage adds another cycle on top.)
    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME ("TB_PSX_CHIP0_AS4C32M16SB"),
        .tLZ_MIN   (0.0),
        .tAC_MAX   (0.0)
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
        .CHIP_NAME ("TB_PSX_CHIP1_AS4C32M16SB"),
        .tLZ_MIN   (0.0),
        .tAC_MAX   (0.0)
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
    logic [31:0] readback;
    int          poll;

    initial begin : stim_proc
        // Wait past the gate AND past PSX's 121 us startup walk plus
        // a few distributed-refresh cycles so each chip has multiple
        // AREFs recorded before the first ACT.
        #(340_000);

        // ch3 write: 0xCAFEBABE at chip 0, byte address 0x10.
        @(posedge clk_base);
        ch3_addr = 27'h00_0010;     // chip 0, word index 0x8, addr[0]=0
        ch3_din  = 32'hCAFE_BABE;
        ch3_be   = 4'b1111;          // all bytes
        ch3_rnw  = 1'b0;             // write
        ch3_req  = 1'b1;

        // Wait for ch3_ready (single-cycle pulse in clk_base domain).
        poll = 0;
        while (!ch3_ready && poll < 500) begin
            @(posedge clk_base);
            poll = poll + 1;
        end
        @(posedge clk_base);
        ch3_req = 1'b0;

        // Settle.
        #(2_000);

        // ch3 read: same address.
        @(posedge clk_base);
        ch3_addr = 27'h00_0010;
        ch3_rnw  = 1'b1;             // read
        ch3_req  = 1'b1;

        poll = 0;
        while (!ch3_ready && poll < 500) begin
            @(posedge clk_base);
            poll = poll + 1;
        end
        @(posedge clk_base);
        ch3_req = 1'b0;

        // Let the read pipeline drain.
        #(1_000);
        readback = ch3_dout;

        $display("[psx-tb] ch3 round-trip: wrote 0xCAFEBABE, read 0x%08h", readback);

        u_chip0.dump_state();
        u_chip1.dump_state();
        u_chip0.report_refresh_status();
        u_chip1.report_refresh_status();

        if (u_chip0.error_count != 0 || u_chip1.error_count != 0) begin
            $display("[psx-tb] FAIL — errors: chip0=%0d chip1=%0d",
                     u_chip0.error_count, u_chip1.error_count);
            $fatal;
        end

        if (readback !== 32'hCAFE_BABE) begin
            $display("[psx-tb] FAIL — readback mismatch (got 0x%08h, expected 0xCAFEBABE)",
                     readback);
            $fatal;
        end

        $display("[psx-tb] PASS — 0 errors, %0d warnings (chip0 + chip1)",
                 u_chip0.warning_count + u_chip1.warning_count);
        $finish;
    end

    initial begin
        #(50_000_000) $fatal(1, "[psx-tb] timeout — TB ran past 50 ms");
    end

endmodule
