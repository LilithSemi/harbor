import 'dart:isolate';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../../util/eth_mac_bench.dart';
import '../../util/eth_phy_model.dart';

const _mac = [0x02, 0, 0, 0, 0, 0];

/// [n] frames, first [fixed] lengths, then random lengths of 1 to [maxLen].
/// The first bytes are the MAC address, or broadcast, so the RX filter keeps
/// every frame.
List<List<int>> _frames(
  Random r,
  int n, {
  List<int> fixed = _fixed,
  int maxLen = 1514,
}) {
  int random() => 1 + r.nextInt(maxLen);
  return [
    for (var i = 0; i < n; i++)
      () {
        final len = i < fixed.length ? fixed[i] : random();
        final bcast = len >= 6 && r.nextInt(5) == 0;
        return [
          for (var j = 0; j < len; j++)
            j < 6 ? (bcast ? 0xff : _mac[j]) : r.nextInt(256),
        ];
      }(),
  ];
}

List<int> _padded(List<int> f) => [...f, for (var i = f.length; i < 60; i++) 0];

/// Runs [n] frames through the MAC in PHY loopback and checks them.
Future<void> _loopback({
  required HarborEthernetConfig config,
  required EthLink link,
  required HarborFabricKind kind,
  required int n,
  int sysPeriod = 10,
  int Function(Random)? latency,
  double stall = 0,
  int seed = 1,
  List<int> fixed = _fixed,
  int maxLen = 1514,
}) async {
  final b = await EthMacBench.start(
    config: config,
    link: link,
    kind: kind,
    sysPeriod: sysPeriod,
    latency: latency,
    stall: stall,
    seed: seed,
  );
  final r = Random(seed + 100);
  final frames = _frames(r, n, fixed: fixed, maxLen: maxLen);
  final d = EthDriver(b, seed: seed);
  await b.write(HarborEthReg.intEnable, 0x1f);
  await d.init(ctrl: 0x3 | (link.speedCode << 4));
  // The front end takes the speed before the first frame.
  await b.cycles(100);

  var irqSeen = false;
  b.clk.posedge.listen((_) {
    if (b.irq) irqSeen = true;
  });

  final got = <EthRxDone>[];
  final txDone = <EthTxDone>[];
  var sent = 0;
  var lastProgress = 0;
  var cyc = 0;
  // Three max frames at the link speed, in sys cycles.
  final quiet = 3 * 1600 * 8000 ~/ link.mbps ~/ sysPeriod;
  while (true) {
    var gave = false;
    while (sent < n) {
      final f = frames[sent];
      final pieces = f.length >= 3 && r.nextInt(4) == 0 ? 1 + r.nextInt(3) : 1;
      if (!d.canSend(pieces)) break;
      d.send(f, pieces: pieces, irq: r.nextBool());
      sent++;
      gave = true;
    }
    if (gave) await d.kickTx();
    final t = d.reclaimTx();
    final rx = d.pollRx();
    txDone.addAll(t);
    got.addAll(rx);
    if (rx.isNotEmpty) await d.giveRx();
    if (t.isNotEmpty || rx.isNotEmpty) lastProgress = cyc;
    if (sent == n && d.txDone == d.txGiven && got.length == n) break;
    if (cyc - lastProgress > quiet) break;
    await b.cycles(64);
    cyc += 64;
  }

  // Every TX descriptor came back done with no error.
  check(txDone, hasLength(d.txGiven));
  for (final t in txDone) {
    check(t.word3 & 1, 1, reason: 'tx ${t.index} done');
    check(t.err, 0, reason: 'tx ${t.index} err');
    check(t.word2 >> 24, 0, reason: 'tx ${t.index} OWN clear');
  }

  // The wire has each frame with no gap in TX_EN.
  final wire = b.phy!.txFrames;
  check(wire, hasLength(n));
  for (var i = 0; i < n; i++) {
    check(wire[i].malformed, isFalse, reason: 'wire frame $i');
    check(wire[i].er, isFalse, reason: 'wire frame $i');
    check(wire[i].bytes, ethWireFrame(_padded(frames[i])), reason: 'wire $i');
  }

  // Received frames are the sent frames in order, byte exact.
  var p = 0;
  for (final g in got) {
    while (p < n && !_same(g.data, _padded(frames[p]))) {
      p++;
    }
    check(p, lessThan(n), reason: 'rx ${g.index} matches no frame');
    final f = frames[p];
    final bcast = f.length >= 6 && f[0] == 0xff;
    check(g.err, 0, reason: 'rx frame $p err');
    check(g.length, max(f.length, 60), reason: 'rx frame $p length');
    check(g.word3 >> 16 & 0xf, 0x3 | (bcast ? 0x8 : 0), reason: 'flags $p');
    check(g.word3 >> 25, 0);
    p++;
  }

  final c = {
    for (final (name, off) in [
      ('txFrames', HarborEthReg.txFrames),
      ('rxFrames', HarborEthReg.rxFrames),
      ('fcs', HarborEthReg.rxFcsErr),
      ('missed', HarborEthReg.rxMissed),
      ('overflow', HarborEthReg.rxOverflow),
      ('runt', HarborEthReg.rxRunt),
      ('oversize', HarborEthReg.rxOversize),
    ])
      name: await b.read(off),
  };
  check(c['txFrames'], n);
  check(c['rxFrames'], n);
  check(c['fcs'], 0);
  check(c['runt'], 0);
  check(c['oversize'], 0);
  print('${link.name} ${kind.name}: received ${got.length} of $n, $c');
  check(got.length + c['missed']! + c['overflow']!, n, reason: '$c');
  check(got, hasLength(n), reason: '$c');
  check(c['missed'], 0);
  check(c['overflow'], 0);
  check(await b.read(HarborEthReg.txHead), d.txGiven % d.txN);
  check(await b.read(HarborEthReg.status) & 0x3c, 0, reason: 'no errors');
  check(await b.read(HarborEthReg.intStatus) & 0x1c, 0, reason: 'no err int');
  check(irqSeen, isTrue);
  check(b.mem.errors, isEmpty);
  await b.finish();
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Case {
  final EthLink link;
  final HarborFabricKind kind;
  final bool full;
  final int n;
  final int sysPeriod;
  final int maxLen;

  /// Test timeout in minutes.
  final int minutes;

  const _Case(
    this.link,
    this.kind,
    this.n, {
    this.full = false,
    required this.sysPeriod,
    this.maxLen = 1514,
    this.minutes = 10,
  });

  String get name =>
      '${link.name} ${kind.name} ${full ? 'full' : 'basic'}, $n frames';

  HarborEthernetConfig get config {
    final p = link.phy;
    // At 10 and 100 Mbps the RGMII cases send the TX clock with no shift.
    // The 90 degree clock then is the same clock, which halves the
    // simulator ticks.
    if (p != HarborEthPhy.rgmii || link.mbps == 1000) {
      return full
          ? HarborEthernetConfig.full(phy: p)
          : HarborEthernetConfig.basic(phy: p);
    }
    final f = HarborEthernetConfig.full(phy: p);
    return full
        ? HarborEthernetConfig(
            phy: p,
            maxSpeed: f.maxSpeed,
            multicastHash: true,
            promiscuous: true,
            txFifoBytes: f.txFifoBytes,
            rxFifoBytes: f.rxFifoBytes,
            outstanding: f.outstanding,
            burstBeats: f.burstBeats,
            txClockShift: false,
          )
        : HarborEthernetConfig(phy: p, txClockShift: false);
  }

  Future<void> run() => _loopback(
    config: config,
    link: link,
    kind: kind,
    n: n,
    sysPeriod: sysPeriod,
    latency: EthWaistMem.dramLatency,
    stall: 0.1,
    maxLen: maxLen,
  );
}

const _fixed = [1, 59, 60, 61, 64, 1514];
const _wb = HarborFabricKind.wishbone;
const _axi = HarborFabricKind.axi4;
const _tl = HarborFabricKind.tilelink;

// Each case sends at least 20 frames with lengths 1, 60, 64 and 1514. On
// the slow links the other frames are short, because a simulator tick
// costs time for every wire and those links have many ticks for each byte.
const _cases = [
  _Case(EthLink.mii10, _wb, 20, sysPeriod: 100, maxLen: 400),
  _Case(EthLink.mii10, _axi, 20, sysPeriod: 100, maxLen: 400, full: true),
  _Case(EthLink.mii100, _wb, 40, sysPeriod: 20),
  _Case(EthLink.mii100, _axi, 40, sysPeriod: 20, full: true),
  _Case(EthLink.mii100, _tl, 20, sysPeriod: 20, full: true),
  _Case(EthLink.rmii10, _wb, 20, sysPeriod: 20, maxLen: 100, minutes: 15),
  _Case(
    EthLink.rmii10,
    _axi,
    20,
    sysPeriod: 20,
    maxLen: 100,
    full: true,
    minutes: 15,
  ),
  _Case(EthLink.rmii100, _wb, 40, sysPeriod: 20),
  _Case(EthLink.rmii100, _axi, 40, sysPeriod: 20, full: true),
  _Case(EthLink.rgmii10, _wb, 20, sysPeriod: 8, maxLen: 64, minutes: 20),
  _Case(
    EthLink.rgmii10,
    _axi,
    20,
    sysPeriod: 8,
    maxLen: 64,
    full: true,
    minutes: 20,
  ),
  _Case(EthLink.rgmii100, _wb, 20, sysPeriod: 8),
  _Case(EthLink.rgmii100, _axi, 20, sysPeriod: 8, full: true),
  _Case(EthLink.rgmii1000, _wb, 200, sysPeriod: 4, full: true, minutes: 30),
  _Case(EthLink.rgmii1000, _axi, 200, sysPeriod: 4, full: true, minutes: 30),
];

/// Sends 1514-byte frames on a wire-limited link and returns the longest run
/// of cycles with Wishbone CYC high and STB low on the DMA port.
Future<int> _wishboneHold() async {
  final b = await EthMacBench.start(
    config: HarborEthernetConfig.basic(phy: HarborEthPhy.mii),
    link: EthLink.mii100,
    sysPeriod: 20,
    loopback: false,
  );
  final cyc = b.top.mac.output('dma_CYC');
  final stb = b.top.mac.output('dma_STB');
  var run = 0;
  var longest = 0;
  b.clk.posedge.listen((_) {
    final c = cyc.value;
    final s = stb.value;
    if (c.isValid && c.toBool() && s.isValid && !s.toBool()) {
      run++;
      longest = max(longest, run);
    } else {
      run = 0;
    }
  });
  final d = EthDriver(b);
  await d.init(ctrl: 0x1 | 0x10);
  final r = Random(4);
  const n = 6;
  for (var i = 0; i < n; i++) {
    d.send([..._mac, for (var j = 6; j < 1514; j++) r.nextInt(256)]);
  }
  await d.kickTx();
  while (b.phy!.txFrames.length < n) {
    await b.cycles(256);
  }
  check(d.reclaimTx(), hasLength(n));
  check(b.mem.errors, isEmpty);
  await b.finish();
  return longest;
}

void main() {
  test(
    'the TX DMA does not hold the Wishbone bus while the wire drains',
    () async {
      final longest = await Isolate.run(_wishboneHold);
      expect(longest, lessThanOrEqualTo(8), reason: 'CYC high, STB low');
    },
  );

  // Each case runs in its own isolate. ROHD keeps a listener for every wire
  // it ever made, so designs of earlier tests would slow the later ones.
  for (final c in _cases) {
    test(
      c.name,
      () => Isolate.run(c.run),
      timeout: Timeout(Duration(minutes: c.minutes)),
    );
  }
}
