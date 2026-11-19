// Functional model of the RAMB36E1 modes that Harbor builds, as UG473
// describes them. It models:
//   - TDP x18 and x36: port A writes with one enable for each byte, port B reads.
//   - SDP x72: port A reads, port B writes with eight byte enables.
// A read of the word that a write changes in the same cycle returns the old
// word when the write port is READ_FIRST and X otherwise (UG473 Table 1-4).
// The model stops the simulation on any other use.
module RAMB36E1 #(
  parameter RAM_MODE = "TDP",
  parameter integer READ_WIDTH_A = 0,
  parameter integer WRITE_WIDTH_A = 0,
  parameter integer READ_WIDTH_B = 0,
  parameter integer WRITE_WIDTH_B = 0,
  parameter WRITE_MODE_A = "WRITE_FIRST",
  parameter WRITE_MODE_B = "WRITE_FIRST",
  parameter integer DOA_REG = 0,
  parameter integer DOB_REG = 0
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
  localparam bit X18 = RAM_MODE == "TDP" && READ_WIDTH_B == 18;
  localparam bit X36 = RAM_MODE == "TDP" && READ_WIDTH_B == 36;
  localparam bit S72 = RAM_MODE == "SDP" && READ_WIDTH_A == 72;

  // Each byte lane takes nine bits, the byte and its parity bit.
  logic [71:0] mem [0:2047];
  logic [10:0] a_idx, b_idx;
  assign a_idx = X18 ? ADDRARDADDR[14:4] : X36 ? {1'b0, ADDRARDADDR[14:5]}
                                         : {2'b0, ADDRARDADDR[14:6]};
  assign b_idx = X18 ? ADDRBWRADDR[14:4] : X36 ? {1'b0, ADDRBWRADDR[14:5]}
                                         : {2'b0, ADDRBWRADDR[14:6]};

  assign CASCADEOUTA = 1'b0;
  assign CASCADEOUTB = 1'b0;
  assign DOPADOP = '0;
  assign DOPBDOP = '0;
  assign ECCPARITY = '0;
  assign RDADDRECC = '0;
  assign SBITERR = 1'b0;
  assign DBITERR = 1'b0;

  initial begin
    if (!(X18 && READ_WIDTH_A == 18 && WRITE_WIDTH_A == 18 &&
          WRITE_WIDTH_B == 18) &&
        !(X36 && READ_WIDTH_A == 36 && WRITE_WIDTH_A == 36 &&
          WRITE_WIDTH_B == 36) &&
        !(S72 && WRITE_WIDTH_B == 72 && WRITE_WIDTH_A == 0 &&
          READ_WIDTH_B == 0))
      $fatal(1, "model does not support this RAMB36E1 configuration");
    if (DOA_REG != 0 || DOB_REG != 0)
      $fatal(1, "the output register is not modelled");
  end

  wire read_first = S72 ? WRITE_MODE_B == "READ_FIRST"
                        : WRITE_MODE_A == "READ_FIRST";

  // TDP: write on port A, read on port B. SDP: read on port A, write on port B.
  wire wclk = S72 ? CLKBWRCLK : CLKARDCLK;
  wire wen = S72 ? ENBWREN : ENARDEN;
  wire [10:0] widx = S72 ? b_idx : a_idx;
  wire rclk = S72 ? CLKARDCLK : CLKBWRCLK;
  wire ren = S72 ? ENARDEN : ENBWREN;
  wire [10:0] ridx = S72 ? a_idx : b_idx;
  wire [7:0] we = S72 ? WEBWE : {4'b0, WEA};
  wire [31:0] di_lo = DIADI;
  wire [31:0] di_hi = DIBDI;
  localparam int LANES = X18 ? 2 : X36 ? 4 : 8;

  always @(posedge wclk) begin
    if (RSTRAMARSTRAM || RSTRAMB) $fatal(1, "RSTRAM is not modelled");
    if (!S72 && WEBWE != 0) $fatal(1, "port B must not write");
    if (S72 && WEA != 0) $fatal(1, "WEA is unused in SDP mode");
    if (X18 && WEA[3:2] != 0) $fatal(1, "WEA[3:2] is unused in x18 mode");
    if (wen)
      for (int l = 0; l < LANES; l++)
        if (we[l]) begin
          if (S72)
            mem[widx][8*l +: 8] <= l < 4 ? di_lo[8*l +: 8]
                                         : di_hi[8*(l-4) +: 8];
          else
            mem[widx][9*l +: 9] <= {DIPADIP[l], di_lo[8*l +: 8]};
        end
  end

  function automatic logic [31:0] word_bytes(logic [71:0] w, int first);
    logic [31:0] r = '0;
    for (int l = 0; l < 4; l++)
      if (X18 ? l < 2 : 1)
        r[8*l +: 8] = S72 ? w[8*(first+l) +: 8] : w[9*l +: 8];
    return r;
  endfunction

  logic [31:0] rd_lo, rd_hi;
  logic [31:0] doa_q = '0, dob_q = '0;
  always @(posedge rclk) begin
    if (ren) begin
      if (wen && we[LANES-1:0] != 0 && widx == ridx && !read_first) begin
        rd_lo = 'x;
        rd_hi = 'x;
      end else begin
        rd_lo = word_bytes(mem[ridx], 0);
        rd_hi = word_bytes(mem[ridx], 4);
      end
      if (S72) begin doa_q <= rd_lo; dob_q <= rd_hi; end
      else dob_q <= rd_lo;
    end
  end
  assign DOADO = doa_q;
  assign DOBDO = dob_q;
endmodule
