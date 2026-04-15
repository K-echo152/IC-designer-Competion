`timescale 1ns / 1ps
//============================================================================
// twiddle_rom.v - Twiddle Factor ROM for 1024-point FFT
//============================================================================
// Stores 512 complex twiddle factors W_1024^k, k=0..511
// Format: 32-bit per entry, {cos[15:0], -sin[15:0]}, Q1.15 signed
// Loaded from twiddle_init.hex via $readmemh
// Inferred as BRAM by Xilinx Vivado
//============================================================================

module twiddle_rom (
    input  wire        clk,
    input  wire [8:0]  addr,    // 0..511
    output reg  [31:0] dout     // {wr[15:0], wi[15:0]}
);

    (* ram_style = "block" *) reg [31:0] rom [0:511];

    initial begin
        $readmemh("twiddle_init.hex", rom);
    end

    // Synchronous read - 1 cycle latency
    always @(posedge clk) begin
        dout <= rom[addr];
    end

endmodule
