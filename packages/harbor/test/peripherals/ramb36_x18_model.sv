// Functional model of RAMB36E1 in true dual-port x18 mode, as UG473 describes
// it. Port A writes with one enable for each byte and port B reads. A read of
// the word that a write changes in the same cycle returns the old word when
// WRITE_MODE_A is READ_FIRST and X otherwise (UG473 Table 1-4). The model stops
// the simulation on any other use.
module RAMB36E1 #(
  parameter RAM_MODE = "TDP",
  parameter integer READ_WIDTH_A = 0,
  parameter integer WRITE_WIDTH_A = 0,
  parameter integer READ_WIDTH_B = 0,
  parameter integer WRITE_WIDTH_B = 0,
  parameter WRITE_MODE_A = "WRITE_FIRST"
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
  // Bits [8:0] hold {DIPADIP[0], DIADI[7:0]}, bits [17:9] hold the next byte.
  logic [17:0] mem [0:2047];
  wire [10:0] a_idx = ADDRARDADDR[14:4];
  wire [10:0] b_idx = ADDRBWRADDR[14:4];

  assign CASCADEOUTA = 1'b0;
  assign CASCADEOUTB = 1'b0;
  assign DOADO = '0;
  assign DOPADOP = '0;
  assign DOPBDOP = '0;
  assign ECCPARITY = '0;
  assign RDADDRECC = '0;
  assign SBITERR = 1'b0;
  assign DBITERR = 1'b0;

  initial begin
    if (RAM_MODE != "TDP" || READ_WIDTH_A != 18 || WRITE_WIDTH_A != 18 ||
        READ_WIDTH_B != 18 || WRITE_WIDTH_B != 18)
      $fatal(1, "model supports only RAMB36E1 TDP x18");
  end

  always @(posedge CLKARDCLK) begin
    if (WEA[3:2] != 0) $fatal(1, "WEA[3:2] is unused in x18 mode");
    if (ENARDEN) begin
      if (WEA[0]) mem[a_idx][8:0] <= {DIPADIP[0], DIADI[7:0]};
      if (WEA[1]) mem[a_idx][17:9] <= {DIPADIP[1], DIADI[15:8]};
    end
  end

  always @(posedge CLKBWRCLK) begin
    if (WEBWE != 0) $fatal(1, "port B must not write");
    if (ENBWREN) begin
      if (ENARDEN && WEA[1:0] != 0 && a_idx == b_idx && WRITE_MODE_A != "READ_FIRST")
        DOBDO <= 'x;
      else
        DOBDO <= {16'b0, mem[b_idx][16:9], mem[b_idx][7:0]};
    end
  end
endmodule
