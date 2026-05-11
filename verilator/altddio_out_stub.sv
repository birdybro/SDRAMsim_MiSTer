`timescale 1ns/1ps

// Sim-only stub of Altera's altddio_out IP, used by MemTest_MiSTer's
// sdram.v to generate DRAM_CLK as a half-cycle-shifted output. We do not
// use DRAM_CLK in the testbench (the chip model takes its own clock
// directly), so this stub exists only to satisfy elaboration. The single
// `assign dataout` approximates the DDR output's behavior with MemTest's
// fixed parameters (datain_h = 0, datain_l = 1) — dataout follows ~outclock.

module altddio_out #(
    parameter extend_oe_disable    = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output         = "OFF",
    parameter lpm_hint              = "UNUSED",
    parameter lpm_type              = "altddio_out",
    parameter oe_reg                = "UNREGISTERED",
    parameter power_up_high         = "OFF",
    parameter width                 = 1
) (
    input  wire [width-1:0] datain_h,
    input  wire [width-1:0] datain_l,
    input  wire             outclock,
    output wire [width-1:0] dataout,
    input  wire             aclr,
    input  wire             aset,
    input  wire             oe,
    input  wire             outclocken,
    input  wire             sclr,
    input  wire             sset
);
    assign dataout = outclock ? datain_h : datain_l;
endmodule
