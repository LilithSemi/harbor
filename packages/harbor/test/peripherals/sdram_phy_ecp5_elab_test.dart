import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration-shape proof for [SdramPhyEcp5]: every sdram pin is an ecp5 io
/// register, cke alone uses the clear (power-up-low) flop, the merge-risk
/// dq output-enable flops survive as 16 distinct instances with a single
/// fanout each, and the bb/capture/delay wiring matches the chosen config.
void main() {
  tearDown(() async => Simulator.reset());

  int count(String sv, String cell) =>
      RegExp('\\b$cell\\b').allMatches(sv).length;

  /// Port connections of every instance of [cell], by instance name.
  Map<String, Map<String, String>> instances(String sv, String cell) {
    final out = <String, Map<String, String>>{};
    final inst = RegExp(
      '^\\s*$cell\\s+(?:#\\(.*?\\)\\s*)?(\\w+)\\s*\\((.*)\\);\\s*\$',
      multiLine: true,
    );
    for (final m in inst.allMatches(sv)) {
      out[m.group(1)!] = {
        for (final p in RegExp(
          r'\.(\w+)\(([^()]*(?:\([^()]*\))?[^()]*)\)',
        ).allMatches(m.group(2)!))
          p.group(1)!: p.group(2)!,
      };
    }
    return out;
  }

  /// How many times [netName] appears as a whole word anywhere in [sv]:
  /// its own declaration (`logic name`), its own `.Q(name)` (or similar)
  /// producer connection, and every place it is used. A net this PHY means
  /// to drive exactly one place shows up exactly 3 times (declaration,
  /// producer, the one consumer), whether that consumer is another
  /// instance's port connection, an `assign`, or a concatenation list
  /// entry: unlike a port-connection-only scan, this also catches a net
  /// that leaks into a debug `assign` on top of its real consumer. The
  /// `(?<!\.)` excludes a port NAME spelled the same as this net's VALUE
  /// (e.g. a `BB.I`/`.T` keyword, always written right after a `.`): ROHD
  /// can pick a bare one-letter net name like `I` or `T` for whichever net
  /// happens to need no numeric suffix, and every other `BB`'s own `.I`/
  /// `.T` keyword would otherwise false-match it.
  int wholeWordCount(String sv, String netName) =>
      RegExp('(?<!\\.)\\b${RegExp.escape(netName)}\\b').allMatches(sv).length;

  const config = HarborSdramConfig.as4c16m16sb6();

  SdramPhyEcp5 build({
    HarborSdramPhyConfig phy = const HarborSdramPhyConfig(),
  }) => SdramPhyEcp5(
    config,
    casLatency: 3,
    clk: Logic(name: 'clk'),
    reset: Logic(name: 'reset'),
    cke: Logic(name: 'cke'),
    csN: Logic(name: 'cs_n'),
    rasN: Logic(name: 'ras_n'),
    casN: Logic(name: 'cas_n'),
    weN: Logic(name: 'we_n'),
    ba: Logic(name: 'ba', width: config.bankBits),
    addr: Logic(name: 'addr', width: config.rowWidth),
    dqm: Logic(name: 'dqm', width: config.dataWidth ~/ 8),
    dqOut: Logic(name: 'dq_out', width: config.dataWidth),
    dqOe: Logic(name: 'dq_oe', width: config.dataWidth),
    dqPad: LogicNet(name: 'dq_pad', width: config.dataWidth),
    phy: phy,
  );

  test('default config: rising-edge capture counts', () async {
    final phy = build();
    await phy.build();
    final sv = phy.generateSynth();

    // 22 non-dq output flops minus cke (moved to OFS1P3DX) + 16 dq data +
    // 16 dq oe = 53.
    expect(count(sv, 'OFS1P3BX'), equals(53));
    expect(count(sv, 'OFS1P3DX'), equals(1));
    expect(count(sv, 'IFS1P3BX'), equals(16));
    expect(count(sv, 'ODDRX1F'), equals(1));
    expect(count(sv, 'BB'), equals(16));
    expect(count(sv, 'IDDRX1F'), equals(0));
    expect(count(sv, 'DELAYF'), equals(0));

    final oddr = instances(sv, 'ODDRX1F').values.single;
    expect(oddr['D0'], equals("1'h0"));
    expect(oddr['D1'], equals("1'h1"));

    final cke = instances(sv, 'OFS1P3DX').values.single;
    expect(cke['D'], isNotEmpty);

    final bb = instances(sv, 'BB');
    final ofs = instances(sv, 'OFS1P3BX');
    final ifs = instances(sv, 'IFS1P3BX');
    final ofsQNets = {for (final e in ofs.entries) e.value['Q']!: e.key};
    final ifsDNets = {for (final e in ifs.entries) e.value['D']!: e.key};
    expect(bb, hasLength(16));
    for (final b in bb.values) {
      expect(ofsQNets, contains(b['T']), reason: 'bb.T is an ofs1p3bx.Q net');
      expect(ofsQNets, contains(b['I']), reason: 'bb.I is an ofs1p3bx.Q net');
      expect(ifsDNets, contains(b['O']), reason: 'bb.O is an ifs1p3bx.D net');
    }
    // Every dq data/oe ofs flop's Q drives its own bb pin and nothing
    // else: a stray second fanout (a debug port, say) is exactly what
    // stops nextpnr packing the flop into IOLOGIC.
    for (final e in ofs.entries) {
      if (!e.key.startsWith('dq_out_ofs_') && !e.key.startsWith('dq_oe_ofs_')) {
        continue;
      }
      final q = e.value['Q']!;
      expect(
        wholeWordCount(sv, q),
        equals(3),
        reason: '${e.key}.Q must fan out to exactly one place',
      );
    }
  });

  test('wholeWordCount catches a net that also leaks into a debug assign '
      '(the fault a prior debug port actually hit, confirmed against '
      'nextpnr: it could not pack the flop into IOLOGIC)', () {
    const snippet = '''
module m (output dbg_dq_out);
logic I_8;
logic T_8;
OFS1P3BX  dq_out_ofs_9(.D(dq_out[9]),.SCLK(clk),.SP(1'h1),.PD(1'h0),.Q(I_8));
OFS1P3BX  dq_oe_ofs_9(.D(dq_oe_n[9]),.SCLK(clk),.SP(1'h1),.PD(1'h0),.Q(T_8));
BB  dq_bb_9(.I(I_8),.T(T_8),.O(D_7),.B(io_sdram_dq[9]));
assign dbg_dq_out = {
I_8, /*  9 */
I_9  /*  8 */
};
endmodule
''';
    // A correctly single-fanout net (T_8 here, only in BB.T) still comes
    // to 3. I_8 leaking into the debug assign on top of its real BB.I
    // use comes to 4, catching exactly the fault point 6's elab check
    // was meant to catch, now also outside a plain port connection.
    expect(wholeWordCount(snippet, 'T_8'), equals(3));
    expect(wholeWordCount(snippet, 'I_8'), equals(4));
  });

  test('falling-edge capture: IDDRX1F replaces IFS1P3BX on dq in', () async {
    final phy = build(
      phy: const HarborSdramPhyConfig(
        captureEdge: HarborSdramCaptureEdge.falling,
      ),
    );
    await phy.build();
    final sv = phy.generateSynth();

    expect(count(sv, 'IDDRX1F'), equals(16));
    expect(count(sv, 'IFS1P3BX'), equals(0));
  });

  test('dqDelayTaps adds a DELAYF per dq bit, chained bb.O -> delayf.A, '
      'delayf.Z -> ifs1p3bx.D', () async {
    final phy = build(phy: const HarborSdramPhyConfig(dqDelayTaps: 10));
    await phy.build();
    final sv = phy.generateSynth();

    expect(count(sv, 'DELAYF'), equals(16));

    final bb = instances(sv, 'BB');
    final delayf = instances(sv, 'DELAYF');
    final ifs = instances(sv, 'IFS1P3BX');
    final delayfANets = {for (final e in delayf.entries) e.value['A']!: e.key};
    final ifsDNets = {for (final e in ifs.entries) e.value['D']!: e.key};
    expect(delayf, hasLength(16));
    for (final b in bb.values) {
      expect(
        delayfANets,
        contains(b['O']),
        reason: 'bb.O must feed a delayf.A, not ifs1p3bx.D directly',
      );
    }
    for (final d in delayf.values) {
      expect(
        ifsDNets,
        contains(d['Z']),
        reason: 'delayf.Z must feed ifs1p3bx.D',
      );
    }
  });
}
