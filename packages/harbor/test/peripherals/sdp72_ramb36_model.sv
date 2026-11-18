// Small functional model for exercising Harbor's generated SDP wiring.
// It models only the 72-bit simple-dual-port mode used by the test: port A
// reads 64 data bits, port B writes byte lanes, and reset does not clear RAM.
module RAMB36E1 #(
  parameter RAM_MODE = "TDP",
  parameter integer READ_WIDTH_A = 0,
  parameter integer WRITE_WIDTH_A = 0,
  parameter integer READ_WIDTH_B = 0,
  parameter integer WRITE_WIDTH_B = 0
) (
  output logic CASCADEOUTA, CASCADEOUTB,
  output logic [31:0] DOADO, DOBDO,
  output logic [3:0] DOPADOP, DOPBDOP,
  output logic [7:0] ECCPARITY,
  output logic [8:0] RDADDRECC,
  output logic SBITERR, DBITERR,
  input logic ENARDEN, CLKARDCLK, RSTRAMARSTRAM, RSTREGARSTREG,
  input logic CASCADEINA, REGCEAREGCE,
  input logic ENBWREN, CLKBWRCLK, RSTRAMB, RSTREGB,
  input logic CASCADEINB, REGCEB, INJECTDBITERR, INJECTSBITERR,
  input logic [15:0] ADDRARDADDR, ADDRBWRADDR,
  input logic [31:0] DIADI, DIBDI,
  input logic [3:0] DIPADIP, DIPBDIP,
  input logic [3:0] WEA,
  input logic [7:0] WEBWE
);
  logic [63:0] mem [0:511];
  wire [8:0] rd_index = ADDRARDADDR[14:6];
  wire [8:0] wr_index = ADDRBWRADDR[14:6];

  assign CASCADEOUTA = 1'b0;
  assign CASCADEOUTB = 1'b0;
  assign DOPADOP = '0;
  assign DOPBDOP = '0;
  assign ECCPARITY = '0;
  assign RDADDRECC = '0;
  assign SBITERR = 1'b0;
  assign DBITERR = 1'b0;

  initial begin
    if (RAM_MODE != "SDP" || READ_WIDTH_A != 72 || WRITE_WIDTH_B != 72 ||
        WRITE_WIDTH_A != 0 || READ_WIDTH_B != 0)
      $fatal(1, "test model only supports RAMB36E1 SDP 72-bit mode");
  end

  // Port A is synchronous, read-first. Writes occur only on port B.
  always_ff @(posedge CLKARDCLK) begin
    if (ENARDEN) begin
      if (RSTRAMARSTRAM) begin
        DOADO <= '0;
        DOBDO <= '0;
      end else begin
        DOADO <= mem[rd_index][31:0];
        DOBDO <= mem[rd_index][63:32];
      end
    end
  end

  // Each WEBWE bit enables one byte. BRAM contents intentionally survive reset.
  always_ff @(posedge CLKBWRCLK) begin
    if (ENBWREN && !RSTRAMB) begin
      for (int b = 0; b < 8; b++) begin
        if (WEBWE[b]) mem[wr_index][8*b +: 8] <= b < 4
            ? DIADI[8*b +: 8] : DIBDI[8*(b-4) +: 8];
      end
    end
  end
endmodule
