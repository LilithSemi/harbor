import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

// sim-only x2 DDR gearbox models (DQ/DQS/command IOLOGIC). Grounded in
// Lattice FPGA-TN-02035 ("ECP5 and ECP5-5G High-Speed I/O Interface") section
// 6.2: the ODDRX2/IDDRX2 family gears 1 fabric ([sclk]) cycle to 4 beats on
// the edge clock ([eclk], 2x sclk), 2 beats per eclk half. yosys
// techlibs/lattice/cells_bb_ecp5.v confirms the port names and order (it
// carries no behavior, so it is a port-fidelity reference only). None of
// this appears in the generated SV: each leaf below is `isSystemVerilogLeaf`,
// so `instantiationVerilog` emits only the declared ports, never this body.
//
// Beat framing: CLKDIVF makes SCLK rise just after the ECLK rising edge that
// starts a 4-beat group, so the SCLK levels seen at two ECLK edges in a row
// are (0,0) at beat 0, (0,1) at beat 1, (1,1) at beat 2 and (1,0) at beat 3.
// The word boundary is fixed to SCLK, as in the silicon gearbox, with no reset
// needed (IOLOGIC RST is pulsed while ECLK is stopped). The models need SCLK
// to change after the ECLK rising edge and before the falling one.
//
// Latency: TN-02035 gives no cell latencies, so these come from litedram's
// hardware-validated ECP5DDRPHY, which drives the command ODDRX2F, the write
// data ODDRX2DQA, and the DQSBUFM READ pulse at fixed SCLK offsets:
//  - Write: litedram puts the data on ODDRX2DQA 4 SCLK after the command on
//    ODDRX2F, and the DRAM wants it CWL (5 CK) after the command. That holds
//    only if ODDRX2F is 1 SCLK slower than ODDRX2DQA.
//  - Read: litedram raises READ 4 SCLK after the command. TN-02035 Table 6.3
//    wants READ about 5.5T before the preamble (no round trip), which puts
//    ODDRX2F at 4 SCLK of latency, so ODDRX2DQA (and DQSB/TSH) at 3.
//  - IDDRX2DQA at 3 SCLK puts litedram's read data at its read_latency
//    (cl_sys_latency + 10) with bitslip 0..3.
// Output cells: D is taken on the SCLK rising edge, delayed through SCLK
// registers, and sent out on ECLK edges, so Q only changes on an ECLK edge.
// [latency] counts SCLK groups from the fabric cycle that holds D to the
// group it goes out in (minimum 2).
Logic _x2Out(Logic eclk, Logic sclk, List<Logic> d, int latency, String name) {
  Logic word = d.rswizzle();
  for (var i = 0; i < latency - 1; i++) {
    final r = Logic(name: '${name}_sim_hold$i', width: 4);
    Sequential(sclk, [r < word]);
    word = r;
  }
  final prev = Logic(name: '${name}_sim_sclk_prev');
  final q = Logic(name: '${name}_sim_q');
  // The word for the whole group is taken at beat 0, since SCLK (and so the
  // last SCLK register) moves just after that ECLK edge.
  final cur = Logic(name: '${name}_sim_cur', width: 4);
  final phase = [prev, sclk ^ prev].swizzle();
  Sequential.multi(
    [eclk],
    [
      If(
        phase.eq(0),
        then: [cur < word, q < word[0]],
        orElse: [
          q <
              cases(
                phase,
                {for (var j = 1; j < 4; j++) Const(j, width: 2): cur[j]},
                defaultValue: cur[0],
                conditionalType: ConditionalType.unique,
              ),
        ],
      ),
      prev < sclk,
    ],
    negedgeTriggers: [eclk],
  );
  return q;
}

/// SCLK groups of latency for ODDRX2F (command and CK pads).
const int _oddrx2fLatency = 4;

/// SCLK groups of latency for ODDRX2DQA, ODDRX2DQSB, TSHX2DQA, TSHX2DQSA.
const int _oddrx2dqaLatency = 3;

/// SCLK groups from a DQ sample to its IDDRX2DQA Q output.
const int _iddrx2dqaLatency = 3;

/// ECP5 EHXPLLL: Primary PLL.
class Ecp5Ehxplll extends BridgeModule {
  Ecp5Ehxplll({
    required int clkiDiv,
    required int clkfbDiv,
    required int clkopDiv,
    required Logic clk,
    required Logic clkfb,
    Logic? rst,
    String feedbackPath = 'CLKOP',
    // Optional secondary output: same rules as CLKOP, with a static phase
    // shift in VCO cycles (CPHASE). A 90-degree shift of the CLKOP frequency
    // is clkosDiv/4 (the DDR PHY uses this for centered write data).
    int? clkosDiv,
    int clkosCphase = 0,
    int clkosFphase = 0,
    // Optional SECOND secondary output (CLKOS2): an independently phase-shifted
    // clock off the same VCO, same rules as CLKOS. The DLL-off DDR PHY uses it as
    // a per-beat read-capture clock (beat0 captured on CLKOS2, beat1 on CLKOS) so
    // each beat's capture edge can be tuned into its OWN eye. The strobeless x1
    // read cannot straddle both beats from a single phase. Emitted only when
    // [clkos2Div] != null, so every other PLL user stays byte-identical.
    int? clkos2Div,
    int clkos2Cphase = 0,
    // CLKOP coarse phase. Defaults to CLKOP_DIV/2 (a 50%-duty 0-degree output)
    // which a USED CLKOP (e.g. the sys clock) needs. When CLKOP is only the
    // FEEDBACK clock (FEEDBK_PATH=CLKOP, CLKOP not used as a clock: the DDR
    // PHY), pass 0: a non-zero feedback CPHASE rotates the VCO/CLKOS phase
    // (~180 deg at /2), which mis-aligns the DDR read capture by a beat.
    int? clkopCphase,
    // Whether to EMIT the CLKOP_ENABLE/CLKOP_CPHASE/CLKOP_FPHASE parameters. A
    // USED CLKOP (the sys clock) needs them. A FEEDBACK-ONLY CLKOP (the DDR PHY
    // PLL) must NOT emit them: the silicon-proven HEAD PHY PLL emitted none and
    // let the tool default the feedback waveform. Forcing them (even CPHASE=0)
    // changes the locked CLKOS (clk90) waveform so the two DDR capture edges no
    // longer straddle both beats. No CLKOS_CPHASE then lands both. Suppress to
    // restore HEAD's exact emission.
    bool emitClkopParams = true,
    super.name = 'pll',
  }) : super('EHXPLLL', isSystemVerilogLeaf: true) {
    clk = addInput('CLKI', clk);
    clkfb = addInput('CLKFB', clkfb);
    addInput('RST', rst ?? Const(0));
    addOutput('CLKOP');
    addOutput('CLKOS');
    addOutput('CLKOS2');
    addOutput('CLKOS3');
    addOutput('LOCK');
    addOutput('INTLOCK');

    createParameter('CLKI_DIV', '$clkiDiv');
    createParameter('CLKFB_DIV', '$clkfbDiv');
    createParameter('CLKOP_DIV', '$clkopDiv');
    // Per-output divider source select. ecppll emits these explicitly. Each
    // output (CLKOP=A, CLKOS=B, CLKOS2=C, CLKOS3=D) must select its OWN divider
    // tap or it falls back to a wrong/dead tap. The yosys/nextpnr EHXPLLL model
    // does NOT default OUTDIVIDER_MUXB to "DIVB", so a CLKOS used as a real
    // clock domain is dead without this (CLKOP's MUXA default happened to be
    // fine, masking the bug until a secondary output was used).
    createParameter('OUTDIVIDER_MUXA', '"DIVA"');
    createParameter('OUTDIVIDER_MUXB', '"DIVB"');
    createParameter('OUTDIVIDER_MUXC', '"DIVC"');
    createParameter('OUTDIVIDER_MUXD', '"DIVD"');
    // CLKOP needs an explicit enable and a coarse phase. ecppll emits
    // CLKOP_CPHASE ~= CLKOP_DIV/2 for a 50%-duty 0-degree output. Leaving it at
    // the default 0 yields a degenerate clock (ecppll warns "wrong CPHASE/FPHASE"
    // is a common failure), which made the sys PLL unusable on hardware.
    if (emitClkopParams) {
      createParameter('CLKOP_ENABLE', '"ENABLED"');
      createParameter('CLKOP_CPHASE', '${clkopCphase ?? (clkopDiv ~/ 2)}');
      createParameter('CLKOP_FPHASE', '0');
    }
    createParameter('FEEDBK_PATH', '"$feedbackPath"');
    if (clkosDiv != null) {
      createParameter('CLKOS_ENABLE', '"ENABLED"');
      createParameter('CLKOS_DIV', '$clkosDiv');
      createParameter('CLKOS_CPHASE', '$clkosCphase');
      createParameter('CLKOS_FPHASE', '$clkosFphase');
    }
    if (clkos2Div != null) {
      createParameter('CLKOS2_ENABLE', '"ENABLED"');
      createParameter('CLKOS2_DIV', '$clkos2Div');
      createParameter('CLKOS2_CPHASE', '$clkos2Cphase');
    }
  }
}

/// ECP5 DCCA: Dynamic clock control with clock mux.
class Ecp5Dcca extends BridgeModule {
  Ecp5Dcca({super.name = 'dcca'}) : super('DCCA', isSystemVerilogLeaf: true) {
    createPort('CLKI', PortDirection.input);
    createPort('CE', PortDirection.input);
    addOutput('CLKO');
  }
}

/// ECP5 BB: Bidirectional I/O buffer (maps to a TRELLIS_IO during
/// `synth_ecp5`). [i] is the drive value, [t] is the tristate control
/// (active-high: T=1 -> HiZ, T=0 -> drive [i]). [o] reads the pad and [b] is
/// the bidirectional pad net.
///
/// The TSHX2DQA/TSHX2DQSA write-OE shift registers must drive a top-level
/// tristate's T pin DIRECTLY (nextpnr's ECP5 packer asserts the TSH `Q` net
/// drives only a TRELLIS_IO `T`, with no fabric logic or extra loads). So the
/// owning module wires `t: tsh.q` straight in, with no inverter, and exposes
/// [b] as an inOut pad. The TSH T0/T1 polarity is chosen so Q is already the
/// active-high HiZ control that [t] wants.
class Ecp5Bb extends BridgeModule {
  /// Pad-read output (the value seen on the bidirectional pad).
  Logic get o => output('O');

  /// The bidirectional pad net.
  Logic get b => inOut('B');

  Ecp5Bb({
    required Logic i,
    required Logic t,
    required Logic b,
    super.name = 'bb',
  }) : super('BB', isSystemVerilogLeaf: true) {
    i = addInput('I', i);
    t = addInput('T', t);
    addOutput('O');
    // Bind the pad net AS the inOut source so the BB `.B` actually connects to
    // the parent pad (a post-construction `<=` from inOut('B') does NOT bind it.
    // The rohd_bridge inout-hierarchy idiom is source-at-construction, else
    // `.B()` emits empty and the pad is severed from the buffer).
    final pad = addInOut('B', b);
    // sim-only tristate model: T=0 drives I onto the pad, T=1 releases it to
    // Z so another driver (or a DRAM model) on the same net can be seen. O
    // always reflects the net. No effect on synth: this leaf emits only the
    // declared ports (yosys cells_bb_ecp5.v BB has no body either). It must
    // be a TriStateBuffer: a ROHD mux turns a selected Z into X.
    pad <= TriStateBuffer(i, enable: ~t, name: 'sim_tristate').out;
    // A floating pad reads 0: the ECP5 input default is PULLMODE DOWN. Two
    // drivers that disagree still read X.
    final o = output('O');
    void readPad() =>
        o.put(pad.value == LogicValue.z ? LogicValue.zero : pad.value);
    pad.glitch.listen((_) => readPad());
    Simulator.injectAction(readPad);
  }
}

/// ECP5 IB: Input buffer.
class Ecp5Ib extends BridgeModule {
  Ecp5Ib({super.name = 'ib'}) : super('IB', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// ECP5 OB: Output buffer.
class Ecp5Ob extends BridgeModule {
  Ecp5Ob({super.name = 'ob'}) : super('OB', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// The accesses of one DP16KD port at its last edge. The two ports use it to
/// find a collision on one edge, whichever port runs first.
class _Dp16kdAccess {
  late final Logic latch;
  int readTime = -1;
  int readWord = 0;
  int readBits = 0;
  int writeTime = -1;
  int writeWord = 0;
  int writeBits = 0;
}

/// Sim body for one DP16KD port over the shared [storage] of x18 words.
///
/// A `Sequential` takes the inputs at the edge, and the array access runs
/// at the end of that tick with those values. So the access always sees the
/// pre-edge inputs, whatever the build order. A set bit in [unknown] makes
/// that storage bit X.
///
/// A write and a read of the same bits by the two ports on one edge make the
/// read X. Two writes of the same bits on one edge make those bits X.
void _dp16kdPortSim({
  required List<int> storage,
  required List<int> unknown,
  required _Dp16kdAccess self,
  required _Dp16kdAccess other,
  required Logic clk,
  required Logic ce,
  required Logic oce,
  required Logic we,
  required Logic rst,
  required Logic cs,
  required Logic ad,
  required Logic di,
  required List<Logic> dout,
  required int width,
  required bool outReg,
  required String writeMode,
  required int csValue,
  required bool asyncReset,
  required String name,
}) {
  final sAd = Logic(name: '${name}_ad', width: 14);
  final sDi = Logic(name: '${name}_di', width: 18);
  final sCe = Logic(name: '${name}_ce');
  final sOce = Logic(name: '${name}_oce');
  final sWe = Logic(name: '${name}_we');
  final sRst = Logic(name: '${name}_rst');
  final sCs = Logic(name: '${name}_cs', width: 3);
  final latch = Logic(name: '${name}_latch', width: 18);
  final outQ = Logic(name: '${name}_outreg', width: 18);
  self.latch = latch;
  Simulator.injectAction(() {
    latch.put(0);
    outQ.put(0);
  });
  Sequential(clk, [
    sAd < ad,
    sDi < di,
    sCe < ce,
    sOce < oce,
    sWe < we,
    sRst < rst,
    sCs < cs,
  ]);

  // A port of [width] bits takes AD[13:shift] as its index, and an x18 word
  // holds perWord of its entries.
  final (int shift, int perWord) = switch (width) {
    18 => (4, 1),
    9 => (3, 2),
    4 => (2, 4),
    2 => (1, 8),
    _ => (0, 16),
  };
  List<int> bitsOf(int slot) {
    if (width == 18) return [for (var i = 0; i < 18; i++) i];
    if (width == 9) return [for (var i = 0; i < 9; i++) slot * 9 + i];
    // Narrow widths use only the 8 data bits of each 9-bit half.
    final perHalf = perWord ~/ 2;
    final base = (slot ~/ perHalf) * 9 + (slot % perHalf) * width;
    return [for (var i = 0; i < width; i++) base + i];
  }

  LogicValue read(int word, int slot) {
    final w = storage[word];
    final bits = bitsOf(slot);
    var v = 0;
    for (var i = 0; i < bits.length; i++) {
      if ((unknown[word] >> bits[i]) & 1 == 1) {
        return LogicValue.filled(18, LogicValue.x);
      }
      v |= ((w >> bits[i]) & 1) << i;
    }
    return LogicValue.ofInt(v, 18);
  }

  void access() {
    final resetNow = !asyncReset && sRst.value == LogicValue.one;
    if (outReg) {
      if (resetNow) {
        outQ.put(0);
      } else if (!sOce.value.isValid) {
        outQ.put(LogicValue.x);
      } else if (sOce.value.toBool()) {
        outQ.put(latch.value);
      }
    }
    final enable = sCe.value.isValid && sCs.value.isValid
        ? sCe.value.toBool() && sCs.value.toInt() == csValue
        : null;
    if (enable == false) {
      if (resetNow) latch.put(0);
      return;
    }
    if (resetNow) {
      // A synchronous reset also blocks the write (yosys: block_wr).
      latch.put(0);
      return;
    }
    if (enable == null || !sAd.value.isValid || !sWe.value.isValid) {
      latch.put(LogicValue.x);
      return;
    }
    final adv = sAd.value.toInt();
    final index = adv >> shift;
    final word = index ~/ perWord;
    final slot = index % perWord;
    final bits = bitsOf(slot);
    final now = Simulator.time;
    var mask = 0;
    for (final b in bits) {
      mask |= 1 << b;
    }

    // Records a read of this port and gives X if the other port wrote the
    // same bits on this edge.
    void readOut(LogicValue v) {
      self
        ..readTime = now
        ..readWord = word
        ..readBits = mask;
      final hit =
          other.writeTime == now &&
          other.writeWord == word &&
          other.writeBits & mask != 0;
      latch.put(hit ? LogicValue.filled(18, LogicValue.x) : v);
    }

    if (!sWe.value.toBool()) {
      readOut(read(word, slot));
      return;
    }
    final before = read(word, slot);
    final data = sDi.value;
    var next = storage[word];
    var nextUnknown = unknown[word];
    var written = 0;
    for (var i = 0; i < bits.length; i++) {
      // x18 writes a 9-bit half only when its byte enable is high.
      if (width == 18 && (adv >> (i ~/ 9)) & 1 == 0) continue;
      written |= 1 << bits[i];
    }
    for (var i = 0; i < bits.length; i++) {
      final bit = 1 << bits[i];
      if (written & bit == 0) continue;
      if (data[i].isValid) {
        next = (next & ~bit) | (data[i].toBool() ? bit : 0);
        nextUnknown &= ~bit;
      } else {
        nextUnknown |= bit;
      }
    }
    if (other.writeTime == now && other.writeWord == word) {
      nextUnknown |= other.writeBits & written;
    }
    storage[word] = next;
    unknown[word] = nextUnknown;
    self
      ..writeTime = now
      ..writeWord = word
      ..writeBits = written;
    if (other.readTime == now &&
        other.readWord == word &&
        other.readBits & written != 0) {
      other.latch.put(LogicValue.filled(18, LogicValue.x));
    }
    switch (writeMode) {
      case 'WRITETHROUGH':
        readOut(read(word, slot));
      case 'READBEFOREWRITE':
        readOut(before);
    }
  }

  // ROHD sends posedge at the end of the tick, after the Sequential above.
  clk.posedge.listen((_) => access());

  if (asyncReset) {
    rst.glitch.listen((_) {
      if (rst.value == LogicValue.one) {
        latch.put(0);
        outQ.put(0);
      }
    });
  }

  final q = outReg ? outQ : latch;
  for (var i = 0; i < 18; i++) {
    dout[i] <= q[i];
  }
}

/// ECP5 DP16KD: 16Kbit dual-port block RAM.
///
/// Ports use per-bit naming to match Yosys's cells_sim.v definition. The sim
/// body follows the ECP5 memory usage guide (FPGA-TN-02204). Both ports share
/// one array of 1024 x18 words. A port takes AD, DI, CE, WE and CS at the
/// rising edge of its clock. With REGMODE NOREG the read shows on DO after
/// that edge. OUTREG adds one more register, which loads when OCE is high.
/// In x18 mode AD[1:0] are the byte enables of the write, so a write with
/// them low changes nothing.
class Ecp5Dp16kd extends BridgeModule {
  Ecp5Dp16kd({
    required Logic clkA,
    required Logic ceA,
    required Logic weA,
    required Logic oceA,
    required Logic rstA,
    required Logic adA,
    required Logic diA,
    required Logic clkB,
    required Logic ceB,
    required Logic weB,
    required Logic oceB,
    required Logic rstB,
    required Logic adB,
    required Logic diB,
    Logic? csA,
    Logic? csB,
    // Port data width (18, 9, 4, 2, or 1). x9 yields one byte lane per BRAM,
    // which is how byte-granular write enables are built (x18 has no byte
    // masks). In sub-18 widths the word address occupies the UPPER AD bits
    // (x9: AD[13:3], low bits zero).
    int dataWidthA = 18,
    int dataWidthB = 18,
    // Optional ROM/RAM initial contents: exactly 64 INITVAL_xx values (each a
    // 320-bit big-endian integer) in the yosys DP16KD x18 packing convention
    // (init_slice: INITVAL_idx[i*20 +: 18] = word at addr idx*16+i). Use
    // [Ecp5Dp16kd.initVals] to compute these from a flat contents list. nextpnr
    // bakes these into the bitstream so the block powers up pre-loaded.
    List<BigInt>? initVals,
    // Cell options. A value equal to the yosys default is not emitted.
    String regModeA = 'NOREG',
    String regModeB = 'NOREG',
    String writeModeA = 'NORMAL',
    String writeModeB = 'NORMAL',
    String csDecodeA = '0b000',
    String csDecodeB = '0b000',
    String resetMode = 'SYNC',
    super.name = 'bram',
  }) : super('DP16KD', isSystemVerilogLeaf: true) {
    for (final w in [dataWidthA, dataWidthB]) {
      if (!const [1, 2, 4, 9, 18].contains(w)) {
        throw ArgumentError('DP16KD port width must be 1, 2, 4, 9 or 18: $w');
      }
    }
    for (final m in [regModeA, regModeB]) {
      if (m != 'NOREG' && m != 'OUTREG') {
        throw ArgumentError('DP16KD REGMODE must be NOREG or OUTREG: $m');
      }
    }
    for (final m in [writeModeA, writeModeB]) {
      if (!const ['NORMAL', 'WRITETHROUGH', 'READBEFOREWRITE'].contains(m)) {
        throw ArgumentError(
          'DP16KD WRITEMODE must be NORMAL, WRITETHROUGH or '
          'READBEFOREWRITE: $m',
        );
      }
    }
    if (resetMode != 'SYNC' && resetMode != 'ASYNC') {
      throw ArgumentError('DP16KD RESETMODE must be SYNC or ASYNC: $resetMode');
    }
    final csValueA = _parseCsDecode(csDecodeA);
    final csValueB = _parseCsDecode(csDecodeB);

    createParameter('DATA_WIDTH_A', '$dataWidthA');
    createParameter('DATA_WIDTH_B', '$dataWidthB');
    void option(String key, String value, String byDefault) {
      if (value != byDefault) createParameter(key, '"$value"');
    }

    option('REGMODE_A', regModeA, 'NOREG');
    option('REGMODE_B', regModeB, 'NOREG');
    option('WRITEMODE_A', writeModeA, 'NORMAL');
    option('WRITEMODE_B', writeModeB, 'NORMAL');
    option('CSDECODE_A', csDecodeA, '0b000');
    option('CSDECODE_B', csDecodeB, '0b000');
    option('RESETMODE', resetMode, 'SYNC');
    if (initVals != null) {
      assert(initVals.length == 64, 'DP16KD needs exactly 64 INITVAL words');
      for (var i = 0; i < 64; i++) {
        final hex = initVals[i].toRadixString(16).padLeft(80, '0');
        final suffix = i.toRadixString(16).padLeft(2, '0').toUpperCase();
        createParameter('INITVAL_$suffix', "320'h$hex");
      }
    }
    // Port A inputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addInput('DIA$i', diA.width > i ? diA[i] : Const(0));
    }
    for (var i = 0; i < 14; i++) {
      addInput('ADA$i', adA.width > i ? adA[i] : Const(0));
    }
    addInput('CLKA', clkA);
    addInput('CEA', ceA);
    addInput('OCEA', oceA);
    addInput('WEA', weA);
    addInput('RSTA', rstA);
    for (var i = 0; i < 3; i++) {
      addInput('CSA$i', csA != null && csA.width > i ? csA[i] : Const(0));
    }

    // Port A outputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addOutput('DOA$i');
    }

    // Port B inputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addInput('DIB$i', diB.width > i ? diB[i] : Const(0));
    }
    for (var i = 0; i < 14; i++) {
      addInput('ADB$i', adB.width > i ? adB[i] : Const(0));
    }
    addInput('CLKB', clkB);
    addInput('CEB', ceB);
    addInput('OCEB', oceB);
    addInput('WEB', weB);
    addInput('RSTB', rstB);
    for (var i = 0; i < 3; i++) {
      addInput('CSB$i', csB != null && csB.width > i ? csB[i] : Const(0));
    }

    // Port B outputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addOutput('DOB$i');
    }

    // sim-only: the emitted SV has only the ports.
    final mask18 = (BigInt.one << 18) - BigInt.one;
    final storage = List<int>.filled(1024, 0);
    final unknown = List<int>.filled(1024, 0);
    if (initVals != null) {
      for (var idx = 0; idx < 64; idx++) {
        for (var i = 0; i < 16; i++) {
          storage[idx * 16 + i] = ((initVals[idx] >> (i * 20)) & mask18)
              .toInt();
        }
      }
    }
    final access = [_Dp16kdAccess(), _Dp16kdAccess()];
    for (final p in ['A', 'B']) {
      final isA = p == 'A';
      _dp16kdPortSim(
        storage: storage,
        unknown: unknown,
        self: access[isA ? 0 : 1],
        other: access[isA ? 1 : 0],
        clk: input('CLK$p'),
        ce: input('CE$p'),
        oce: input('OCE$p'),
        we: input('WE$p'),
        rst: input('RST$p'),
        cs: [for (var i = 2; i >= 0; i--) input('CS$p$i')].swizzle(),
        ad: [for (var i = 13; i >= 0; i--) input('AD$p$i')].swizzle(),
        di: [for (var i = 17; i >= 0; i--) input('DI$p$i')].swizzle(),
        dout: [for (var i = 0; i < 18; i++) output('DO$p$i')],
        width: isA ? dataWidthA : dataWidthB,
        outReg: (isA ? regModeA : regModeB) == 'OUTREG',
        writeMode: isA ? writeModeA : writeModeB,
        csValue: isA ? csValueA : csValueB,
        asyncReset: resetMode == 'ASYNC',
        name: '${name}_sim_$p',
      );
    }
  }

  static int _parseCsDecode(String s) {
    final m = RegExp(r'^0b([01]{3})$').firstMatch(s);
    if (m == null) {
      throw ArgumentError('DP16KD CSDECODE must look like 0b000: $s');
    }
    return int.parse(m.group(1)!, radix: 2);
  }

  /// Port A read data as a bus.
  Logic get doA => [for (var i = 17; i >= 0; i--) output('DOA$i')].swizzle();

  /// Port B read data as a bus.
  Logic get doB => [for (var i = 17; i >= 0; i--) output('DOB$i')].swizzle();

  /// Packs one DP16KD block's contents into the 64 INITVAL_xx words expected by
  /// [Ecp5Dp16kd]'s `initVals`. [words] is the per-block 18-bit value at each
  /// word address (low addresses first, length <= 1024, missing/extra = 0).
  /// Mirrors yosys brams_map_16kd.v `init_slice`: each INITVAL_idx holds 16
  /// words, word i at bits [i*20 +: 18] (18 data in a 20-bit slot).
  static List<BigInt> initVals(List<BigInt> words) {
    final mask18 = (BigInt.one << 18) - BigInt.one;
    return [
      for (var idx = 0; idx < 64; idx++)
        () {
          var v = BigInt.zero;
          for (var i = 0; i < 16; i++) {
            final addr = idx * 16 + i;
            final w = addr < words.length
                ? (words[addr] & mask18)
                : BigInt.zero;
            v |= w << (i * 20);
          }
          return v;
        }(),
    ];
  }
}

/// ECP5 EBR-backed ROM/patchable-ROM, pre-loaded from [contents] via DP16KD
/// INITVAL (baked into the bitstream). `ceil(width/18)` DP16KD blocks in x18
/// mode hold an 18-bit slice of each word. Port B is the registered read
/// ([rdData] is one cycle behind [rdAddr], readLatency == 1) and port A is an
/// optional single write port (for runtime patching). It simulates through
/// the [Ecp5Dp16kd] sim body. A read of the word that is written on the same
/// edge gives X in [rdData] for that cycle, as on silicon.
class Ecp5InitRom extends Module {
  /// Registered read data, one cycle behind [rdAddr].
  Logic get rdData => output('rd_data');

  Ecp5InitRom(
    Logic clk, {
    required List<BigInt> contents,
    required int width,
    required Logic rdAddr,
    Logic? wrEn,
    Logic? wrAddr,
    Logic? wrData,
    super.name = 'ecp5_init_rom',
    // Distinct stable module name per ROM (two instances with different
    // contents/width are different modules. Without this ROHD uniquifies them
    // and the per-module SV file emission collides).
    super.definitionName,
    super.reserveDefinitionName = true,
  }) {
    clk = addInput('clk', clk);
    rdAddr = addInput('rd_addr', rdAddr, width: rdAddr.width);
    final hasWrite = wrEn != null;
    if (hasWrite) {
      wrEn = addInput('wr_en', wrEn);
      wrAddr = addInput('wr_addr', wrAddr!, width: wrAddr.width);
      wrData = addInput('wr_data', wrData!, width: width);
    }
    final rd = addOutput('rd_data', width: width);

    const ebrWidth = 18;
    const ebrAddrBits = 14;
    final blocks = (width + ebrWidth - 1) ~/ ebrWidth;
    // x18 addressing: the word index sits in AD[13:4]. AD[1:0] are the byte
    // enables of a write, so the write port drives them high.
    Logic toAd(Logic a, int byteEnables) =>
        [a.zeroExtend(ebrAddrBits - 4), Const(byteEnables, width: 4)].swizzle();
    final rdAd = toAd(rdAddr, 0);
    final wrAd = hasWrite ? toAd(wrAddr!, 3) : Const(0, width: ebrAddrBits);

    final slices = <Logic>[];
    for (var b = 0; b < blocks; b++) {
      final lo = b * ebrWidth;
      final hi = (lo + ebrWidth) > width ? width : lo + ebrWidth;
      final sliceWidth = hi - lo;
      final sliceMask = (BigInt.one << sliceWidth) - BigInt.one;
      final words = [for (final w in contents) (w >> lo) & sliceMask];

      final bram = Ecp5Dp16kd(
        name: 'rom_w$b',
        dataWidthA: ebrWidth,
        dataWidthB: ebrWidth,
        initVals: Ecp5Dp16kd.initVals(words),
        // Port A: optional single write port (posedge).
        clkA: clk,
        ceA: Const(1),
        weA: hasWrite ? wrEn! : Const(0),
        oceA: Const(0),
        rstA: Const(0),
        adA: wrAd,
        diA: hasWrite
            ? wrData!.getRange(lo, hi).zeroExtend(ebrWidth)
            : Const(0, width: ebrWidth),
        // Port B: registered read (posedge -> readLatency == 1).
        clkB: clk,
        ceB: Const(1),
        weB: Const(0),
        oceB: Const(0),
        rstB: Const(0),
        adB: rdAd,
        diB: Const(0, width: ebrWidth),
      );
      slices.add(bram.doB.getRange(0, sliceWidth));
    }

    rd <=
        (slices.length == 1
            ? slices.first.zeroExtend(width)
            : slices.rswizzle().getRange(0, width));
  }
}

/// ECP5 DTR: Die temperature readout.
class Ecp5Dtr extends BridgeModule {
  Ecp5Dtr({super.name = 'dtr'}) : super('DTR', isSystemVerilogLeaf: true) {
    createPort('STARTPULSE', PortDirection.input);
    addOutput('DTROUT8', width: 8);
  }
}

/// ECP5 ODDRX1F: 1:2 gearing DDR output register. Both [d0] and [d1] are
/// captured on the rising edge of [sclk]. [q] then shows [d0] while [sclk]
/// is high and [d1] while it is low. Capturing [d1] on the falling edge
/// instead would send the wrong bit, because by then a source register
/// driving [d1] from the same rising edge has already moved on to the next
/// value ([HarborDdrOutput] documents the same fault for its own, vendor-
/// neutral copy of this gearing).
class Ecp5Oddrx1f extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Oddrx1f({
    required Logic sclk,
    required Logic rst,
    required Logic d0,
    required Logic d1,
    super.name = 'oddr',
  }) : super('ODDRX1F', isSystemVerilogLeaf: true) {
    sclk = addInput('SCLK', sclk);
    addInput('RST', rst);
    d0 = addInput('D0', d0);
    d1 = addInput('D1', d1);
    final q = addOutput('Q');
    // sim-only: both halves latch together on the rise, then q just reads
    // off whichever half is live. RST is not modeled (every caller ties it
    // to a constant). No effect on synth: this leaf emits only the
    // declared ports.
    final qRise = Logic(name: '${name}_sim_rise');
    final qFall = Logic(name: '${name}_sim_fall');
    Sequential(sclk, [qRise < d0, qFall < d1]);
    q <= mux(sclk, qRise, qFall);
  }
}

/// ECP5 ODDRX2F: 4:1 DDR output register on the edge clock. [d0] to [d3] are
/// the four half-CK beats of one [sclk] cycle, [d0] first. Used for the CK and
/// command pads of an x2 DDR3 PHY.
class Ecp5Oddrx2f extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Oddrx2f({
    required Logic d0,
    required Logic d1,
    required Logic d2,
    required Logic d3,
    required Logic sclk,
    required Logic eclk,
    required Logic rst,
    super.name = 'oddrx2f',
  }) : super('ODDRX2F', isSystemVerilogLeaf: true) {
    d0 = addInput('D0', d0);
    d1 = addInput('D1', d1);
    d2 = addInput('D2', d2);
    d3 = addInput('D3', d3);
    sclk = addInput('SCLK', sclk);
    eclk = addInput('ECLK', eclk);
    rst = addInput('RST', rst);
    addOutput('Q');
    output('Q') <= _x2Out(eclk, sclk, [d0, d1, d2, d3], _oddrx2fLatency, name);
  }
}

/// ECP5 IDDRX1F: 1:2 gearing DDR input register. [q0] is the bit captured
/// on the rising edge of [sclk], [q1] the falling-edge bit, and both move
/// to the fabric together on the rise. No sim model ships for this cell in
/// yosys or prjtrellis: this is the ordinary 1:2 DDR input gearbox shape
/// FPGA-TN-02035 section 6.2 describes for the x2 family, applied to a
/// single edge pair. [q0]'s own timing (whether it is really available
/// with zero added latency past a plain rising-edge sample, the way this
/// model gives it) is not checked against any vendor model either: none
/// exists to check it against.
class Ecp5Iddrx1f extends BridgeModule {
  Logic get q0 => output('Q0');
  Logic get q1 => output('Q1');

  Ecp5Iddrx1f({
    required Logic sclk,
    required Logic rst,
    required Logic d,
    super.name = 'iddr',
  }) : super('IDDRX1F', isSystemVerilogLeaf: true) {
    sclk = addInput('SCLK', sclk);
    addInput('RST', rst);
    d = addInput('D', d);
    final q0 = addOutput('Q0');
    final q1 = addOutput('Q1');
    // sim-only: at a fall, d is latched into a holding bit (its own single-
    // edge trigger, since sampling sclk itself as data in a block it also
    // triggers reads back as x). At the next rise, q0 takes d right then and
    // q1 takes that held falling-edge bit, so both outputs move together on
    // the rise. RST is not modeled (every caller ties it to a constant). No
    // effect on synth.
    final fallHeld = Logic(name: '${name}_sim_fall');
    final q0r = Logic(name: '${name}_sim_q0');
    final q1r = Logic(name: '${name}_sim_q1');
    Sequential.multi([], [fallHeld < d], negedgeTriggers: [sclk]);
    Sequential(sclk, [q0r < d, q1r < fallHeld]);
    q0 <= q0r;
    q1 <= q1r;
  }
}

/// Sim body shared by [Ecp5Ofs1p3bx], [Ecp5Ifs1p3bx] and [Ecp5Ofs1p3dx]: a
/// flip-flop with an asynchronous set/clear. [sr] forces [q] to [srValue]
/// the instant it goes high, and holds it even if [sr] drops before the
/// next edge. [sp] gates capture (low holds the last value). [d] is
/// captured through a `Sequential`, not a raw edge listener, so it always
/// reads the pre-edge value no matter the build order.
void _srFlopSim(Logic d, Logic sclk, Logic sp, Logic sr, Logic q, int srValue) {
  final qr = Logic(name: 'sim_q');
  final srConst = Const(srValue, width: 1);
  Simulator.injectAction(() => qr.put(LogicValue.ofInt(srValue, 1)));
  Sequential(sclk, [qr < mux(sr, srConst, mux(sp, d, qr))]);
  sr.glitch.listen((_) {
    if (sr.value == LogicValue.one) qr.put(srConst.value);
  });
  q <= qr;
}

/// ECP5 OFS1P3BX: plain (non-DDR) output IO register with asynchronous
/// preset, from yosys `cells_ff.vh` (techmapped to a `TRELLIS_FF` with
/// `syn_useioff`) and litex `lattice_common.py`, which ties [sp] high and
/// [pd] low for a plain SDR output. [keep] adds a synthesis `(* keep *)`
/// attribute, for an output-enable flop whose [d] can equal a sibling
/// bit's and so risk being merged away.
class Ecp5Ofs1p3bx extends BridgeModule {
  Logic get q => output('Q');

  final bool keep;

  Ecp5Ofs1p3bx({
    required Logic d,
    required Logic sclk,
    Logic? sp,
    Logic? pd,
    this.keep = false,
    super.name = 'ofs1p3bx',
  }) : super('OFS1P3BX', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    sclk = addInput('SCLK', sclk);
    sp = addInput('SP', sp ?? Const(1));
    pd = addInput('PD', pd ?? Const(0));
    final q = addOutput('Q');
    _srFlopSim(d, sclk, sp, pd, q, 1);
  }

  @override
  String instantiationVerilog(
    String instanceType,
    String instanceName,
    Map<String, String> ports,
  ) {
    final inst = super.instantiationVerilog(instanceType, instanceName, ports);
    return keep ? '(* keep *)\n$inst' : inst;
  }
}

/// ECP5 IFS1P3BX: plain (non-DDR) input IO register with asynchronous
/// preset. Same ports and sim body as [Ecp5Ofs1p3bx].
class Ecp5Ifs1p3bx extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Ifs1p3bx({
    required Logic d,
    required Logic sclk,
    Logic? sp,
    Logic? pd,
    super.name = 'ifs1p3bx',
  }) : super('IFS1P3BX', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    sclk = addInput('SCLK', sclk);
    sp = addInput('SP', sp ?? Const(1));
    pd = addInput('PD', pd ?? Const(0));
    final q = addOutput('Q');
    _srFlopSim(d, sclk, sp, pd, q, 1);
  }
}

/// ECP5 OFS1P3DX: plain (non-DDR) output IO register with asynchronous
/// clear, so [q] powers up and resets to 0 instead of [Ecp5Ofs1p3bx]'s 1.
/// Used for a pin that must idle low across a power-up (cke, so the device
/// never samples a command before the init sequence raises it).
class Ecp5Ofs1p3dx extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Ofs1p3dx({
    required Logic d,
    required Logic sclk,
    Logic? sp,
    Logic? cd,
    super.name = 'ofs1p3dx',
  }) : super('OFS1P3DX', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    sclk = addInput('SCLK', sclk);
    sp = addInput('SP', sp ?? Const(1));
    cd = addInput('CD', cd ?? Const(0));
    final q = addOutput('Q');
    _srFlopSim(d, sclk, sp, cd, q, 0);
  }
}

/// ECP5 FD1S3BX: fabric flip-flop with asynchronous preset, so [q] powers
/// up and presets to 1. Yosys does not merge two of these with the same
/// inputs, so it can make a local copy of a reset for each block.
class Ecp5Fd1s3bx extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Fd1s3bx({
    required Logic d,
    required Logic ck,
    required Logic pd,
    super.name = 'fd1s3bx',
  }) : super('FD1S3BX', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    ck = addInput('CK', ck);
    pd = addInput('PD', pd);
    final q = addOutput('Q');
    _srFlopSim(d, ck, Const(1), pd, q, 1);
  }
}

/// ECP5 FD1S3DX: fabric flip-flop with asynchronous clear, so [q] powers
/// up and clears to 0. Like [Ecp5Fd1s3bx], yosys does not merge two of
/// these with the same inputs.
class Ecp5Fd1s3dx extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Fd1s3dx({
    required Logic d,
    required Logic ck,
    required Logic cd,
    super.name = 'fd1s3dx',
  }) : super('FD1S3DX', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    ck = addInput('CK', ck);
    cd = addInput('CD', cd);
    final q = addOutput('Q');
    _srFlopSim(d, ck, Const(1), cd, q, 0);
  }
}

/// ECP5 DELAYG: static input delay line (128 taps of ~25ps). Used to move
/// the read-data sampling point into the eye. The tap count is fixed at
/// synthesis ([delValue]), so read training picks a value per board/build.
class Ecp5Delayg extends BridgeModule {
  Logic get z => output('Z');

  Ecp5Delayg({
    required Logic a,
    int delValue = 0,
    // DEL_MODE selects the delay primitive's calibration mode. Default
    // "USER_DEFINED" (raw tap count) for static/non-DQS delays. The DQ READ
    // delays feeding an IDDRX2DQA DQS gearbox use "DQS_ALIGNED_X2" so the delay
    // tracks the DQS-aligned x2 read window (Lattice TN-02035 / litedram DQ
    // read DELAYF), which centers the captured beat in the DQS eye.
    String delMode = 'USER_DEFINED',
    super.name = 'delayg',
  }) : super('DELAYG', isSystemVerilogLeaf: true) {
    createParameter('DEL_MODE', '"$delMode"');
    createParameter('DEL_VALUE', '$delValue');
    a = addInput('A', a);
    addOutput('Z');
    // sim-only: the leveler sweeps READCLKSEL and bitslip, not this tap, so a
    // digital identity model is enough (no analog eye to miss in sim).
    output('Z') <= a;
  }
}

/// ECP5 DELAYF: DYNAMIC input delay line (128 taps of ~25ps), the runtime-
/// tunable counterpart of [Ecp5Delayg]. The tap is set at runtime instead of at
/// synthesis, so the CPU/FSBL can train the read-data sampling point per board
/// without a rebuild:
///   - [loadn] (active-low) loads the initial tap [delValue].
///   - each rising edge on [move] steps the tap by one, in [direction]
///     (0 = increment toward more delay, 1 = decrement).
///   - [cflag] pulses when a move would run off the end (tap at 0 or 127), so
///     the controller can detect the sweep limits.
class Ecp5Delayf extends BridgeModule {
  Logic get z => output('Z');
  Logic get cflag => output('CFLAG');

  Ecp5Delayf({
    required Logic a,
    required Logic loadn,
    required Logic move,
    required Logic direction,
    int delValue = 0,
    // See [Ecp5Delayg.delMode]. The DQ READ DELAYF feeding the IDDRX2DQA D input
    // uses "DQS_ALIGNED_X2" to track the DQS-aligned x2 read window.
    String delMode = 'USER_DEFINED',
    super.name = 'delayf',
  }) : super('DELAYF', isSystemVerilogLeaf: true) {
    createParameter('DEL_MODE', '"$delMode"');
    createParameter('DEL_VALUE', '$delValue');
    a = addInput('A', a);
    addInput('LOADN', loadn);
    addInput('MOVE', move);
    addInput('DIRECTION', direction);
    addOutput('Z');
    addOutput('CFLAG');
    // sim-only: see Ecp5Delayg. CFLAG (sweep-limit flag) is not consumed by
    // the leveler, so it ties to a defined 0 rather than floating.
    output('Z') <= a;
    output('CFLAG') <= Const(0);
  }
}

/// ECP5 USRMCLK: user access to the dedicated configuration SPI clock (MCLK).
///
/// On the ECP5 the master-SPI configuration clock has NO general-purpose I/O
/// pad: after configuration, a design that wants to drive the on-board config
/// flash (e.g. for XIP firmware) must route its flash clock through this
/// primitive, which drives the dedicated MCLK ball internally. [usrmclki] is the
/// clock to emit. [usrmclkts] is the (active-high) tristate: hold it low to
/// drive. There is no output port (the pad is internal to the macro).
class Ecp5Usrmclk extends BridgeModule {
  Ecp5Usrmclk({
    required Logic usrmclki,
    required Logic usrmclkts,
    super.name = 'usrmclk',
  }) : super('USRMCLK', isSystemVerilogLeaf: true) {
    addInput('USRMCLKI', usrmclki);
    addInput('USRMCLKTS', usrmclkts);
  }
}

/// ECP5 JTAGG: JTAG interface access.
class Ecp5Jtagg extends BridgeModule {
  Ecp5Jtagg({super.name = 'jtag'}) : super('JTAGG', isSystemVerilogLeaf: true) {
    addOutput('JTCK');
    addOutput('JTDI');
    addOutput('JSHIFT');
    addOutput('JUPDATE');
    addOutput('JRSTN');
    addOutput('JCE1');
    addOutput('JCE2');
    addOutput('JRTI1');
    addOutput('JRTI2');
    createPort('JTDO1', PortDirection.input);
    createPort('JTDO2', PortDirection.input);
  }
}

// DDR-memory I/O primitives (TN1265). These implement the DQS-strobe-based
// read/write path Lattice's own ECP5 DDR3 PHY uses, replacing creek's static-
// DELAYG + clk90 read capture, which is marginal under continuous reads. The
// read side runs in an edge-clock (ECLK = 2x sysclk) domain: DDRDLLA produces
// a calibrated delay code, DQSBUFM gates the incoming DQS and produces the
// DQS-derived read clock (DQSR90) + read pointer, and IDDRX2DQA captures DQ in
// that domain. Port names are the Lattice primitive names (verified by nextpnr
// + on silicon, since these are placement leaves).

/// ECP5 DDRDLLA: DDR delay-locked loop. Generates the 8-bit delay code
/// [ddrdel] (a 90-degree reference for DQSBUFM) from the edge clock [clk].
/// [uddcntln] (active-low) freezes/updates the code. [freeze] holds it.
class Ecp5Ddrdlla extends BridgeModule {
  Logic get ddrdel => output('DDRDEL');
  Logic get lock => output('LOCK');

  Ecp5Ddrdlla({
    required Logic clk,
    required Logic rst,
    required Logic uddcntln,
    required Logic freeze,
    super.name = 'ddrdlla',
  }) : super('DDRDLLA', isSystemVerilogLeaf: true) {
    addInput('CLK', clk);
    addInput('RST', rst);
    addInput('UDDCNTLN', uddcntln);
    addInput('FREEZE', freeze);
    addOutput('DDRDEL');
    addOutput('LOCK');
  }
}

/// ECP5 ECLKSYNCB: edge-clock sync/gate. Passes [eclki] to ECLKO unless
/// [stop] is asserted (used to stop the edge clock during DLL update).
class Ecp5Eclksyncb extends BridgeModule {
  Logic get eclko => output('ECLKO');

  Ecp5Eclksyncb({
    required Logic eclki,
    required Logic stop,
    super.name = 'eclksyncb',
  }) : super('ECLKSYNCB', isSystemVerilogLeaf: true) {
    addInput('ECLKI', eclki);
    addInput('STOP', stop);
    addOutput('ECLKO');
  }
}

/// ECP5 CLKDIVF: divides the edge clock [clki] by [div] to make the slow
/// (fabric) clock. For the 2:1 DDR read path div = "2.0". [alignwd] aligns the
/// divider word boundary. [rst] resets it.
class Ecp5Clkdivf extends BridgeModule {
  Logic get cdivx => output('CDIVX');

  Ecp5Clkdivf({
    required Logic clki,
    required Logic rst,
    required Logic alignwd,
    String div = '2.0',
    super.name = 'clkdivf',
  }) : super('CLKDIVF', isSystemVerilogLeaf: true) {
    createParameter('DIV', '"$div"');
    addInput('CLKI', clki);
    addInput('RST', rst);
    addInput('ALIGNWD', alignwd);
    addOutput('CDIVX');
  }
}

/// ECP5 DQSBUFM: the DQS strobe buffer + read/write delay + read pointer for
/// one byte lane. The heart of the DDR read path: it delays the incoming DQS
/// ([dqsi]) by the DDRDLLA-calibrated 90 degrees to make [dqsr90] (the read
/// capture clock for IDDRX2DQA), tracks the DQS read-gate window via the read
/// pointer ([rdpntr]), and produces the write strobes ([dqsw]/[dqsw270]). The
/// READCLKSEL bus selects the read-gate clock cycle (DQS gate training).
/// RDLOADN/RDMOVE/RDDIRECTION step the read delay (read training). [datavalid]
/// and [burstdet] report a captured burst.
class Ecp5Dqsbufm extends BridgeModule {
  Logic get dqsr90 => output('DQSR90');
  Logic get dqsw => output('DQSW');
  Logic get dqsw270 => output('DQSW270');
  // Per-bit pointers swizzled LSB-first into a 3-bit bus ({RDPNTR2..0}).
  Logic get rdpntr =>
      [output('RDPNTR2'), output('RDPNTR1'), output('RDPNTR0')].swizzle();
  Logic get wrpntr =>
      [output('WRPNTR2'), output('WRPNTR1'), output('WRPNTR0')].swizzle();
  Logic get datavalid => output('DATAVALID');
  Logic get burstdet => output('BURSTDET');

  Ecp5Dqsbufm({
    required Logic dqsi,
    required Logic read0,
    required Logic read1,
    required Logic readclksel, // 3-bit DQS-gate cycle select
    required Logic ddrdel,
    required Logic eclk,
    required Logic sclk,
    required Logic rst,
    required Logic rdloadn,
    required Logic rdmove,
    required Logic rddirection,
    required Logic wrloadn,
    required Logic wrmove,
    required Logic wrdirection,
    required Logic pause,
    // Optional 8-bit dynamic DQS delay (DYNDELAY[7:0]). PORT STRUCTURE (verified
    // against the ECP5 primitive / Lattice TN1265 / blackboxes.v): DYNDELAY0..7
    // are EIGHT SINGLE-BIT input ports that together form ONE 8-bit dynamic delay
    // VALUE. It is a PER-DQSBUFM (per-byte-lane) trim of the read/write DQS delay
    // generated in the DDRDLL: NOT a per-DQ-bit delay (there is no per-DQ
    // DYNDELAY in this primitive). So this shifts the WHOLE lane's DQS strobe.
    // JEDEC/Lattice PAUSE caveat: a DYNDELAY change must have PAUSE asserted 4T
    // before and 4T after. For a quasi-static firmware-swept value (settled long
    // before any strobe) that timing margin is comfortably met.
    // Default null -> the prior per-bit Const(0) tie-off, so every other
    // instantiation stays byte-identical (back-compat).
    Logic? dyndelay,
    super.name = 'dqsbufm',
  }) : super('DQSBUFM', isSystemVerilogLeaf: true) {
    // DQS read/write delay calibration. These center DQSR90 in the read eye and
    // are REQUIRED for the read-delay DLL to consume the DDRDEL 90-degree code.
    // Without them the tool default leaves DQSR90 uncalibrated and BURSTDET
    // never fires (DLL locks but no burst is detected). Values are litedram's
    // ECP5DDRPHY DDR3 settings (DQS_LI_DEL_VAL=1, DQS_LO_DEL_VAL=4, both MINUS).
    createParameter('DQS_LI_DEL_ADJ', '"MINUS"');
    createParameter('DQS_LI_DEL_VAL', '1');
    createParameter('DQS_LO_DEL_ADJ', '"MINUS"');
    createParameter('DQS_LO_DEL_VAL', '4');
    dqsi = addInput('DQSI', dqsi);
    read0 = addInput('READ0', read0);
    read1 = addInput('READ1', read1);
    final rcs0 = addInput('READCLKSEL0', readclksel.getRange(0, 1));
    final rcs1 = addInput('READCLKSEL1', readclksel.getRange(1, 2));
    final rcs2 = addInput('READCLKSEL2', readclksel.getRange(2, 3));
    addInput('DDRDEL', ddrdel);
    eclk = addInput('ECLK', eclk);
    addInput('SCLK', sclk);
    rst = addInput('RST', rst);
    addInput('RDLOADN', rdloadn);
    addInput('RDMOVE', rdmove);
    addInput('RDDIRECTION', rddirection);
    addInput('WRLOADN', wrloadn);
    addInput('WRMOVE', wrmove);
    addInput('WRDIRECTION', wrdirection);
    pause = addInput('PAUSE', pause);
    // The 8 single-bit DYNDELAY ports = bits [7:0] of the dynamic DQS-delay
    // value. Tied low per bit when [dyndelay] is null (the prior behavior), else
    // driven from the supplied 8-bit value bit-by-bit.
    for (var i = 0; i < 8; i++) {
      addInput(
        'DYNDELAY$i',
        dyndelay == null ? Const(0) : dyndelay.getRange(i, i + 1),
      );
    }
    addOutput('DQSR90');
    addOutput('DQSW');
    addOutput('DQSW270');
    addOutput('RDPNTR0');
    addOutput('RDPNTR1');
    addOutput('RDPNTR2');
    addOutput('WRPNTR0');
    addOutput('WRPNTR1');
    addOutput('WRPNTR2');
    addOutput('DATAVALID');
    addOutput('BURSTDET');
    addOutput('RDCFLAG');
    addOutput('WRCFLAG');

    // sim-only READ pulse model, from FPGA-TN-02035 6.2.4 and Table 6.3:
    //  - The internal READ pulse opens 5.5T after READ0/READ1 rise, plus
    //    READCLKSEL x T/4 (8 steps over 2T).
    //  - It is placed right when it opens inside the 1T DQS preamble. The
    //    model takes only the middle of the preamble: 1 to 3 quarter-T steps
    //    before the first DQS rising edge (narrower than silicon, so a
    //    marginal setting fails here rather than passing).
    //  - Then RDPNTR reads 0 for the 8 beats of that burst (the IDDRX2DQA
    //    model passes data only then) and BURSTDET rises after the last DQS
    //    edge, until the next READ. Otherwise RDPNTR reads 7 and BURSTDET
    //    stays low. PAUSE at the opening fails the burst.
    // Behavioral (event-driven) because it needs quarter-T timing. One burst
    // per READ rise. The write strobes have no role in the write models.
    final valid = Logic(name: '${name}_sim_window');
    final burst = Logic(name: '${name}_sim_burstdet');
    Simulator.injectAction(() {
      valid.put(0);
      burst.put(0);
    });
    final readIn = read0 | read1;
    final selIn = [rcs2, rcs1, rcs0].swizzle();
    int? lastEclkRise;
    int? tck;
    eclk.posedge.listen((_) {
      final t = Simulator.time;
      if (lastEclkRise != null) tck = t - lastEclkRise!;
      lastEclkRise = t;
    });
    int? gateAt;
    readIn.posedge.listen((_) {
      final period = tck;
      final sel = selIn.value;
      if (period == null || !sel.isValid) return;
      final quarter = period ~/ 4;
      final g = Simulator.time + (period * 11) ~/ 2 + sel.toInt() * quarter;
      Simulator.registerAction(g, () {
        gateAt = pause.value == LogicValue.one ? null : g;
        burst.put(0);
        Simulator.registerAction(g + 4 * period, () {
          if (gateAt == g) gateAt = null;
        });
      });
    });
    dqsi.posedge.listen((_) {
      final g = gateAt;
      final period = tck;
      if (g == null || period == null) return;
      gateAt = null;
      final t = Simulator.time;
      final quarter = period ~/ 4;
      final early = t - g;
      if (early < quarter || early > 3 * quarter) return;
      valid.put(1);
      Simulator.registerAction(t + 4 * period, () {
        valid.put(0);
        burst.put(1);
      });
    });
    output('RDPNTR0') <= ~valid;
    output('RDPNTR1') <= ~valid;
    output('RDPNTR2') <= ~valid;
    output('WRPNTR0') <= Const(0);
    output('WRPNTR1') <= Const(0);
    output('WRPNTR2') <= Const(0);
    output('DQSR90') <= eclk;
    output('DQSW') <= eclk;
    output('DQSW270') <= eclk;
    output('RDCFLAG') <= Const(0);
    output('WRCFLAG') <= Const(0);
    output('DATAVALID') <= valid;
    output('BURSTDET') <= burst;
  }
}

/// ECP5 ODDRX2DQA: 1:4 gearing DDR output register for DQ/DM. The four
/// sub-beats [d0]..[d3] are launched on the DQS-derived write clock: the
/// primitive runs in the [eclk] edge-clock domain (clocked-out at 2x), word-
/// loaded from the [sclk] fabric, and phase-aligned to the write strobe via
/// [dqsw270] (DQSBUFM's DQSW270, the 270-degree write clock that centers DQ in
/// the DQS eye). This is the x2 write counterpart of [Ecp5Iddrx2dqa] and the
/// replacement for the x1 [Ecp5Oddrx1f] on DQ/DM pads (an ECP5 DQ pad's input
/// and output IOLOGIC must share gearing, so a MIDDRX read forces a MODDRX
/// write). Port names + order match yosys cells_bb.v / litex ECP5DDRPHY.
class Ecp5Oddrx2dqa extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Oddrx2dqa({
    required Logic d0,
    required Logic d1,
    required Logic d2,
    required Logic d3,
    required Logic dqsw270,
    required Logic sclk,
    required Logic eclk,
    required Logic rst,
    super.name = 'oddrx2dqa',
  }) : super('ODDRX2DQA', isSystemVerilogLeaf: true) {
    d0 = addInput('D0', d0);
    d1 = addInput('D1', d1);
    d2 = addInput('D2', d2);
    d3 = addInput('D3', d3);
    addInput('DQSW270', dqsw270);
    sclk = addInput('SCLK', sclk);
    eclk = addInput('ECLK', eclk);
    rst = addInput('RST', rst);
    addOutput('Q');
    output('Q') <=
        _x2Out(eclk, sclk, [d0, d1, d2, d3], _oddrx2dqaLatency, name);
  }
}

/// ECP5 ODDRX2DQSB: 1:4 gearing DDR output register for the DQS strobe. Same
/// gearing as [Ecp5Oddrx2dqa] but aligned to [dqsw] (DQSBUFM's DQSW, the
/// 0/90-degree write strobe clock) so the launched DQS is edge-aligned to the
/// write data window. Driven with the toggling pattern D = 0b1010 (D0=0, D1=1,
/// D2=0, D3=1) per litex to emit the strobe. Replaces the x1 DQS ODDRX1F.
class Ecp5Oddrx2dqsb extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Oddrx2dqsb({
    required Logic d0,
    required Logic d1,
    required Logic d2,
    required Logic d3,
    required Logic dqsw,
    required Logic sclk,
    required Logic eclk,
    required Logic rst,
    super.name = 'oddrx2dqsb',
  }) : super('ODDRX2DQSB', isSystemVerilogLeaf: true) {
    d0 = addInput('D0', d0);
    d1 = addInput('D1', d1);
    d2 = addInput('D2', d2);
    d3 = addInput('D3', d3);
    addInput('DQSW', dqsw);
    sclk = addInput('SCLK', sclk);
    eclk = addInput('ECLK', eclk);
    rst = addInput('RST', rst);
    addOutput('Q');
    output('Q') <=
        _x2Out(eclk, sclk, [d0, d1, d2, d3], _oddrx2dqaLatency, name);
  }
}

/// ECP5 TSHX2DQA: 1:4 gearing tristate (output enable) shift for DQ/DM pads.
/// [t0]/[t1] are the two active-LOW tristate phases (T=0 drives, T=1 = HiZ).
/// [q] is the geared pad tristate control. Phase-aligned to [dqsw270] (matches
/// the DQ ODDRX2DQA). The output [q] is the active-low OE the pad's tristate
/// buffer inverts (pad drives when ~Q).
class Ecp5Tshx2dqa extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Tshx2dqa({
    required Logic t0,
    required Logic t1,
    required Logic dqsw270,
    required Logic sclk,
    required Logic eclk,
    required Logic rst,
    super.name = 'tshx2dqa',
  }) : super('TSHX2DQA', isSystemVerilogLeaf: true) {
    t0 = addInput('T0', t0);
    t1 = addInput('T1', t1);
    addInput('DQSW270', dqsw270);
    sclk = addInput('SCLK', sclk);
    eclk = addInput('ECLK', eclk);
    rst = addInput('RST', rst);
    addOutput('Q');
    output('Q') <=
        _x2Out(eclk, sclk, [t0, t0, t1, t1], _oddrx2dqaLatency, name);
  }
}

/// ECP5 TSHX2DQSA: 1:4 gearing tristate (output enable) shift for the DQS
/// strobe pad. Like [Ecp5Tshx2dqa] but aligned to [dqsw] (matches the DQS
/// ODDRX2DQSB). [t0]/[t1] are active-low. litex drives them with the
/// preamble/postamble-extended write-enable window.
class Ecp5Tshx2dqsa extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Tshx2dqsa({
    required Logic t0,
    required Logic t1,
    required Logic dqsw,
    required Logic sclk,
    required Logic eclk,
    required Logic rst,
    super.name = 'tshx2dqsa',
  }) : super('TSHX2DQSA', isSystemVerilogLeaf: true) {
    t0 = addInput('T0', t0);
    t1 = addInput('T1', t1);
    addInput('DQSW', dqsw);
    sclk = addInput('SCLK', sclk);
    eclk = addInput('ECLK', eclk);
    rst = addInput('RST', rst);
    addOutput('Q');
    output('Q') <=
        _x2Out(eclk, sclk, [t0, t0, t1, t1], _oddrx2dqaLatency, name);
  }
}

/// ECP5 IDDRX2DQA: DQS-domain DDR input register, 1:4 gearing. Captures the
/// delayed DQ [d] using the DQS-derived read clock [dqsr90] and the DQSBUFM
/// read pointer [rdpntr], presenting the four sub-beats [q0..q3] in the slow
/// ([sclk]) domain. This is the DQS-strobed replacement for the IDDRX1F-on-
/// clk90 capture.
class Ecp5Iddrx2dqa extends BridgeModule {
  Logic get q0 => output('Q0');
  Logic get q1 => output('Q1');
  Logic get q2 => output('Q2');
  Logic get q3 => output('Q3');

  Ecp5Iddrx2dqa({
    required Logic d,
    required Logic dqsr90,
    required Logic rdpntr, // 3-bit
    required Logic wrpntr, // 3-bit
    required Logic eclk,
    required Logic sclk,
    required Logic rst,
    super.name = 'iddrx2dqa',
  }) : super('IDDRX2DQA', isSystemVerilogLeaf: true) {
    d = addInput('D', d);
    addInput('DQSR90', dqsr90);
    final rdpntr0 = addInput('RDPNTR0', rdpntr.getRange(0, 1));
    final rdpntr1 = addInput('RDPNTR1', rdpntr.getRange(1, 2));
    final rdpntr2 = addInput('RDPNTR2', rdpntr.getRange(2, 3));
    // When the IDDRX2DQA packs with the DQ pad's ODDRX2DQA/TSHX2DQA into a single
    // merged MIDDRX_MODDRX DQ-IOLOGIC bel, nextpnr requires the bel's write
    // pointer (WRPNTR0..2) to be driven from the byte lane's DQSBUFM, exactly as
    // RDPNTR is. litex ECP5DDRPHY wires both pointers onto this read cell.
    addInput('WRPNTR0', wrpntr.getRange(0, 1));
    addInput('WRPNTR1', wrpntr.getRange(1, 2));
    addInput('WRPNTR2', wrpntr.getRange(2, 3));
    eclk = addInput('ECLK', eclk);
    sclk = addInput('SCLK', sclk);
    rst = addInput('RST', rst);
    addOutput('Q0');
    addOutput('Q1');
    addOutput('Q2');
    addOutput('Q3');

    // sim-only. D is sampled on both ECLK edges: the DRAM model trails CK by
    // T/4, so an ECLK edge is the middle of a beat, which stands in for the
    // 90 degree DQSR90 shift. RDPNTR carries the DQSBUFM read-window flag
    // (0 = inside a properly gated burst, see Ecp5Dqsbufm). A sample taken
    // outside it is inverted, so a misplaced READ pulse returns wrong data.
    // Each 4-beat group is handed to SCLK on the SCLK edge, oldest in Q0,
    // then delayed to _iddrx2dqaLatency groups.
    final valid = [rdpntr2, rdpntr1, rdpntr0].swizzle().eq(0);
    final sample = mux(valid, d, ~d);
    final sr = [for (var k = 0; k < 4; k++) Logic(name: '${name}_sim_sr$k')];
    Sequential.multi(
      [eclk],
      [sr[0] < sample, for (var k = 1; k < 4; k++) sr[k] < sr[k - 1]],
      negedgeTriggers: [eclk],
    );
    Logic group = [sr[0], sr[1], sr[2], sr[3]].swizzle();
    for (var i = 0; i < _iddrx2dqaLatency; i++) {
      final r = Logic(name: '${name}_sim_grp$i', width: 4);
      Sequential(sclk, [r < group]);
      group = r;
    }
    final q0r = group[0];
    final q1r = group[1];
    final q2r = group[2];
    final q3r = group[3];
    output('Q0') <= q0r;
    output('Q1') <= q1r;
    output('Q2') <= q2r;
    output('Q3') <= q3r;
  }
}

/// ECP5 DDR edge-clock tree (Milestone 1 of the proper DDR3 PHY clocking).
///
/// Builds Lattice's 2-phase edge-clock scheme that DQSBUFM/IDDRX2DQA reads
/// (Milestone 2) require, replacing the old single-clock (CK == sysclk) PHY
/// datapath:
///   - [eclk] (edge clock, CK rate): the [clkSource] (a PLL output at the CK
///     rate) passed through an ECLKSYNCB. STOP is tied low here. Milestone 2
///     gates it during a DDRDLLA update.
///   - [sclk] (fabric clock, CK/2): eclk divided by CLKDIVF DIV "2.0". This is
///     the PHY-fabric + sequencer clock: half the CK rate, as the DDR gearing
///     wants. ALIGNWD is driven by [alignwd]: the init FSM pulses it to align the
///     divide-by-2 word boundary deterministically instead of a random power-up
///     CK phase.
///   - [ddrdel]/[lock] from a DDRDLLA on eclk: the 90-degree delay code the
///     DQSBUFM read path consumes. UDDCNTLN (active-low), FREEZE, the ECLKSYNCB
///     STOP and an ECLK-domain reset are now DRIVEN INPUTS so the DDR PHY's init
///     FSM (litedram ECP5DDRPHYInit) can run the DDRDEL-load handshake: it
///     freezes the DLL, stops + resets the ECLK domain, then pulses UDDCNTLN low
///     once (inside a DQSBUFM PAUSE window) to latch the calibrated DDRDEL code
///     into the DQSBUFMs. The DLL never detected a read burst without this load
///     even though it locked (the on-silicon DLL=1/BURSTDET=0 signature). All
///     four inputs default to the previous hard-tied constants when unconnected,
///     so non-DDR clock-tree users are unaffected.
///
/// [ddrdel]/[lock] are exposed so a later milestone can route them and so the
/// elaborator does not prune the DDRDLLA.
///
/// The ECLKSYNCB/CLKDIVF/DDRDLLA primitives are SystemVerilog leaves with NO
/// simulation model, so a fabric register clocked off their outputs would be
/// dead (z) in a ROHD sim (the "Bad state: No element" / z-clock trap in the
/// rohd-rtl-gotchas skill). To keep the controller's existing functional sims
/// working AND emit the real Lattice primitives for synthesis, this is a
/// [SystemVerilog]-mixin module: its internal ROHD body is a behavioral model
/// (eclk = a buffered source, sclk = a real divide-by-2 flop, ddrdel/lock = 0)
/// that SIMULATES, while [instantiationVerilog] emits the three Lattice leaves
/// for the netlist (and the default empty [definitionVerilog] suppresses the
/// behavioral module definition in synth). The behavioral sclk is a faithful
/// CK/2 clock in sim. On hardware the CLKDIVF drives it.
class Ecp5DdrClockTree extends Module with SystemVerilog {
  /// Edge clock at the CK rate (drives CK ODDR + the read IOLOGIC eclk).
  Logic get eclk => output('eclk');

  /// Fabric/sequencer clock at CK/2.
  Logic get sclk => output('sclk');

  /// DDRDLLA 90-degree delay code (consumed by DQSBUFM in Milestone 2).
  Logic get ddrdel => output('ddrdel');

  /// DDRDLLA lock (exposed for training, tie-off consumer keeps it live).
  Logic get lock => output('lock');

  /// When false (DLL-OFF, static-tap read), the DDRDLLA leaf is OMITTED from the
  /// synth output so [eclk] fans out ONLY to the bank-local CLKDIVF, not the
  /// bank-spanning DDRDLL. The DDRDLL is placed toward the DQS pins it feeds
  /// (OrangeCrab: byte lane 1 in bank 6), which forced [eclk] to reach BOTH DQ
  /// banks off ONE ECLKSYNCB (BEL-locked to bank 7): unroutable ("arc 1 of net
  /// ddr_eclk"). DLL-off does not use the DDREL calibration (the read is a static
  /// DELAYG tap), so dropping it is functionally inert and makes [eclk] a single-
  /// bank net. ddrdel/lock tie to 0 in that build. Default true (DLL-on).
  final bool buildDll;

  Ecp5DdrClockTree(
    Logic clkSource,
    Logic reset, {
    // Lattice DDR PHY init handshake inputs (litedram ECP5DDRPHYInit). All four
    // default to today's hard-tied constants when left unconnected, so non-DDR
    // and pre-init-FSM users of this clock tree are unaffected.
    //   - [uddcntln]: DDRDLLA UDDCNTLN, ACTIVE-LOW. Idles HIGH. The init FSM
    //     pulses it LOW once to latch the calibrated DDRDEL code into the
    //     DQSBUFMs. Default 1 (no update, = the old hard-tie at 1'b0 inverted...
    //     note the OLD code tied UDDCNTLN to 1'b0 = continuous update. The new
    //     default is 1 = idle/no-update, the litedram idle state. The FSM, when
    //     wired, drives the single low pulse).
    //   - [freeze]: DDRDLLA FREEZE. Default 0 (DLL free-running).
    //   - [eclkStop]: ECLKSYNCB STOP. Default 0 (edge clock runs).
    //   - [eclkReset]: ECLK-domain reset pulsed during the DLL update. Default
    //     0 (no extra reset). The CLKDIVF still takes the module [reset].
    //   - [alignwd]: CLKDIVF.ALIGNWD word-align control. Each rising edge slips
    //     the eclk->sclk divide-by-2 word boundary by one eclk cycle. Default 0
    //     (back-compat hard-tie). The DDR PHY init FSM PULSES it high during the
    //     ECLK stop/reset window so the divider re-aligns its word phase
    //     DETERMINISTICALLY on every config instead of powering up on an
    //     arbitrary CK phase (the silicon-only 2-beat-repeat root cause: cosim
    //     CLKDIVF always resets to phase 0, so sim never showed it). litedram
    //     ECP5DDRPHYInit drives the equivalent word-align step (ecp5ddrphy.py
    //     L93-96). No behavioral effect in the sim model (the divide is modelled
    //     as a phase-0 generated clock). It is a synth-leaf control.
    Logic? uddcntln,
    Logic? freeze,
    Logic? eclkStop,
    Logic? eclkReset,
    Logic? alignwd,
    this.buildDll = true,
    super.name = 'ddr_clk_tree',
  }) {
    clkSource = addInput('clk_source', clkSource);
    reset = addInput('reset', reset);
    // UDDCNTLN/FREEZE/eclkReset feed the synth leaves only (see
    // instantiationVerilog). They have no behavioral effect in the sim model
    // (the DLL/DDRDEL leaves are unmodelled), so their ports are created but the
    // returns are intentionally discarded. eclkStop DOES gate the sim eclk.
    addInput('uddcntln', uddcntln ?? Const(1));
    addInput('freeze', freeze ?? Const(0));
    final eclkStopIn = addInput('eclk_stop', eclkStop ?? Const(0));
    addInput('eclk_reset', eclkReset ?? Const(0));
    // alignwd feeds the CLKDIVF synth leaf only (no sim-model effect: the divide
    // is a phase-0 generated clock in sim). Port created, return discarded.
    addInput('alignwd', alignwd ?? Const(0));
    final eclkO = addOutput('eclk');
    final sclkO = addOutput('sclk');
    final ddrdelO = addOutput('ddrdel');
    final lockO = addOutput('lock');

    // eclk tracks the CK-rate source (ECLKSYNCB passes ECLKI through unless STOP
    // is asserted, in which case the edge clock is held). Gating in sim mirrors
    // the real ECLKSYNCB.STOP so an eclk-domain consumer sees the clock stop
    // during the init handshake.
    eclkO <= clkSource & ~eclkStopIn;

    // sclk = source / 2, generated as a GENERATED CLOCK exactly the way
    // SimpleClockGenerator builds its clk: makeUnassignable + an initial put +
    // a FUTURE-TIME scheduled toggle on the source edge. This is the ONLY form
    // that makes the divided sclk a clock a downstream `Sequential(sclk, ...)`
    // OUTSIDE this module actually ticks on (proven empirically):
    //   - A `Sequential` register output used as the divided clock is the
    //     "Bad state: No element" / dead-clock trap from the rohd-rtl-gotchas
    //     skill: the register settles in the clkStable phase, so its edge lands
    //     too late and the sclk-domain flops sit at X forever.
    //   - A same-tick `injectAction` toggle, OR driving the output through a
    //     combinational `sclkO <= internal` hop, ALSO leaves the external
    //     sequencer at X (the edge is consumed by the delta hop before the
    //     trigger sees it).
    //   - The SimpleClockGenerator recipe below (unassignable output + a
    //     `registerAction(time + step)` toggle, no combinational hop) drives a
    //     clean half-rate edge across the module boundary, and the external
    //     sequencer counts on it.
    // On hardware the CLKDIVF leaf (see [instantiationVerilog]) drives sclk.
    // This is its faithful CK/2 simulation stand-in.
    sclkO.makeUnassignable(
      reason: 'sclk is a generated divided clock, not a driven signal',
    );
    // Seed sclk to 0 via a DEFERRED injectAction, not an immediate put: the
    // action runs only when the simulator actually ticks, so a pure
    // build()/generateSynth() (no running Simulator) never glitches sclk and so
    // never leaves a downstream Sequential's clkStable wait dangling -> the
    // "Bad state: No element" trap that an immediate put triggers when the sim
    // is later reset without running. A defined 0 seed is required so the first
    // real edge is a clean 0->1 the downstream flops latch on.
    Simulator.injectAction(() => sclkO.put(0));
    // STOP-GATED divided toggle: sclk flips on every clkSource posedge, scheduled
    // as its OWN future-time simulator event (+1 lands strictly inside the next
    // source cycle for any source period >= 2). Future-time scheduling (not a
    // same-tick injectAction, and no combinational `sclkO <= ...` hop) is what
    // makes this a clean clock edge an external `Sequential(sclk, ...)` ticks on
    // across the module boundary (all three alternatives were found to leave the
    // sclk-domain flops at X).
    //
    // FAITHFUL STOP MODEL: the real CLKDIVF derives sclk from eclk, and
    // ECLKSYNCB.STOP halts eclk, so asserting eclkStop STOPS sclk on hardware.
    // The sim toggle is now gated on ~eclkStopIn (mirroring the eclk gate above)
    // so the model reproduces the self-stop instead of free-running through it.
    // This is what lets ddr_init_timeline_test catch the respin-class bug where
    // the init FSM was clocked on the gated sclk: with the gate live, a
    // sclk-clocked FSM would freeze the moment it asserted eclkStop. The FSM now
    // runs on the ungated init clk (clkSource), so it keeps stepping and releases
    // stop, after which sclk resumes. The timeline completes BECAUSE the FSM is
    // off the gated clock, not because the model ignores stop.
    //
    // It is NOT gated by reset: a real CLKDIVF free-runs and the sclk-domain
    // flops handle reset via their own async reset. Gating the generated clock on
    // reset wedged the downstream flops at X on the irregular reset-release edge.
    clkSource.posedge.listen((_) {
      // Sample eclkStop at the source edge. When stopped, hold sclk at its
      // current level (no toggle) exactly as a stalled CLKDIVF would.
      if (eclkStopIn.value == LogicValue.one) {
        return;
      }
      Simulator.registerAction(
        Simulator.time + 1,
        () => sclkO.put(sclkO.value.isValid ? ~sclkO.value : LogicValue.zero),
      );
    });

    // DDRDEL is the multi-bit calibrated delay CODE. It has no behavioral
    // meaning in sim (only the DQSBUFM read leaf, also unmodelled, consumes it),
    // so tie it to a defined 0.
    ddrdelO <= Const(0);

    // LOCK behavioral model. On real silicon DDRDLLA.LOCK rises once the DLL has
    // locked. The init FSM downstream triggers its DDRDEL-load handshake on the
    // RISING edge of LOCK. To keep that FSM exercised in EVERY running sim (not
    // only a test that force-drives lock), model LOCK as deasserted under reset
    // and asserted a few sclk cycles after reset release. This is a faithful
    // stand-in for "the DLL eventually locks". On hardware the real DDRDLLA leaf
    // drives LOCK. A small shift register clocked on the generated sclk produces
    // the clean 0 -> 1 transition the FSM's edge detector needs.
    final lockShift = Logic(name: 'dll_lock_model', width: 3);
    Sequential(sclkO, reset: reset, [
      lockShift < [lockShift.getRange(0, 2), Const(1)].swizzle(),
    ]);
    lockO <= lockShift[2];
  }

  @override
  String? instantiationVerilog(
    String instanceType,
    String instanceName,
    Map<String, String> ports,
  ) {
    final src = ports['clk_source'];
    final rst = ports['reset'];
    final uddcntln = ports['uddcntln'];
    final freeze = ports['freeze'];
    final eclkStop = ports['eclk_stop'];
    final eclkReset = ports['eclk_reset'];
    final alignwd = ports['alignwd'];
    final eclkO = ports['eclk'];
    final sclkO = ports['sclk'];
    final ddrdelO = ports['ddrdel'];
    final lockO = ports['lock'];
    // Real Lattice edge-clock tree for synthesis (nextpnr-verified leaves):
    //   ECLKSYNCB(src, STOP=eclkStop) -> eclk, CLKDIVF(eclk, DIV "2.0") -> sclk,
    //   DDRDLLA(eclk, UDDCNTLN=uddcntln, FREEZE=freeze) -> ddrdel/lock. The
    // init FSM (litedram ECP5DDRPHYInit) drives STOP/UDDCNTLN/FREEZE plus the
    // ECLK-domain reset to load the calibrated DDRDEL code into the DQSBUFMs.
    // The CLKDIVF reset is OR-ed with the FSM's eclkReset so the divider is
    // re-aligned during the ECLK-domain reset step. Matches the blackbox port
    // names used elsewhere in this file.
    // DLL-OFF: omit the DDRDLLA. It is the bank-spanning eclk sink (placed toward
    // the bank-6 DQS pins it feeds) that makes ddr_eclk need BOTH DQ banks off the
    // single bank-7 ECLKSYNCB, which nextpnr cannot route ("arc 1 of net
    // ddr_eclk"). The static-tap read does not use DDRDEL, so dropping it leaves
    // ddr_eclk with only the bank-local CLKDIVF sink -> single-bank, routable.
    // ddrdel/lock are tied off (lock=0 => the init FSM takes its lock-wait timeout
    // fallback, the same path a never-locking DLL-off DDRDLLA already produced).
    final dllaBlock = buildDll
        ? '''
DDRDLLA ${instanceName}_dlla (
  .CLK($eclkO),
  .RST($rst),
  .UDDCNTLN($uddcntln),
  .FREEZE($freeze),
  .DDRDEL($ddrdelO),
  .LOCK($lockO)
);'''
        : '''
assign $ddrdelO = 8'b0; // DLL-OFF: DDRDLLA omitted (single-bank eclk); read is static-tap
assign $lockO = 1'b0;''';
    // The source goes through an ECLKBRIDGECS before the ECLKSYNCB, as in the
    // LiteX OrangeCrab CRG (gsd_orangecrab.py _CRGSDRAM). Without the bridge
    // one ECLKSYNCB reaches the edge clocks of one chip side only, and a DDR
    // pin map that uses both sides (OrangeCrab: DQ in banks 6/7, address in
    // bank 2) cannot route.
    return '''
// ddr_clk_tree ($instanceName): Lattice 2-phase edge clock + DDRDEL-load init
wire ${instanceName}_ecsout;
ECLKBRIDGECS ${instanceName}_eclkbridge (
  .CLK0($src),
  .CLK1(1'b0),
  .SEL(1'b0),
  .ECSOUT(${instanceName}_ecsout)
);
ECLKSYNCB ${instanceName}_eclksync (
  .ECLKI(${instanceName}_ecsout),
  .STOP($eclkStop),
  .ECLKO($eclkO)
);
CLKDIVF #(.DIV("2.0")) ${instanceName}_clkdiv (
  .CLKI($eclkO),
  .RST($rst | $eclkReset),
  .ALIGNWD($alignwd),
  .CDIVX($sclkO)
);
$dllaBlock''';
  }
}
