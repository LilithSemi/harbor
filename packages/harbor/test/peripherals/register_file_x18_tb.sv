// Random reads, writes and byte enables against a plain array.
module tb;
  localparam int DEPTH = @DEPTH@;
  localparam int WIDTH = @WIDTH@;
  localparam bit RESZ = @RESZ@;
  localparam int AW = $clog2(DEPTH);
  logic clk = 0, reset = 0;
  logic [AW-1:0] rd0_addr = 0, rd1_addr = 0, wr_addr = 0;
  logic wr_en = 0;
  logic [WIDTH-1:0] wr_data = 0;
  logic [WIDTH/8-1:0] wr_strb = 0;
  wire [WIDTH-1:0] rd0_data, rd1_data;
  wire wr_ready;
  @NAME@ dut (.*@PORTS@);

  logic [WIDTH-1:0] ref_mem [0:DEPTH-1];
  logic [WIDTH-1:0] expect0, expect1;
  logic expect_valid = 0;
  int errors = 0;

  always #5 clk = ~clk;

  function automatic logic [WIDTH-1:0] merged(logic [WIDTH-1:0] old);
    logic [WIDTH-1:0] r = old;
    for (int b = 0; b < WIDTH / 8; b++)
      if (wr_strb[b]) r[8*b +: 8] = wr_data[8*b +: 8];
    return r;
  endfunction

  // The read data of a cycle shows the write of the same cycle.
  function automatic logic [WIDTH-1:0] seen_at(logic [AW-1:0] a);
    logic [WIDTH-1:0] s = ref_mem[a];
    if (wr_en && !reset && wr_addr == a) s = merged(s);
    if (RESZ && a == 0) s = '0;
    return s;
  endfunction

  always @(posedge clk) begin
    expect0 <= seen_at(rd0_addr);
    expect1 <= seen_at(rd1_addr);
    if (wr_en && !reset) ref_mem[wr_addr] = merged(ref_mem[wr_addr]);
    expect_valid <= 1;
  end

  always @(negedge clk) begin
    if (expect_valid && rd0_data !== expect0) begin
      errors++;
      if (errors < 5) $display("rd0 %h want %h got %h", rd0_addr, expect0, rd0_data);
    end
    if (@NRD@ == 2 && expect_valid && rd1_data !== expect1) begin
      errors++;
      if (errors < 5) $display("rd1 %h want %h got %h", rd1_addr, expect1, rd1_data);
    end
  end

  initial begin
    int seed = 7;
    for (int i = 0; i < DEPTH; i++) ref_mem[i] = 'x;
    // Fill every word once so no read sees an unwritten word.
    for (int i = 0; i < DEPTH; i++) begin
      @(negedge clk);
      wr_en = 1; wr_addr = i; wr_strb = '1;
      wr_data = {$random(seed), $random(seed)};
      rd0_addr = $random(seed);
      rd1_addr = $random(seed);
    end
    for (int i = 0; i < 200000; i++) begin
      @(negedge clk);
      reset = ($random(seed) % 97) == 0;
      wr_en = $random(seed) % 2;
      wr_strb = $random(seed);
      wr_addr = (($random(seed) % 4) == 0) ? rd0_addr : $random(seed);
      wr_data = {$random(seed), $random(seed)};
      rd0_addr = (($random(seed) % 4) == 0) ? wr_addr : $random(seed);
      rd1_addr = (($random(seed) % 4) == 0) ? wr_addr : $random(seed);
    end
    @(negedge clk);
    if (errors == 0) $display("PASS");
    else $display("FAIL %0d", errors);
    $finish;
  end
endmodule
