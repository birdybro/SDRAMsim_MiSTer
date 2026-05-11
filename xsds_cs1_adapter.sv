`timescale 1ns/1ps

// =============================================================================
// XSDS CS1-aware controller adapter
// =============================================================================
// Translates an existing MiSTer-style single-chip SDRAM controller bus to the
// XSDS v3.0 connector so a controller can transparently address the full
// 128 MB (both AS4C32M16SB chips on the board) instead of just the lower
// 64 MB it would reach on a stock MT48LC-style controller.
//
// Why this exists:
//   The XSDS connector exposes only `Cs1_n` and uses an on-board LVC1G04
//   inverter to drive chip 1's CS# from `~Cs1_n`. The hardware can NEVER
//   deselect both chips at the same time — whichever level `Cs1_n` sits at,
//   exactly one of the two chips is decoding commands. So a controller that
//   simply holds CS=0 always (the corpus convention) only ever touches chip 0,
//   and the upper 64 MB is unreachable.
//
//   This adapter fills that gap with two pieces of logic:
//
//     1. `ctrl_chip` (1 bit, driven by the controller) selects which chip
//        the *next* command should land on. It is wired straight through to
//        `Cs1_n` so chip 0 sees CS=0 when `ctrl_chip = 0` and chip 1 sees
//        CS=0 when `ctrl_chip = 1`.
//
//     2. When the controller deasserts its own `ctrl_cs_n` (the convention
//        many MiSTer controllers fall back to between bursts), the adapter
//        FORCES `{Ras_n, Cas_n, We_n} = 3'b111` on the XSDS bus. Without
//        this step the "selected" chip would see whatever the controller
//        happened to leave on those wires — usually fine on a single-chip
//        module but unsafe on the XSDS where exactly one chip is always
//        selected.
//
// Controller-side contract:
//   - Drive `ctrl_chip` synchronously with the command on `ctrl_*`.
//   - When holding `ctrl_cs_n = 0` permanently (the corpus pattern), use
//     `{Ras_n, Cas_n, We_n} = 3'b111` (NOP) to idle and the adapter behaves
//     transparently.
//   - When toggling `ctrl_cs_n`, the adapter does the right thing either way.
//   - Both chips must be initialized independently (PRE-ALL → 2x AREF → MRS,
//     once with `ctrl_chip = 0` and once with `ctrl_chip = 1`) before issuing
//     normal commands. Refreshes must also be issued against both chips.
//
// Drop-in compatibility:
//   If a controller does not know about `ctrl_chip`, tie it to 1'b0 at the
//   adapter port and the resulting behavior is identical to a 64 MB single-
//   chip SDRAM — every command lands on chip 0, chip 1 stays idle (other
//   than its independent refresh / init requirements, which the controller
//   does still have to satisfy).
//
// DQ is not routed through this module. Wire the controller's DQ and the
// XSDS module's `Dq` together at the testbench / top level so both chips and
// the controller share the same tristate bus.
//
// Simulation-only. Pure combinational — no clocked state.
// =============================================================================

module xsds_cs1_adapter (
    // Controller-side command bus.
    input  wire        ctrl_cs_n,
    input  wire        ctrl_ras_n,
    input  wire        ctrl_cas_n,
    input  wire        ctrl_we_n,
    input  wire [1:0]  ctrl_ba,
    input  wire [12:0] ctrl_addr,

    // Selects which chip the current command targets:
    //   0 -> chip 0 (lower 64 MB, Cs1_n = 0)
    //   1 -> chip 1 (upper 64 MB, Cs1_n = 1)
    input  wire        ctrl_chip,

    // XSDS module command bus.
    output wire        xsds_cs1_n,
    output wire        xsds_ras_n,
    output wire        xsds_cas_n,
    output wire        xsds_we_n,
    output wire [1:0]  xsds_ba,
    output wire [12:0] xsds_addr
);

    // Whenever the controller asserts CS, pass its RAS/CAS/WE through. When
    // the controller deasserts CS, force NOP encoding so the chip selected
    // by ctrl_chip doesn't decode whatever the controller left on those
    // wires. ctrl_cs_n is active-low on the controller side.
    wire ctrl_active = ~ctrl_cs_n;

    assign xsds_cs1_n = ctrl_chip;
    assign xsds_ras_n = ctrl_active ? ctrl_ras_n : 1'b1;
    assign xsds_cas_n = ctrl_active ? ctrl_cas_n : 1'b1;
    assign xsds_we_n  = ctrl_active ? ctrl_we_n  : 1'b1;
    assign xsds_ba    = ctrl_ba;
    assign xsds_addr  = ctrl_addr;

endmodule
