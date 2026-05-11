`timescale 1ns/1ps

// Minimal stub used solely to lint the model under an open-source
// simulator. Two notes shaping its design:
//
// 1. The model exposes Dq as an inout. Some sim engines do not
//    support tristate at a top-level port, so this stub IS the top
//    and Dq is an internal wire here.
// 2. Some sim engines also struggle with the wrapper's inout pass-
//    through through hierarchy. Run with --bbox-unsup to let those
//    constructs through as black boxes — lint will still flag every
//    genuine syntax / width / unused-signal issue in the model.
//
// Run (see verilator/Makefile for the full command).

module verilator_lint_stub (
    input  logic Clk
);
    logic        Cs1_n;
    logic        Ras_n;
    logic        Cas_n;
    logic        We_n;
    logic [1:0]  Ba;
    logic [12:0] Addr;

    wire  [15:0] Dq;

    initial begin
        Cs1_n = 1'b1;
        Ras_n = 1'b1;
        Cas_n = 1'b1;
        We_n  = 1'b1;
        Ba    = 2'b00;
        Addr  = 13'h0000;
    end

    xsds_128mbyte_sdram_model u_dut (
        .Clk   (Clk),
        .Cs1_n (Cs1_n),
        .Ras_n (Ras_n),
        .Cas_n (Cas_n),
        .We_n  (We_n),
        .Ba    (Ba),
        .Addr  (Addr),
        .Dq    (Dq)
    );

endmodule
