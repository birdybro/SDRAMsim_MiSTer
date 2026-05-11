`timescale 1ns/1ps

// =============================================================================
// XSDS v3.0 128 MByte SDRAM module simulation model
// =============================================================================
// Models the XSDS RAM module addon board for the MiSTer FPGA platform — a
// 40-pin SDRAM module containing two AS4C32M16SB-6TIN chips on a shared bus.
//
// Module capacity:
//   128 MBytes = 1024 Mbits
//
// Physical memory:
//   2 x AS4C32M16SB-6TIN chips
//   each chip = 512 Mbits = 64 MBytes
//   Per chip: 4 banks x 8192 rows x 1024 columns x 16 bits
//
// Connector signals (matches XSDS v3.0 schematic, 40-pin header P1):
//   Clk, Cs1_n, Ras_n, Cas_n, We_n, Ba[1:0], Addr[12:0], Dq[15:0]
//
// Hidden by the board (NOT on the connector):
//   - CKE: tied to VCC permanently. No power-down / self-refresh / clock-
//     suspend possible through this connector. Hardwired to 1'b1 internally.
//   - DQML / DQMH: tied to Addr[11] / Addr[12] at the chip pins. The wrapper
//     extracts those bits and drives the chip-level Ldqm / Udqm internally.
//   - CS2: an internal-only net generated as ~Cs1_n via an LVC1G04 inverter
//     (U3 on the schematic). Cs1_n IS the high chip-select bit.
//
// Addressing the full 128 MB:
//   Cs1_n=0 selects chip 0 (lower 64 MB); chip 1 sees CS=1 and ignores cmds.
//   Cs1_n=1 selects chip 1 (upper 64 MB); chip 0 sees CS=1 and ignores cmds.
//   The hardware can never deselect both chips. Idle cycles must drive
//   {Ras_n, Cas_n, We_n} = 3'b111 (NOP) regardless of Cs1_n.
//
// Refresh:
//   Each chip independently requires 8192 AUTO REFRESH commands per 64 ms.
//   The controller must issue refreshes against both Cs1_n=0 and Cs1_n=1 to
//   keep both chips alive.
//
// See CONTROLLER_GUIDE.md for protocol/timing rules a controller must follow.
//
// Simulation-only. Not synthesizable.
// =============================================================================

module xsds_128mbyte_sdram_model #(
    parameter bit DEBUG               = 1'b0,
    parameter bit STRICT_TIMING       = 1'b1,
    parameter bit WARN_TREFI          = 1'b1,
    parameter bit INIT_UNWRITTEN_TO_X = 1'b1
) (
    input  wire        Clk,

    // Connector pin P1.33. Acts as the high chip-select bit:
    //   Cs1_n=0 -> chip 0 (lower 64 MB) selected, chip 1 deselected.
    //   Cs1_n=1 -> chip 0 deselected, chip 1 (upper 64 MB) selected.
    // The board has no separate ChipSel; the on-board LVC1G04 inverter (U3)
    // drives chip 1's CS# from ~Cs1_n. Both-chips-deselected is impossible.
    input  wire        Cs1_n,

    input  wire        Ras_n,
    input  wire        Cas_n,
    input  wire        We_n,

    input  wire [1:0]  Ba,
    input  wire [12:0] Addr,

    inout  wire [15:0] Dq
);

    // CKE is tied to VCC on the XSDS board.
    wire chip_cke = 1'b1;

    // DQML / DQMH are tied to Addr[11] / Addr[12] at the chip pins.
    wire chip_ldqm = Addr[11];
    wire chip_udqm = Addr[12];

    // Chip 0 takes Cs1_n directly; chip 1 takes the inverted Cs1_n,
    // mirroring the LVC1G04 inverter (U3) on the board.
    wire chip0_cs_n =  Cs1_n;
    wire chip1_cs_n = ~Cs1_n;

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME           ("XSDS_CHIP0_AS4C32M16SB"),
        .DEBUG               (DEBUG),
        .STRICT_TIMING       (STRICT_TIMING),
        .WARN_TREFI          (WARN_TREFI),
        .INIT_UNWRITTEN_TO_X (INIT_UNWRITTEN_TO_X)
    ) u_chip0 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip0_cs_n),
        .Ras_n (Ras_n),
        .Cas_n (Cas_n),
        .We_n  (We_n),
        .Ba    (Ba),
        .Addr  (Addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (Dq)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME           ("XSDS_CHIP1_AS4C32M16SB"),
        .DEBUG               (DEBUG),
        .STRICT_TIMING       (STRICT_TIMING),
        .WARN_TREFI          (WARN_TREFI),
        .INIT_UNWRITTEN_TO_X (INIT_UNWRITTEN_TO_X)
    ) u_chip1 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip1_cs_n),
        .Ras_n (Ras_n),
        .Cas_n (Cas_n),
        .We_n  (We_n),
        .Ba    (Ba),
        .Addr  (Addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (Dq)
    );

    // Refresh tracking is per-chip because each chip only sees commands when
    // Cs1_n routes to it. A testbench that only refreshes one Cs1_n state will
    // get a violation from the other chip, not from the wrapper — call this
    // at end-of-test to print both chips' refresh state side by side.
    task automatic module_refresh_status();
        begin
            u_chip0.report_refresh_status();
            u_chip1.report_refresh_status();
        end
    endtask

    // Dump/restore the full 128 MB module to a pair of files:
    //   "<base>.chip0" — lower 64 MB
    //   "<base>.chip1" — upper 64 MB
    // Each file is the sparse-key format produced by the chip-level
    // dump_memory task and consumed by load_memory.
    task automatic module_dump_memory(input string base_filename);
        begin
            u_chip0.dump_memory({base_filename, ".chip0"});
            u_chip1.dump_memory({base_filename, ".chip1"});
        end
    endtask

    task automatic module_load_memory(input string base_filename);
        begin
            u_chip0.load_memory({base_filename, ".chip0"});
            u_chip1.load_memory({base_filename, ".chip1"});
        end
    endtask

    // Load a contiguous ROM image into the 128 MB module starting at
    // byte address `byte_base`. One 16-bit hex value per line; the file
    // may straddle the 64 MB chip boundary at byte 0x0400_0000 (word
    // index 2^25) — words on each side are dispatched to the matching
    // chip's poke task.
    // Aggregate violation counts across both chips. issue_error / issue_warn
    // in the chip model bump these on every violation regardless of whether
    // STRICT_TIMING downgrades $error to $warning, so a testbench can do
    //   if (dut.module_error_count() != 0) $fatal;
    // at end-of-test without parsing simulator output.
    function automatic int unsigned module_error_count();
        module_error_count = u_chip0.error_count + u_chip1.error_count;
    endfunction

    function automatic int unsigned module_warning_count();
        module_warning_count = u_chip0.warning_count + u_chip1.warning_count;
    endfunction

    task automatic module_dump_state();
        begin
            u_chip0.dump_state();
            u_chip1.dump_state();
        end
    endtask

    task automatic module_load_rom_hex(
        input string             filename,
        input longint unsigned   byte_base
    );
        int                fd;
        string             line;
        logic [15:0]       value;
        longint unsigned   global_word_idx;
        logic [24:0]       chip_local_word;
        int unsigned       loaded;
        int unsigned       bank;
        int unsigned       row;
        int unsigned       col;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("xsds module_load_rom_hex: failed to open '%s'", filename);
                return;
            end

            if (byte_base[0]) begin
                $error("xsds module_load_rom_hex: byte_base=%0d is not 16-bit aligned",
                       byte_base);
                $fclose(fd);
                return;
            end

            global_word_idx = byte_base >> 1;
            loaded = 0;

            while ($fgets(line, fd) != 0) begin
                if ($sscanf(line, "%h", value) == 1) begin
                    if (global_word_idx >= (longint'(1) << 26)) begin
                        $error("xsds module_load_rom_hex: word offset %0d exceeds 128 MB capacity",
                               global_word_idx);
                        break;
                    end

                    chip_local_word = global_word_idx[24:0];
                    bank = chip_local_word[24:23];
                    row  = chip_local_word[22:10];
                    col  = chip_local_word[9:0];

                    if (global_word_idx[25] == 1'b0) begin
                        u_chip0.poke(bank, row, col, value);
                    end else begin
                        u_chip1.poke(bank, row, col, value);
                    end

                    global_word_idx++;
                    loaded++;
                end
            end
            $fclose(fd);
        end
    endtask

endmodule


// =============================================================================
// AS4C32M16SB-6TIN-compatible 512 Mbit x16 SDR SDRAM chip model
// =============================================================================
// Geometry:
//   512 Mbits = 64 MBytes
//   4 banks x 8192 rows x 1024 columns x 16 bits
//
// Features modeled:
//   - ACT, READ, WRITE, PRECHARGE, PRECHARGE ALL
//   - AUTO REFRESH
//   - SELF REFRESH entry/exit
//   - MODE REGISTER SET
//   - BURST STOP
//   - CAS latency 2 or 3
//   - Burst length 1, 2, 4, 8, full page
//   - Sequential and interleaved bursts
//   - Write burst single/burst mode
//   - LDQM/UDQM byte masking
//   - Read DQM two-clock output-mask latency
//   - Sparse memory backing store
//   - 8192 refresh commands per 64 ms checker
//
// Simulation-only. Not synthesizable.
// =============================================================================

module as4c32m16sb_6tin_chip_model #(
    parameter string   CHIP_NAME             = "AS4C32M16SB",
    parameter bit      DEBUG                 = 1'b0,
    parameter bit      STRICT_TIMING         = 1'b1,
    parameter bit      WARN_TREFI            = 1'b1,
    parameter bit      INIT_UNWRITTEN_TO_X   = 1'b1,

    // Geometry.
    parameter int      BANKS                 = 4,
    parameter int      ROW_BITS              = 13,
    parameter int      ROWS                  = 8192,
    parameter int      COL_BITS              = 10,
    parameter int      COLS                  = 1024,
    parameter int      DATA_BITS             = 16,

    // The physical column count is 1024 for this 512 Mbit x16 organization.
    // Some datasheet tables list 512 for full-page length; keep this as a
    // parameter so you can override it if your target controller expects that.
    parameter int      FULL_PAGE_LEN         = 1024,

    // AS4C32M16SB-6 speed-grade timing, ns.
    parameter realtime tCK_CL2_MIN           = 10.0,
    parameter realtime tCK_CL3_MIN           = 6.0,
    parameter realtime tCH_MIN               = 2.0,
    parameter realtime tCL_MIN               = 2.0,
    parameter realtime tRC_MIN               = 60.0,
    parameter realtime tRFC_MIN              = 60.0,
    parameter realtime tRCD_MIN              = 18.0,
    parameter realtime tRP_MIN               = 18.0,
    parameter realtime tRRD_MIN              = 12.0,
    parameter realtime tMRD_MIN              = 12.0,
    parameter realtime tRAS_MIN              = 42.0,
    parameter realtime tRAS_MAX              = 120_000.0,
    parameter realtime tWR_MIN               = 12.0,
    parameter realtime tWTR_MIN              = 7.5,
    parameter realtime tCCD_MIN              = 6.0,
    parameter realtime tXSR_MIN              = 70.0,
    parameter realtime tIS_MIN               = 1.5,
    parameter realtime tREFI_MAX             = 7_800.0,

    // 8192 refresh cycles per 64 ms.
    parameter realtime tREF_WINDOW           = 64_000_000.0,
    parameter int      REFRESHES_PER_WINDOW  = 8192,

    parameter realtime POWERUP_STABLE_TIME   = 200_000.0
) (
    input  wire        Clk,
    input  wire        Cke,
    input  wire        Cs_n,
    input  wire        Ras_n,
    input  wire        Cas_n,
    input  wire        We_n,
    input  wire [1:0]  Ba,
    input  wire [12:0] Addr,
    input  wire        Ldqm,
    input  wire        Udqm,
    inout  wire [15:0] Dq
);

    // -------------------------------------------------------------------------
    // Command decode
    // -------------------------------------------------------------------------

    localparam int CMD_DESL = 0;
    localparam int CMD_NOP  = 1;
    localparam int CMD_ACT  = 2;
    localparam int CMD_READ = 3;
    localparam int CMD_WRIT = 4;
    localparam int CMD_PRE  = 5;
    localparam int CMD_AREF = 6;
    localparam int CMD_MRS  = 7;
    localparam int CMD_BST  = 8;
    localparam int CMD_SREF = 9;

    function automatic int decode_cmd(
        input bit cs_n,
        input bit ras_n,
        input bit cas_n,
        input bit we_n,
        input bit cke_now
    );
        begin
            if (cs_n) begin
                decode_cmd = CMD_DESL;
            end else begin
                unique case ({ras_n, cas_n, we_n})
                    3'b111: decode_cmd = CMD_NOP;
                    3'b011: decode_cmd = CMD_ACT;
                    3'b101: decode_cmd = CMD_READ;
                    3'b100: decode_cmd = CMD_WRIT;
                    3'b010: decode_cmd = CMD_PRE;
                    3'b001: decode_cmd = cke_now ? CMD_AREF : CMD_SREF;
                    3'b000: decode_cmd = CMD_MRS;
                    3'b110: decode_cmd = CMD_BST;
                    default: decode_cmd = CMD_NOP;
                endcase
            end
        end
    endfunction

    function automatic string cmd_name(input int cmd);
        begin
            unique case (cmd)
                CMD_DESL: cmd_name = "DESL";
                CMD_NOP : cmd_name = "NOP";
                CMD_ACT : cmd_name = "ACT";
                CMD_READ: cmd_name = "READ";
                CMD_WRIT: cmd_name = "WRITE";
                CMD_PRE : cmd_name = "PRECHARGE";
                CMD_AREF: cmd_name = "AUTO_REFRESH";
                CMD_MRS : cmd_name = "MODE_REGISTER_SET";
                CMD_BST : cmd_name = "BURST_STOP";
                CMD_SREF: cmd_name = "SELF_REFRESH";
                default : cmd_name = "UNKNOWN";
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sparse memory
    // -------------------------------------------------------------------------

    typedef bit   [24:0] mem_key_t;
    typedef logic [15:0] data_t;

    data_t mem [mem_key_t];

    function automatic mem_key_t make_key(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col
    );
        begin
            make_key = mem_key_t'({bank[1:0], row[12:0], col[9:0]});
        end
    endfunction

    function automatic data_t mem_read(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col
    );
        mem_key_t key;
        begin
            key = make_key(bank, row, col);

            if (mem.exists(key)) begin
                mem_read = mem[key];
            end else if (INIT_UNWRITTEN_TO_X) begin
                mem_read = 16'hxxxx;
            end else begin
                mem_read = 16'h0000;
            end
        end
    endfunction

    task automatic mem_write(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        input data_t       data_in,
        input bit          mask_low,
        input bit          mask_high
    );
        mem_key_t key;
        data_t old_data;
        data_t new_data;
        begin
            key      = make_key(bank, row, col);
            old_data = mem_read(bank, row, col);
            new_data = old_data;

            if (!mask_low)  new_data[7:0]  = data_in[7:0];
            if (!mask_high) new_data[15:8] = data_in[15:8];

            mem[key] = new_data;

            if (DEBUG) begin
                $display("%0t %s WRITE bank=%0d row=%0d col=%0d data=%04h dqm=%b%b",
                         $time, CHIP_NAME, bank, row, col, new_data, mask_high, mask_low);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Bank state
    // -------------------------------------------------------------------------

    bit          bank_open [BANKS];
    int unsigned open_row  [BANKS];

    realtime last_activate  [BANKS];
    realtime last_precharge [BANKS];
    realtime last_write     [BANKS];
    realtime last_read      [BANKS];

    realtime last_any_activate;
    realtime last_refresh;
    realtime last_mrs;
    realtime last_self_refresh_exit;
    realtime last_col_cmd;

    initial begin
        int i;

        for (i = 0; i < BANKS; i++) begin
            bank_open[i]      = 1'b0;
            open_row[i]       = 0;
            last_activate[i]  = -1.0e30;
            last_precharge[i] = -1.0e30;
            last_write[i]     = -1.0e30;
            last_read[i]      = -1.0e30;
        end

        last_any_activate      = -1.0e30;
        last_refresh           = -1.0e30;
        last_mrs               = -1.0e30;
        last_self_refresh_exit = -1.0e30;
        last_col_cmd           = -1.0e30;
    end

    function automatic bit all_banks_idle();
        int i;
        begin
            all_banks_idle = 1'b1;

            for (i = 0; i < BANKS; i++) begin
                if (bank_open[i]) all_banks_idle = 1'b0;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Mode register
    // -------------------------------------------------------------------------

    int unsigned burst_length;
    bit          burst_full_page;
    bit          burst_interleaved;
    int unsigned cas_latency;
    bit          write_burst_single;

    initial begin
        burst_length       = 1;
        burst_full_page    = 1'b0;
        burst_interleaved  = 1'b0;
        cas_latency        = 3;
        write_burst_single = 1'b0;
    end

    function automatic int unsigned decode_burst_length(input bit [2:0] bl);
        begin
            unique case (bl)
                3'b000: decode_burst_length = 1;
                3'b001: decode_burst_length = 2;
                3'b010: decode_burst_length = 4;
                3'b011: decode_burst_length = 8;
                3'b111: decode_burst_length = FULL_PAGE_LEN;
                default: decode_burst_length = 0;
            endcase
        end
    endfunction

    task automatic load_mode_register(input bit [12:0] mode);
        int unsigned bl;
        begin
            bl = decode_burst_length(mode[2:0]);

            if (Ba != 2'b00) begin
                issue_warn("MRS BA should be 00");
            end

            if (mode[10] != 1'b0) begin
                issue_warn("MRS A10 should be 0");
            end

            if (mode[12] != 1'b0 || mode[11] != 1'b0) begin
                issue_warn("MRS A12:A11 should be 00/RFU");
            end

            if (bl == 0) begin
                issue_error("reserved MRS burst length selected");
                bl = 1;
            end

            burst_length      = bl;
            burst_full_page   = (mode[2:0] == 3'b111);
            burst_interleaved = mode[3];

            unique case (mode[6:4])
                3'b010: cas_latency = 2;
                3'b011: cas_latency = 3;
                default: begin
                    issue_error("reserved MRS CAS latency selected");
                    cas_latency = 3;
                end
            endcase

            if (mode[8:7] != 2'b00) begin
                issue_error("MRS test mode bits A8:A7 must be 00");
            end

            write_burst_single = mode[9];

            if (burst_full_page && burst_interleaved) begin
                issue_error("full-page burst is not valid with interleaved burst type");
            end

            if (DEBUG) begin
                $display("%0t %s MRS BL=%0d full=%0b BT=%s CL=%0d WBL=%s",
                         $time,
                         CHIP_NAME,
                         burst_length,
                         burst_full_page,
                         burst_interleaved ? "interleaved" : "sequential",
                         cas_latency,
                         write_burst_single ? "single" : "burst");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Burst address generation
    // -------------------------------------------------------------------------

    function automatic int unsigned next_col(
        input int unsigned start_col,
        input int unsigned index,
        input int unsigned len,
        input bit          interleaved
    );
        int unsigned low_mask;
        int unsigned base;
        int unsigned offset;
        begin
            if (len <= 1) begin
                next_col = start_col & (COLS - 1);
            end else if (interleaved) begin
                low_mask = len - 1;
                base     = start_col & ~low_mask;
                offset   = (start_col ^ index) & low_mask;
                next_col = (base | offset) & (COLS - 1);
            end else begin
                low_mask = len - 1;
                base     = start_col & ~low_mask;
                offset   = (start_col + index) & low_mask;
                next_col = (base | offset) & (COLS - 1);
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // DQ drive and DQM pipeline
    // -------------------------------------------------------------------------

    logic [15:0] dq_out;
    logic        dq_oe;

    assign Dq = dq_oe ? dq_out : 16'hzzzz;

    logic [1:0] dqm_pipe [0:1];

    initial begin
        dq_out      = 16'h0000;
        dq_oe       = 1'b0;
        dqm_pipe[0] = 2'b11;
        dqm_pipe[1] = 2'b11;
    end

    // -------------------------------------------------------------------------
    // Active burst state
    // -------------------------------------------------------------------------

    typedef struct {
        bit          active;
        bit          is_read;
        bit          is_write;
        int unsigned bank;
        int unsigned row;
        int unsigned start_col;
        int unsigned index;
        int unsigned len;
        int unsigned latency;
        bit          auto_precharge;
        bit          full_page;
        bit          interleaved;
    } burst_state_t;

    burst_state_t burst;

    initial begin
        burst.active         = 1'b0;
        burst.is_read        = 1'b0;
        burst.is_write       = 1'b0;
        burst.bank           = 0;
        burst.row            = 0;
        burst.start_col      = 0;
        burst.index          = 0;
        burst.len            = 1;
        burst.latency        = 0;
        burst.auto_precharge = 1'b0;
        burst.full_page      = 1'b0;
        burst.interleaved    = 1'b0;
    end

    task automatic stop_burst();
        begin
            burst.active   = 1'b0;
            burst.is_read  = 1'b0;
            burst.is_write = 1'b0;
            dq_oe          = 1'b0;
        end
    endtask

    task automatic maybe_auto_precharge(input int unsigned bank);
        begin
            if (burst.auto_precharge && !burst.full_page) begin
                do_precharge(bank, 1'b0, "auto-precharge");
            end
        end
    endtask

    task automatic advance_read_burst();
        int unsigned col;
        data_t data_read;
        logic [1:0] read_dqm;
        begin
            if (!burst.active || !burst.is_read) begin
                dq_oe = 1'b0;
            end else if (burst.latency != 0) begin
                burst.latency--;
                dq_oe = 1'b0;
            end else begin
                col       = next_col(burst.start_col, burst.index, burst.len, burst.interleaved);
                data_read = mem_read(burst.bank, burst.row, col);
                read_dqm  = dqm_pipe[1];

                dq_out = data_read;
                dq_oe  = 1'b1;

                if (read_dqm[0]) dq_out[7:0]  = 8'hzz;
                if (read_dqm[1]) dq_out[15:8] = 8'hzz;

                if (DEBUG) begin
                    $display("%0t %s READ bank=%0d row=%0d col=%0d data=%04h dqm_latency2=%b",
                             $time, CHIP_NAME, burst.bank, burst.row, col, data_read, read_dqm);
                end

                burst.index++;

                if (!burst.full_page && burst.index >= burst.len) begin
                    maybe_auto_precharge(burst.bank);
                    stop_burst();
                end
            end
        end
    endtask

    task automatic consume_write_data();
        int unsigned col;
        begin
            col = next_col(burst.start_col, burst.index, burst.len, burst.interleaved);

            mem_write(
                burst.bank,
                burst.row,
                col,
                Dq,
                Ldqm,
                Udqm
            );

            // Stamp at every data cycle so tWR (write-to-precharge) and tWTR
            // (write-to-read) measure from the LAST DQ input, not from the
            // WRITE command. Matters once BL > 1.
            last_write[burst.bank] = $realtime;

            burst.index++;

            if (!burst.full_page && burst.index >= burst.len) begin
                maybe_auto_precharge(burst.bank);
                stop_burst();
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Initialization and refresh tracking
    // -------------------------------------------------------------------------

    bit init_seen_cke_high;
    bit init_seen_precharge_all;
    bit init_seen_mrs;
    int init_auto_refresh_count;

    realtime refresh_times [$];

    bit in_power_down;
    bit in_self_refresh;
    bit in_clock_suspend;

    initial begin
        init_seen_cke_high      = 1'b0;
        init_seen_precharge_all = 1'b0;
        init_seen_mrs           = 1'b0;
        init_auto_refresh_count = 0;
        in_power_down           = 1'b0;
        in_self_refresh         = 1'b0;
        in_clock_suspend        = 1'b0;
    end

    task automatic record_refresh();
        realtime span;
        begin
            if (WARN_TREFI && refresh_times.size() != 0) begin
                if (($realtime - refresh_times[refresh_times.size()-1]) > tREFI_MAX) begin
                    issue_warn($sformatf("AUTO REFRESH interval %0.3f ns exceeds tREFI target %0.3f ns",
                                         $realtime - refresh_times[refresh_times.size()-1],
                                         tREFI_MAX));
                end
            end

            last_refresh = $realtime;
            refresh_times.push_back($realtime);

            while (refresh_times.size() > REFRESHES_PER_WINDOW) begin
                void'(refresh_times.pop_front());
            end

            if (refresh_times.size() == REFRESHES_PER_WINDOW) begin
                span = refresh_times[refresh_times.size()-1] - refresh_times[0];

                if (span > tREF_WINDOW) begin
                    issue_error($sformatf("refresh requirement violated: %0d AUTO REFRESH commands span %0.3f ns; limit is %0.3f ns",
                                          REFRESHES_PER_WINDOW,
                                          span,
                                          tREF_WINDOW));
                end
            end
        end
    endtask

    task automatic check_init_before_normal_cmd(input int cmd);
        begin
            if ((cmd == CMD_ACT) || (cmd == CMD_READ) || (cmd == CMD_WRIT)) begin
                if (!init_seen_cke_high) begin
                    issue_error("normal command before CKE high");
                end

                if (!init_seen_precharge_all) begin
                    issue_error("normal command before initialization PRECHARGE ALL");
                end

                if (!init_seen_mrs) begin
                    issue_error("normal command before MODE REGISTER SET");
                end

                if (init_auto_refresh_count < 2) begin
                    issue_error("normal command before two initialization AUTO REFRESH cycles");
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Diagnostics and timing helpers
    // -------------------------------------------------------------------------

    // TB-readable counters. Bumped on every issue_error / issue_warn call,
    // regardless of whether STRICT_TIMING routes the violation to $error or
    // downgrades it to $warning. Lets a testbench assert no-violations at
    // end-of-test without parsing simulator output.
    int unsigned error_count;
    int unsigned warning_count;

    initial begin
        error_count   = 0;
        warning_count = 0;
    end

    task automatic issue_error(input string msg);
        begin
            error_count++;
            if (STRICT_TIMING) begin
                $error("%0t %s %s", $time, CHIP_NAME, msg);
            end else begin
                $warning("%0t %s %s", $time, CHIP_NAME, msg);
            end
        end
    endtask

    task automatic issue_warn(input string msg);
        begin
            warning_count++;
            $warning("%0t %s %s", $time, CHIP_NAME, msg);
        end
    endtask

    task automatic check_time_min(
        input string label_name,
        input realtime last_time,
        input realtime required
    );
        realtime delta;
        begin
            delta = $realtime - last_time;

            if ((last_time > -1.0e20) && (delta < required)) begin
                issue_error($sformatf("%s violation: delta=%0.3f ns, required=%0.3f ns",
                                      label_name,
                                      delta,
                                      required));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Command handlers
    // -------------------------------------------------------------------------

    task automatic do_activate(input int unsigned bank, input int unsigned row);
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (bank_open[bank]) begin
                issue_error($sformatf("ACT to bank %0d while already active", bank));
            end

            check_time_min($sformatf("tRP bank %0d PRE-to-ACT", bank),
                           last_precharge[bank],
                           tRP_MIN);

            check_time_min($sformatf("tRC bank %0d ACT-to-ACT", bank),
                           last_activate[bank],
                           tRC_MIN);

            check_time_min("tRRD ACT-to-ACT",
                           last_any_activate,
                           tRRD_MIN);

            check_time_min("tRFC refresh-to-command",
                           last_refresh,
                           tRFC_MIN);

            check_time_min("tXSR self-refresh-exit-to-command",
                           last_self_refresh_exit,
                           tXSR_MIN);

            bank_open[bank]     = 1'b1;
            open_row[bank]      = row;
            last_activate[bank] = $realtime;
            last_any_activate   = $realtime;

            if (DEBUG) begin
                $display("%0t %s ACT bank=%0d row=%0d", $time, CHIP_NAME, bank, row);
            end
        end
    endtask

    task automatic do_precharge(
        input int unsigned bank,
        input bit all_banks,
        input string why
    );
        int i;
        begin
            if (all_banks) begin
                for (i = 0; i < BANKS; i++) begin
                    if (bank_open[i]) begin
                        check_time_min($sformatf("tRAS bank %0d ACT-to-PRE", i),
                                       last_activate[i],
                                       tRAS_MIN);

                        check_time_min($sformatf("tWR bank %0d WRITE-to-PRE", i),
                                       last_write[i],
                                       tWR_MIN);
                    end

                    bank_open[i]      = 1'b0;
                    last_precharge[i] = $realtime;
                end

                if (DEBUG) begin
                    $display("%0t %s PRECHARGE ALL (%s)", $time, CHIP_NAME, why);
                end
            end else begin
                if (bank >= BANKS) begin
                    issue_error($sformatf("illegal bank index %0d", bank));
                    return;
                end

                if (bank_open[bank]) begin
                    check_time_min($sformatf("tRAS bank %0d ACT-to-PRE", bank),
                                   last_activate[bank],
                                   tRAS_MIN);

                    check_time_min($sformatf("tWR bank %0d WRITE-to-PRE", bank),
                                   last_write[bank],
                                   tWR_MIN);
                end

                bank_open[bank]      = 1'b0;
                last_precharge[bank] = $realtime;

                if (DEBUG) begin
                    $display("%0t %s PRECHARGE bank=%0d (%s)", $time, CHIP_NAME, bank, why);
                end
            end
        end
    endtask

    task automatic do_read(
        input int unsigned bank,
        input int unsigned col,
        input bit auto_precharge
    );
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (!bank_open[bank]) begin
                issue_error($sformatf("READ to inactive bank %0d", bank));
            end

            check_time_min("tCCD READ/WRITE-to-READ",
                           last_col_cmd,
                           tCCD_MIN);

            check_time_min($sformatf("tRCD bank %0d ACT-to-READ", bank),
                           last_activate[bank],
                           tRCD_MIN);

            check_time_min($sformatf("tWTR bank %0d WRITE-to-READ", bank),
                           last_write[bank],
                           tWTR_MIN);

            last_col_cmd = $realtime;

            stop_burst();

            burst.active         = 1'b1;
            burst.is_read        = 1'b1;
            burst.is_write       = 1'b0;
            burst.bank           = bank;
            burst.row            = open_row[bank];
            burst.start_col      = col & (COLS - 1);
            burst.index          = 0;
            burst.len            = burst_length;
            burst.latency        = cas_latency - 1;
            burst.auto_precharge = auto_precharge;
            burst.full_page      = burst_full_page;
            burst.interleaved    = burst_interleaved;

            last_read[bank] = $realtime;

            if (DEBUG) begin
                $display("%0t %s READ bank=%0d row=%0d col=%0d len=%0d ap=%0b",
                         $time,
                         CHIP_NAME,
                         bank,
                         open_row[bank],
                         col,
                         burst.len,
                         auto_precharge);
            end
        end
    endtask

    task automatic do_write(
        input int unsigned bank,
        input int unsigned col,
        input bit auto_precharge
    );
        int unsigned actual_len;
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (!bank_open[bank]) begin
                issue_error($sformatf("WRITE to inactive bank %0d", bank));
            end

            check_time_min("tCCD READ/WRITE-to-WRITE",
                           last_col_cmd,
                           tCCD_MIN);

            check_time_min($sformatf("tRCD bank %0d ACT-to-WRITE", bank),
                           last_activate[bank],
                           tRCD_MIN);

            last_col_cmd = $realtime;

            stop_burst();

            actual_len = write_burst_single ? 1 : burst_length;

            burst.active         = 1'b1;
            burst.is_read        = 1'b0;
            burst.is_write       = 1'b1;
            burst.bank           = bank;
            burst.row            = open_row[bank];
            burst.start_col      = col & (COLS - 1);
            burst.index          = 0;
            burst.len            = actual_len;
            burst.latency        = 0;
            burst.auto_precharge = auto_precharge;
            burst.full_page      = burst_full_page && !write_burst_single;
            burst.interleaved    = burst_interleaved;

            consume_write_data();

            if (DEBUG) begin
                $display("%0t %s WRITE bank=%0d row=%0d col=%0d len=%0d ap=%0b",
                         $time,
                         CHIP_NAME,
                         bank,
                         open_row[bank],
                         col,
                         actual_len,
                         auto_precharge);
            end
        end
    endtask

    task automatic do_auto_refresh();
        begin
            if (!all_banks_idle()) begin
                issue_error("AUTO REFRESH while one or more banks are active");
            end

            check_time_min("tRFC AUTO_REFRESH-to-AUTO_REFRESH",
                           last_refresh,
                           tRFC_MIN);

            record_refresh();

            // JEDEC init order is PRE-ALL -> 2 AREF -> MRS. Only count
            // refreshes that arrive after PRE-ALL so out-of-order init
            // sequences (e.g. MRS before PRE-ALL) trip the check later
            // instead of being silently accepted.
            if (init_seen_precharge_all) begin
                if (init_auto_refresh_count < 2) begin
                    init_auto_refresh_count++;
                end
            end

            if (DEBUG) begin
                $display("%0t %s AUTO REFRESH init_count=%0d window_count=%0d",
                         $time,
                         CHIP_NAME,
                         init_auto_refresh_count,
                         refresh_times.size());
            end
        end
    endtask

    task automatic do_burst_stop();
        begin
            if (DEBUG && burst.active) begin
                $display("%0t %s BURST STOP", $time, CHIP_NAME);
            end

            stop_burst();
        end
    endtask

    // -------------------------------------------------------------------------
    // Clock high/low checks
    // -------------------------------------------------------------------------

    realtime last_clk_posedge;
    realtime last_clk_negedge;

    initial begin
        last_clk_posedge = -1.0e30;
        last_clk_negedge = -1.0e30;
    end

    always @(posedge Clk) begin
        if (last_clk_negedge > -1.0e20) begin
            if (($realtime - last_clk_negedge) < tCL_MIN) begin
                issue_error($sformatf("tCL violation: low=%0.3f ns required=%0.3f ns",
                                      $realtime - last_clk_negedge,
                                      tCL_MIN));
            end
        end

        last_clk_posedge = $realtime;
    end

    always @(negedge Clk) begin
        if (last_clk_posedge > -1.0e20) begin
            if (($realtime - last_clk_posedge) < tCH_MIN) begin
                issue_error($sformatf("tCH violation: high=%0.3f ns required=%0.3f ns",
                                      $realtime - last_clk_posedge,
                                      tCH_MIN));
            end
        end

        last_clk_negedge = $realtime;
    end

    // -------------------------------------------------------------------------
    // Main synchronous behavior
    // -------------------------------------------------------------------------

    bit cke_prev;

    initial begin
        cke_prev = 1'b0;
    end

    always @(posedge Clk) begin : main_proc
        int cmd;
        int unsigned bank;
        int unsigned row;
        int unsigned col;
        bit auto_precharge;
        bit precharge_all;

        // X-prop check on command pins. decode_cmd's bit-typed args silently
        // coerce X/Z to 0, which would let undefined controller outputs
        // collapse into a defined (often dangerous) command — e.g. an X on
        // Cs_n becomes "selected" and an X on Ras/Cas/We becomes MRS. Flag
        // X/Z explicitly so those bugs surface here instead of as confusing
        // downstream state corruption.
        if ((Cke === 1'bx) || (Cke === 1'bz)) begin
            issue_error("X/Z on Cke");
            disable main_proc;
        end
        if (Cke === 1'b1 && init_seen_cke_high) begin
            if ((Cs_n === 1'bx) || (Cs_n === 1'bz)) begin
                issue_error("X/Z on Cs_n while Cke=1");
                disable main_proc;
            end
            if ((Ras_n === 1'bx) || (Ras_n === 1'bz)) begin
                issue_error("X/Z on Ras_n while Cke=1");
                disable main_proc;
            end
            if ((Cas_n === 1'bx) || (Cas_n === 1'bz)) begin
                issue_error("X/Z on Cas_n while Cke=1");
                disable main_proc;
            end
            if ((We_n === 1'bx) || (We_n === 1'bz)) begin
                issue_error("X/Z on We_n while Cke=1");
                disable main_proc;
            end
        end

        cmd            = decode_cmd(Cs_n, Ras_n, Cas_n, We_n, Cke);
        bank           = Ba;
        row            = Addr[ROW_BITS-1:0];
        col            = Addr[COL_BITS-1:0];
        auto_precharge = Addr[10];
        precharge_all  = Addr[10];

        dqm_pipe[1] <= dqm_pipe[0];
        dqm_pipe[0] <= {Udqm, Ldqm};

        if (!init_seen_cke_high && Cke) begin
            init_seen_cke_high = 1'b1;

            if ($realtime < POWERUP_STABLE_TIME) begin
                issue_error($sformatf("CKE high at %0.3f ns before 200 us power-up delay",
                                      $realtime));
            end
        end

        if (in_self_refresh) begin
            dq_oe = 1'b0;

            if (!cke_prev && Cke) begin
                in_self_refresh        = 1'b0;
                last_self_refresh_exit = $realtime;
                refresh_times.delete();

                if (DEBUG) begin
                    $display("%0t %s SELF REFRESH EXIT", $time, CHIP_NAME);
                end
            end

            cke_prev <= Cke;
            disable main_proc;
        end

        if (!cke_prev && Cke) begin
            if (in_power_down) begin
                in_power_down = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s POWER DOWN EXIT", $time, CHIP_NAME);
                end

                cke_prev <= Cke;
                disable main_proc;
            end

            if (in_clock_suspend) begin
                in_clock_suspend = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s CLOCK SUSPEND EXIT", $time, CHIP_NAME);
                end

                cke_prev <= Cke;
                disable main_proc;
            end
        end

        if (cke_prev && !Cke) begin
            if (cmd == CMD_SREF) begin
                if (!all_banks_idle()) begin
                    issue_error("SELF REFRESH entry while banks active");
                end

                in_self_refresh = 1'b1;
                dq_oe = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s SELF REFRESH ENTRY", $time, CHIP_NAME);
                end
            end else if (burst.active) begin
                in_clock_suspend = 1'b1;
                dq_oe = 1'b0;
            end else if (all_banks_idle()) begin
                in_power_down = 1'b1;
                dq_oe = 1'b0;
            end else begin
                in_clock_suspend = 1'b1;
                dq_oe = 1'b0;
            end

            cke_prev <= Cke;
            disable main_proc;
        end

        if (!Cke) begin
            dq_oe <= 1'b0;
            cke_prev <= Cke;
            disable main_proc;
        end

        if (burst.active && burst.is_read) begin
            advance_read_burst();
        end else begin
            dq_oe = 1'b0;
        end

        if (DEBUG && cmd != CMD_NOP && cmd != CMD_DESL) begin
            $display("%0t %s CMD=%s BA=%0d ADDR=%04h DQM=%b%b CS#=%b",
                     $time,
                     CHIP_NAME,
                     cmd_name(cmd),
                     bank,
                     Addr,
                     Udqm,
                     Ldqm,
                     Cs_n);
        end

        check_init_before_normal_cmd(cmd);

        unique case (cmd)
            CMD_DESL,
            CMD_NOP: begin
                if (burst.active && burst.is_write) begin
                    consume_write_data();
                end
            end

            CMD_ACT: begin
                if (burst.active && burst.is_write) begin
                    issue_warn("ACT issued while write burst active; terminating write burst");
                    stop_burst();
                end

                do_activate(bank, row);
            end

            CMD_READ: begin
                do_read(bank, col, auto_precharge);
            end

            CMD_WRIT: begin
                do_write(bank, col, auto_precharge);
            end

            CMD_PRE: begin
                if (burst.active) begin
                    stop_burst();
                end

                do_precharge(
                    bank,
                    precharge_all,
                    precharge_all ? "command all" : "command"
                );

                if (precharge_all) begin
                    init_seen_precharge_all = 1'b1;
                end
            end

            CMD_AREF: begin
                stop_burst();
                do_auto_refresh();
            end

            CMD_MRS: begin
                if (!all_banks_idle()) begin
                    issue_error("MRS while one or more banks active");
                end

                check_time_min("tMRD MRS-to-MRS/command",
                               last_mrs,
                               tMRD_MIN);

                load_mode_register(Addr);
                last_mrs      = $realtime;
                init_seen_mrs = 1'b1;
            end

            CMD_BST: begin
                do_burst_stop();
            end

            CMD_SREF: begin
                if (!all_banks_idle()) begin
                    issue_error("SELF REFRESH command while banks active");
                end

                in_self_refresh = 1'b1;
                stop_burst();
            end

            default: begin
                issue_warn($sformatf("unhandled command %0d", cmd));
            end
        endcase

        for (int i = 0; i < BANKS; i++) begin
            if (bank_open[i]) begin
                if (($realtime - last_activate[i]) > tRAS_MAX) begin
                    issue_error($sformatf("tRAS(max) violation bank %0d active for %0.3f ns max=%0.3f ns",
                                          i,
                                          $realtime - last_activate[i],
                                          tRAS_MAX));
                end
            end
        end

        cke_prev <= Cke;
    end

    // -------------------------------------------------------------------------
    // Testbench helper tasks
    // -------------------------------------------------------------------------

    task automatic clear_memory();
        begin
            mem.delete();
        end
    endtask

    task automatic poke(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        input data_t value
    );
        begin
            mem[make_key(bank, row, col)] = value;
        end
    endtask

    task automatic peek(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        output data_t value
    );
        begin
            value = mem_read(bank, row, col);
        end
    endtask

    // Sparse snapshot format: "<key_hex> <data_hex>" per line.
    //   key  = 7 hex digits = {bank[1:0], row[12:0], col[9:0]} (25 bits)
    //   data = 4 hex digits (16 bits)
    // Lines whose first two tokens don't match this layout are skipped, so
    // "//" or "#" comment lines and blank lines pass through harmlessly.
    task automatic dump_memory(input string filename);
        int       fd;
        mem_key_t k;
        int unsigned count;
        begin
            fd = $fopen(filename, "w");
            if (fd == 0) begin
                $error("%s: dump_memory failed to open '%s' for write",
                       CHIP_NAME, filename);
                return;
            end

            $fdisplay(fd, "// %s memory dump @ %0t", CHIP_NAME, $time);
            count = 0;
            if (mem.first(k)) begin
                do begin
                    $fdisplay(fd, "%07h %04h", k, mem[k]);
                    count++;
                end while (mem.next(k));
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s dumped %0d entries to '%s'",
                         $time, CHIP_NAME, count, filename);
            end
        end
    endtask

    task automatic load_memory(input string filename);
        int       fd;
        int       code;
        string    line;
        mem_key_t key;
        data_t    value;
        int unsigned loaded;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("%s: load_memory failed to open '%s' for read",
                       CHIP_NAME, filename);
                return;
            end

            loaded = 0;
            while ($fgets(line, fd) != 0) begin
                code = $sscanf(line, "%h %h", key, value);
                if (code == 2) begin
                    mem[key] = value;
                    loaded++;
                end
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s loaded %0d entries from '%s'",
                         $time, CHIP_NAME, loaded, filename);
            end
        end
    endtask

    // Load a contiguous ROM image into this chip starting at `word_base`,
    // one 16-bit value per non-blank/non-comment line of `filename` (the
    // standard $readmemh-style format, minus the @address syntax). word_base
    // is a chip-local 25-bit word address: bits [24:23]=bank, [22:10]=row,
    // [9:0]=col, matching make_key().
    task automatic load_rom_hex(input string filename, input int unsigned word_base);
        int          fd;
        string       line;
        data_t       value;
        logic [24:0] word_idx;
        int unsigned loaded;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("%s: load_rom_hex failed to open '%s' for read",
                       CHIP_NAME, filename);
                return;
            end

            word_idx = word_base[24:0];
            loaded   = 0;

            while ($fgets(line, fd) != 0) begin
                if ($sscanf(line, "%h", value) == 1) begin
                    if ((word_base + loaded) >= (1 << 25)) begin
                        $error("%s: load_rom_hex word %0d overflows chip (32M words)",
                               CHIP_NAME, word_base + loaded);
                        break;
                    end
                    mem[mem_key_t'(word_idx)] = value;
                    word_idx++;
                    loaded++;
                end
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s load_rom_hex loaded %0d words from '%s' (word_base=%0d)",
                         $time, CHIP_NAME, loaded, filename, word_base);
            end
        end
    endtask

    // Post-mortem state dump. Prints every piece of chip state a controller
    // bug might depend on: counters, mode register, per-bank activity, the
    // current burst, power-management flags, init-checker progress, and a
    // one-line refresh summary. Cheap to call repeatedly during a failing
    // test or once at end-of-test.
    task automatic dump_state();
        int i;
        begin
            $display("===== %s state @ %0t =====", CHIP_NAME, $time);
            $display("  counters: errors=%0d warnings=%0d",
                     error_count, warning_count);
            $display("  mode reg: BL=%0d full_page=%0b BT=%s CL=%0d WBL=%s",
                     burst_length,
                     burst_full_page,
                     burst_interleaved ? "interleaved" : "sequential",
                     cas_latency,
                     write_burst_single ? "single" : "burst");
            $display("  power:    pd=%0b sref=%0b clk_susp=%0b",
                     in_power_down, in_self_refresh, in_clock_suspend);
            $display("  init:     cke_high=%0b pre_all=%0b mrs=%0b aref_count=%0d",
                     init_seen_cke_high,
                     init_seen_precharge_all,
                     init_seen_mrs,
                     init_auto_refresh_count);
            $display("  refresh:  queued=%0d / %0d last_refresh=%0.3f ns",
                     refresh_times.size(), REFRESHES_PER_WINDOW, last_refresh);

            for (i = 0; i < BANKS; i++) begin
                $display("  bank %0d:   open=%0b row=%0d last_act=%0.3f last_rd=%0.3f last_wr=%0.3f last_pre=%0.3f",
                         i,
                         bank_open[i],
                         open_row[i],
                         last_activate[i],
                         last_read[i],
                         last_write[i],
                         last_precharge[i]);
            end

            if (burst.active) begin
                $display("  burst:    %s bank=%0d row=%0d start_col=%0d idx=%0d len=%0d lat=%0d ap=%0b full=%0b il=%0b",
                         burst.is_read ? "READ" : (burst.is_write ? "WRITE" : "?"),
                         burst.bank,
                         burst.row,
                         burst.start_col,
                         burst.index,
                         burst.len,
                         burst.latency,
                         burst.auto_precharge,
                         burst.full_page,
                         burst.interleaved);
            end else begin
                $display("  burst:    idle");
            end
        end
    endtask

    task automatic report_refresh_status();
        begin
            $display("%0t %s REFRESH_STATUS count=%0d last_refresh=%0.3f ns",
                     $time,
                     CHIP_NAME,
                     refresh_times.size(),
                     last_refresh);

            if (refresh_times.size() == REFRESHES_PER_WINDOW) begin
                $display("%0t %s REFRESH_WINDOW span=%0.3f ns limit=%0.3f ns",
                         $time,
                         CHIP_NAME,
                         refresh_times[refresh_times.size()-1] - refresh_times[0],
                         tREF_WINDOW);
            end
        end
    endtask

endmodule
