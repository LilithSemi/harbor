import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

import 'sdram_pin_model.dart';

/// Controller-side pin driver for [SdramPhyEcp5]: it owns the phy's
/// engine-facing inputs and changes them on `clk` negedges, so every rising
/// edge the phy's own io registers capture sees a stable setup margin.
class SdramPhyEcp5Driver {
  SdramPhyEcp5Driver(this.clk) {
    Simulator.injectAction(() {
      dqOe.put(0);
      dqOut.put(0);
    });
  }

  final Logic clk;
  final Logic cke = Logic(name: 'cke')..inject(0);
  final Logic csN = Logic(name: 'cs_n')..inject(1);
  final Logic rasN = Logic(name: 'ras_n')..inject(1);
  final Logic casN = Logic(name: 'cas_n')..inject(1);
  final Logic weN = Logic(name: 'we_n')..inject(1);
  final Logic ba = Logic(name: 'ba', width: 2)..inject(0);
  final Logic addr = Logic(name: 'addr', width: 13)..inject(0);
  final Logic dqm = Logic(name: 'dqm', width: 2)..inject(0);
  final Logic dqOut = Logic(name: 'dq_out', width: 16);
  final Logic dqOe = Logic(name: 'dq_oe', width: 16);

  Future<void> _issue(
    int cmd3, {
    int bank = 0,
    int a = 0,
    int cke = 1,
    int? data,
    int dqmBits = 0,
  }) async {
    await clk.nextNegedge;
    rasN.put((cmd3 >> 2) & 1);
    casN.put((cmd3 >> 1) & 1);
    weN.put(cmd3 & 1);
    csN.put(0);
    ba.put(bank);
    addr.put(a);
    this.cke.put(cke);
    dqm.put(dqmBits);
    if (data != null) {
      dqOut.put(data);
      dqOe.put(0xFFFF); // one shared engine-side enable across every bit.
    } else {
      dqOe.put(0);
    }
    await clk.nextPosedge;
  }

  /// A real nop: every command pin re-driven to deselect, not just left at
  /// whatever a previous command set. Holding a command's pins across
  /// extra cycles instead of this would re-issue it every one of them.
  Future<void> nop({int cke = 1}) => _issue(7, cke: cke);
  Future<void> prechargeAll() => _issue(2, a: 1 << 10);
  Future<void> mrs(int word) => _issue(0, a: word);
  Future<void> refresh() => _issue(1);
  Future<void> activate(int bank, int row) => _issue(3, bank: bank, a: row);
  Future<void> read(int bank, int col) => _issue(5, bank: bank, a: col);

  Future<void> write(int bank, int col, int data, {int dqmBits = 0}) =>
      _issue(4, bank: bank, a: col, data: data, dqmBits: dqmBits);

  Future<void> waitEdges(int n) async {
    for (var i = 0; i < n; i++) {
      await nop();
    }
  }
}

/// Merges [data] into the datasheet's unwritten-word pattern the way
/// [SdramPinModel] does, so a partially dqm-masked write has a known
/// expected readback.
int sdramPhyExpectedWord(int bank, int row, int col, int data, int dqmBits) {
  var merged = SdramPinModel.initialWord(bank, row, col);
  if ((dqmBits & 1) == 0) merged = (merged & 0xFF00) | (data & 0xFF);
  if ((dqmBits & 2) == 0) merged = (merged & 0x00FF) | (data & 0xFF00);
  return merged & 0xFFFF;
}

const sdramPhyTestConfig = HarborSdramConfig.as4c16m16sb6();
const sdramPhyTestGap = 20; // generous: above every datasheet minimum.

/// ECP5 tSUPLL / tHPLL (Lattice FPGA-DS-02012 v1.9, table 3.22): the fpga's
/// own input register wants data this far clear of the capture edge, on
/// top of the chip's own valid window ([SdramPhyEcp5]'s class doc).
const sdramPhyTsuNs = 0.85;
const sdramPhyThNs = 0.98;

/// The raw pad-level sample point, in sdram_clk cycles past the chip's own
/// committing edge `E` ([SdramPhyEcp5]'s class doc): `0.5` for rising
/// capture (the inverted clock's own rising edge), `0` for falling, plus
/// [HarborSdramPhyConfig.captureCycleOffset] whole cycles more.
double sdramPhyCaptureM(HarborSdramPhyConfig phy) =>
    (phy.captureEdge == HarborSdramCaptureEdge.rising ? 0.5 : 0.0) +
    phy.captureCycleOffset;

/// Whether a beat sampled at [sdramPhyCaptureM] cycles past `E` lands
/// inside `[E - tCk + d + tAC, E + d + tOH]` with the fpga's own tSU/tH
/// margin still clear on both sides, for the given [periodPs] (`tCk`),
/// [tAcNs] and board flight [fpgaToSdramNs] + `sdramToFpgaNs` (0.5 ns,
/// [SdramPinModel]'s default). `tOH` is the datasheet's fixed 2.5 ns.
bool sdramPhyCaptureOk({
  required int periodPs,
  required double tAcNs,
  required double fpgaToSdramNs,
  required HarborSdramPhyConfig phy,
}) {
  const tOhNs = 2.5;
  const sdramToFpgaNs = 0.5;
  final m = sdramPhyCaptureM(phy);
  final samplePs = (m * periodPs).round();
  final dPs = ((fpgaToSdramNs + sdramToFpgaNs) * 1000).round();
  final dMinPs =
      samplePs - (tOhNs * 1000).round() + (sdramPhyThNs * 1000).round();
  final dMaxPs =
      samplePs +
      periodPs -
      (tAcNs * 1000).round() -
      (sdramPhyTsuNs * 1000).round();
  return dPs >= dMinPs && dPs <= dMaxPs;
}

/// The 16 [Ecp5Bb] dq pad buffers inside [phy], indexed the way
/// [SdramPhyEcp5] names them (`dq_bb_0`..`dq_bb_15`).
List<Ecp5Bb> _sdramPhyDqBbs(SdramPhyEcp5 phy, int dataWidth) {
  final byName = {
    for (final m in phy.subModules.whereType<Ecp5Bb>()) m.name: m,
  };
  return [for (var i = 0; i < dataWidth; i++) byName['dq_bb_$i']!];
}

/// Result of one [runSdramPhyEcp5Case]: the 8 burst beats as the phy
/// returned them, what they should have been, and every rule the model
/// saw broken.
class SdramPhyEcp5RunResult {
  SdramPhyEcp5RunResult(this.beats, this.expected, this.modelErrors);

  final List<LogicValue> beats;
  final List<int> expected;
  final List<String> modelErrors;

  /// True only if every beat is valid, correct, and the model saw no
  /// protocol violation.
  bool get allCorrect =>
      modelErrors.isEmpty &&
      List.generate(
        beats.length,
        (i) => beats[i].isValid && beats[i].toInt() == expected[i],
      ).every((ok) => ok);
}

/// Builds the phy + model, runs init, 8 refreshes, an activate, 8 writes
/// with mixed dqm, then one real read (the BL8 burst that returns all 8
/// written words) followed by real nops, and samples `rdData` once per
/// beat.
///
/// Beat 0 is sampled [sdramOffsetCycles] cycles after [SdramPhyEcp5
/// .readLatency] past the edge the read command is issued on, read()'s own
/// return included: `readLatency` itself counts from the engine's own
/// phy_* cycle, one cycle earlier than that (the output register's own
/// cycle), so this file samples at `readLatency - 1 + sampleOffsetCycles`.
/// Every later beat follows exactly 1 cycle after the one before it,
/// whatever [sampleOffsetCycles] shifted beat 0 by, so a wrong offset
/// shows up as every beat landing on its neighbor's data instead, not just
/// a single missed sample.
///
/// The model's `fpgaDqOe`/`fpgaDqOut` are read from the phy's own `BB`
/// pad buffers through the module hierarchy (T inverted, since `BB.T` is
/// active low), not from a debug port on the phy: a debug port fanning out
/// an io-register's `Q` to anywhere other than its own pad is exactly the
/// fault that stops nextpnr packing it into IOLOGIC.
Future<SdramPhyEcp5RunResult> runSdramPhyEcp5Case({
  required int periodPs,
  required int casLatency,
  required double fpgaToSdramNs,
  HarborSdramPhyConfig phy = const HarborSdramPhyConfig(),
  int sampleOffsetCycles = 0,
}) async {
  const bank = 0, row = 0;
  final config = sdramPhyTestConfig;
  final clk = SimpleClockGenerator(periodPs).clk;
  final reset = Logic(name: 'reset')..inject(0);
  final driver = SdramPhyEcp5Driver(clk);
  final dqPad = LogicNet(name: 'dq_pad', width: config.dataWidth);

  final sdramPhy = SdramPhyEcp5(
    config,
    casLatency: casLatency,
    clk: clk,
    reset: reset,
    cke: driver.cke,
    csN: driver.csN,
    rasN: driver.rasN,
    casN: driver.casN,
    weN: driver.weN,
    ba: driver.ba,
    addr: driver.addr,
    dqm: driver.dqm,
    dqOut: driver.dqOut,
    dqOe: driver.dqOe,
    dqPad: dqPad,
    phy: phy,
  );
  await sdramPhy.build();

  final bbs = _sdramPhyDqBbs(sdramPhy, config.dataWidth);
  final fpgaDqOe = [for (final bb in bbs) ~bb.input('T')].rswizzle();
  final fpgaDqOut = [for (final bb in bbs) bb.input('I')].rswizzle();

  final rules = const SdramModelRules.as4c16m16sb6().copyWith(powerUpNs: 2000);
  final model = SdramPinModel(
    clk: sdramPhy.oSdramClk,
    cke: sdramPhy.oSdramCke,
    csN: sdramPhy.oSdramCsN,
    rasN: sdramPhy.oSdramRasN,
    casN: sdramPhy.oSdramCasN,
    weN: sdramPhy.oSdramWeN,
    ba: sdramPhy.oSdramBa,
    addr: sdramPhy.oSdramAddr,
    dqm: sdramPhy.oSdramDqm,
    dq: sdramPhy.ioSdramDq as LogicNet,
    rules: rules,
    fpgaToSdramNs: fpgaToSdramNs,
    fpgaDqOe: fpgaDqOe,
    fpgaDqOut: fpgaDqOut,
  );

  Simulator.setMaxSimTime(40000000);
  unawaited(Simulator.run());

  final powerUpCycles = (rules.powerUpNs * 1000 / periodPs).ceil() + 5;
  for (var i = 0; i < powerUpCycles; i++) {
    await driver.nop(cke: 0);
  }
  await driver.nop(cke: 1);

  await driver.prechargeAll();
  await driver.waitEdges(sdramPhyTestGap);
  await driver.mrs(config.modeRegister(casLatency));
  await driver.waitEdges(sdramPhyTestGap);
  for (var i = 0; i < 8; i++) {
    await driver.refresh();
    await driver.waitEdges(sdramPhyTestGap);
  }
  await driver.activate(bank, row);
  await driver.waitEdges(sdramPhyTestGap);

  const data = [
    0x1234, 0x5678, 0x9abc, 0xdef0, //
    0x1111, 0x2222, 0x3333, 0x4444,
  ];
  const dqmSeq = [0, 1, 2, 0, 1, 2, 0, 1];
  final expected = <int>[];
  for (var col = 0; col < 8; col++) {
    await driver.write(bank, col, data[col], dqmBits: dqmSeq[col]);
    expected.add(sdramPhyExpectedWord(bank, row, col, data[col], dqmSeq[col]));
    await driver.waitEdges(sdramPhyTestGap);
  }

  // One read, column 0: the burst returns columns 0..7 in order, matching
  // the columns just written.
  await driver.read(bank, 0);
  final beats = <LogicValue>[];
  final firstBeatCycles = sdramPhy.readLatency - 1 + sampleOffsetCycles;
  if (firstBeatCycles < 0) {
    throw ArgumentError('sampleOffsetCycles left beat 0 before the read');
  }
  for (var i = 0; i < 8; i++) {
    final cyclesThisBeat = i == 0 ? firstBeatCycles : 1;
    for (var k = 0; k < cyclesThisBeat; k++) {
      await driver.nop();
    }
    beats.add(sdramPhy.rdData.value);
  }
  await driver.waitEdges(sdramPhyTestGap);

  await Simulator.endSimulation();
  return SdramPhyEcp5RunResult(beats, expected, model.errors);
}
