module register_file_sdp72_generated_tb;
  logic clk = 0;
  always #5 clk = ~clk;

  logic reset64 = 1, we64 = 0;
  logic [2:0] wa64 = 0, ra64 = 0;
  logic [63:0] wd64 = 0, q64;
  logic ready64;
  HarborRegisterFile_E8_W64_R1_W1_B1_L1_BUF0_Z1_xilinxSdp72 rf64 (
    .clk(clk), .reset(reset64), .rd0_addr(ra64), .wr_en(we64),
    .wr_addr(wa64), .wr_data(wd64), .rd0_data(q64), .wr_ready(ready64)
  );

  logic reset56 = 1, we56 = 0;
  logic [2:0] wa56 = 0, ra56 = 0;
  logic [55:0] wd56 = 0, q56;
  logic ready56;
  HarborRegisterFile_E8_W56_R1_W1_B1_L1_BUF0_Z1_xilinxSdp72 rf56 (
    .clk(clk), .reset(reset56), .rd0_addr(ra56), .wr_en(we56),
    .wr_addr(wa56), .wr_data(wd56), .rd0_data(q56), .wr_ready(ready56)
  );

  logic resetR2 = 1, weR2 = 0;
  logic [2:0] waR2 = 0, raR20 = 0, raR21 = 0;
  logic [63:0] wdR2 = 0, qR20, qR21;
  logic readyR2;
  HarborRegisterFile_E8_W64_R2_W1_B1_L1_BUF0_Z0_xilinxSdp72 rf64_r2_z0 (
    .clk(clk), .reset(resetR2), .rd0_addr(raR20), .rd1_addr(raR21),
    .wr_en(weR2), .wr_addr(waR2), .wr_data(wdR2), .rd0_data(qR20),
    .rd1_data(qR21), .wr_ready(readyR2)
  );

  logic reset58 = 1, we58 = 0;
  logic [2:0] wa58 = 0, ra58 = 0;
  logic [57:0] wd58 = 0, q58;
  logic ready58;
  HarborRegisterFile_E8_W58_R1_W1_B1_L1_BUF0_Z0_xilinxSdp72 rf58_z0 (
    .clk(clk), .reset(reset58), .rd0_addr(ra58), .wr_en(we58),
    .wr_addr(wa58), .wr_data(wd58), .rd0_data(q58), .wr_ready(ready58)
  );

  task automatic tick;
    @(posedge clk); #1;
  endtask

  task automatic check64(input logic [63:0] want, input string label);
    if (q64 !== want) $fatal(1, "%s: got %016h want %016h", label, q64, want);
  endtask

  task automatic check56(input logic [55:0] want, input string label);
    if (q56 !== want) $fatal(1, "%s: got %014h want %014h", label, q56, want);
  endtask

  task automatic checkR2(input logic [63:0] want0, input logic [63:0] want1,
                         input string label);
    if (qR20 !== want0 || qR21 !== want1)
      $fatal(1, "%s: got %016h/%016h want %016h/%016h", label,
             qR20, qR21, want0, want1);
  endtask

  task automatic check58(input logic [57:0] want, input string label);
    if (q58 !== want) $fatal(1, "%s: got %015h want %015h", label, q58, want);
  endtask

  initial begin
    // Two reset clocks gate writes but do not clear BRAM storage.
    tick(); tick();
    reset64 = 0; reset56 = 0; resetR2 = 0; reset58 = 0;

    // Distinct high/low halves make upper-lane swaps or truncation visible.
    ra64 = 1; wa64 = 1; we64 = 1; wd64 = 64'hfedcba9876543210;
    ra56 = 1; wa56 = 1; we56 = 1; wd56 = 56'hfedcba98765432;
    tick();
    check64(64'hfedcba9876543210, "64-bit same-cycle forward");
    check56(56'hfedcba98765432, "56-bit same-cycle forward");

    we64 = 0; we56 = 0;
    tick();
    check64(64'hfedcba9876543210, "64-bit stored read");
    check56(56'hfedcba98765432, "56-bit stored read");

    // A different-address write must not disturb the current read.
    wa64 = 2; wd64 = 64'h0123456789abcdef;
    wa56 = 2; wd56 = 56'h0123456789abcd;
    we64 = 1; we56 = 1;
    tick();
    check64(64'hfedcba9876543210, "64-bit non-colliding read");
    check56(56'hfedcba98765432, "56-bit non-colliding read");

    // x0 ignores writes and reads zero.
    ra64 = 0; wa64 = 0; wd64 = 64'hfedcba9876543210;
    ra56 = 0; wa56 = 0; wd56 = 56'hfedcba98765432;
    tick();
    check64(64'h0, "64-bit x0");
    check56(56'h0, "56-bit x0");

    // Reset-time writes are dropped, and prior BRAM contents survive reset.
    reset64 = 1; reset56 = 1;
    ra64 = 1; wa64 = 1; wd64 = 64'h1111111122222222;
    ra56 = 1; wa56 = 1; wd56 = 56'h11111111222222;
    tick();
    check64(64'hfedcba9876543210, "64-bit reset retention");
    check56(56'hfedcba98765432, "56-bit reset retention");
    if (ready64 !== 1'b0 || ready56 !== 1'b0) $fatal(1, "wr_ready during reset");

    // R2/Z0 matches cache and FP-style files: both read replicas are
    // independently addressed and entry zero is ordinary storage.
    waR2 = 0; wdR2 = 64'hfedcba9876543210; weR2 = 1;
    raR20 = 0; raR21 = 1;
    tick();
    if (qR20 !== 64'hfedcba9876543210)
      $fatal(1, "R2/Z0 entry-zero forwarding got %016h", qR20);
    waR2 = 1; wdR2 = 64'h0123456789abcdef;
    raR20 = 0; raR21 = 1;
    tick();
    checkR2(64'hfedcba9876543210, 64'h0123456789abcdef,
            "R2/Z0 independent reads and forwarding");
    weR2 = 0;
    tick();
    checkR2(64'hfedcba9876543210, 64'h0123456789abcdef,
            "R2/Z0 stored reads including entry zero");

    // W58 uses all eight BRAM byte enables, with only bits 57:56 occupied in
    // the top byte. Z0 verifies that entry zero remains writable.
    we58 = 1; wa58 = 0; ra58 = 0; wd58 = 58'h3fedcba98765432;
    tick();
    check58(58'h3fedcba98765432, "W58/Z0 forwarding through top byte");
    we58 = 0;
    tick();
    check58(58'h3fedcba98765432, "W58/Z0 stored entry-zero read");

    $display("SDP72 generated RTL behavioral test passed");
    $finish;
  end
endmodule
