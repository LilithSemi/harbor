// Random reads, writes and byte enables against a plain array.
module tb;
  localparam int DEPTH = 2048;
  logic clk = 0, reset = 0;
  logic [10:0] rd0_addr = 0, wr_addr = 0;
  logic wr_en = 0;
  logic [63:0] wr_data = 0;
  logic [7:0] wr_strb = 0;
  wire [63:0] rd0_data;
  wire wr_ready;
  DUT dut (.*);

  logic [63:0] ref_mem [0:DEPTH-1];
  logic [63:0] expect_q;
  logic expect_valid = 0;
  int errors = 0;

  always #5 clk = ~clk;

  function automatic logic [63:0] merged(logic [63:0] old);
    logic [63:0] r = old;
    for (int b = 0; b < 8; b++)
      if (wr_strb[b]) r[8*b +: 8] = wr_data[8*b +: 8];
    return r;
  endfunction

  // The read data of a cycle shows the write of the same cycle.
  always @(posedge clk) begin
    logic [63:0] seen;
    seen = ref_mem[rd0_addr];
    if (wr_en && !reset && wr_addr == rd0_addr) seen = merged(seen);
    if (wr_en && !reset) ref_mem[wr_addr] = merged(ref_mem[wr_addr]);
    expect_q <= seen;
    expect_valid <= 1;
  end

  always @(negedge clk) begin
    if (expect_valid && rd0_data !== expect_q) begin
      errors++;
      if (errors < 5)
        $display("mismatch %h want %h got %h", rd0_addr, expect_q, rd0_data);
    end
  end

  initial begin
    int seed = 7;
    for (int i = 0; i < DEPTH; i++) ref_mem[i] = 64'hx;
    // Fill every word once so no read sees an unwritten word.
    for (int i = 0; i < DEPTH; i++) begin
      @(negedge clk);
      wr_en = 1; wr_addr = i; wr_strb = 8'hff;
      wr_data = {$random(seed), $random(seed)};
      rd0_addr = $random(seed);
    end
    for (int i = 0; i < 200000; i++) begin
      @(negedge clk);
      reset = ($random(seed) % 97) == 0;
      wr_en = $random(seed) % 2;
      wr_strb = $random(seed);
      wr_addr = (($random(seed) % 4) == 0) ? rd0_addr : $random(seed);
      wr_data = {$random(seed), $random(seed)};
      rd0_addr = (($random(seed) % 4) == 0) ? wr_addr : $random(seed);
    end
    @(negedge clk);
    if (errors == 0) $display("PASS");
    else $display("FAIL %0d", errors);
    $finish;
  end
endmodule
