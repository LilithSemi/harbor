import 'dart:isolate';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_mac_bench.dart';
import '../../util/eth_phy_model.dart';

typedef R = HarborEthReg;

HarborEthernetConfig _basic(HarborEthPhy p) =>
    HarborEthernetConfig.basic(phy: p);

HarborEthernetConfig _full(HarborEthPhy p) => HarborEthernetConfig.full(phy: p);

EthLink _link(HarborEthPhy p) => switch (p) {
  HarborEthPhy.mii => EthLink.mii100,
  HarborEthPhy.rmii => EthLink.rmii100,
  HarborEthPhy.rgmii => EthLink.rgmii1000,
};

Future<void> _resetValues(HarborEthernetConfig config) async {
  final b = await EthMacBench.start(
    config: config,
    link: _link(config.phy),
    sysPeriod: config.phy == HarborEthPhy.rgmii ? 8 : 10,
  );
  final want = {
    R.id: R.idValue,
    R.hwCaps: config.hwCaps,
    R.ctrl: 0x40,
    R.status: 0,
    R.intStatus: 0,
    R.intEnable: 0,
    R.macLo: 0,
    R.macHi: 0,
    R.mcHashLo: 0,
    R.mcHashHi: 0,
    R.txRingLo: 0,
    R.txRingHi: 0,
    R.txRingSize: 1,
    R.txTail: 0,
    R.txHead: 0,
    R.rxRingLo: 0,
    R.rxRingHi: 0,
    R.rxRingSize: 1,
    R.rxTail: 0,
    R.rxHead: 0,
    R.mdioCtrl: 0,
    R.mdioData: 0,
    R.mdioDiv: R.mdioDivReset,
    for (var o = R.txFrames; o <= R.rxPause; o += 4) o: 0,
    0x100: 0,
    0x200: 0,
    0xFFC: 0,
  };
  for (final e in want.entries) {
    check(
      await b.read(e.key),
      e.value,
      reason: 'offset 0x${e.key.toRadixString(16)}',
    );
  }
  check(b.irq, isFalse);
  await b.finish();
}

Future<void> _masks(HarborEthernetConfig config, int dmaAddressWidth) async {
  final b = await EthMacBench.start(
    config: config,
    link: _link(config.phy),
    sysPeriod: config.phy == HarborEthPhy.rgmii ? 8 : 10,
    dmaAddressWidth: dmaAddressWidth,
    loopback: false,
  );
  final gig = config.maxSpeed == HarborEthSpeed.mbps1000;
  Future<int> wr(int off, int v) async {
    await b.write(off, v);
    return b.read(off);
  }

  // Soft reset (bit 7) is not written here.
  check(
    await wr(R.ctrl, 0x7F),
    0x4B | (config.promiscuous ? 0x04 : 0) | (gig ? 0x30 : 0x10),
  );
  await b.write(R.ctrl, 0);
  check(await wr(R.macLo, 0xAABBCCDD), 0xAABBCCDD);
  check(await wr(R.macHi, 0xFFFF1234), 0x1234);
  final hash = config.multicastHash;
  check(await wr(R.mcHashLo, 0x89ABCDEF), hash ? 0x89ABCDEF : 0);
  check(await wr(R.mcHashHi, 0x01234567), hash ? 0x01234567 : 0);
  final loMask =
      (dmaAddressWidth >= 32 ? 0xFFFFFFFF : (1 << dmaAddressWidth) - 1) &
      ~(config.descBytes - 1);
  final hiMask = dmaAddressWidth > 32 ? (1 << (dmaAddressWidth - 32)) - 1 : 0;
  for (final (lo, hi, size, tail, head) in [
    (R.txRingLo, R.txRingHi, R.txRingSize, R.txTail, R.txHead),
    (R.rxRingLo, R.rxRingHi, R.rxRingSize, R.rxTail, R.rxHead),
  ]) {
    check(await wr(lo, 0xFFFFFFFF), loMask);
    check(await wr(hi, 0xFFFFFFFF), hiMask);
    check(await wr(size, 0), 1);
    check(await wr(size, 13), 12);
    check(await wr(size, 15), 12);
    check(await wr(size, 3), 3);
    check(await wr(tail, 0xFFF), 7, reason: 'tail masked to size');
    check(await wr(size, 12), 12);
    check(await b.read(tail), 0, reason: 'a ring write clears tail');
    check(await wr(tail, 0x123), 0x123);
    await b.write(lo, 0);
    check(await b.read(tail), 0, reason: 'a ring write clears tail');
    check(await wr(head, 5), 0, reason: 'head is read only');
  }
  check(await wr(R.intEnable, 0xFFFFFFFF), 0x1F);
  check(await wr(R.intStatus, 0xFFFFFFFF), 0);
  check(await wr(R.status, 0xFFFFFFFF), 0);
  final c45 = config.mdioC45;
  check(await wr(R.mdioCtrl, 0x001F0FFF), c45 ? 0x1F0FFF : 0x7FF);
  check(await wr(R.mdioData, 0xFFFFFFFF), c45 ? 0xFFFFFFFF : 0xFFFF);
  check(await wr(R.mdioDiv, 0x1FF), 0xFF);
  for (final off in [R.hwCaps, R.id, R.txFrames, R.txPause, R.rxPause, 0x100]) {
    final before = await b.read(off);
    check(await wr(off, 0x5A5A5A5A), before, reason: 'read only 0x$off');
  }
  await b.finish();
}

Future<void> _byteLanes() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    loopback: false,
  );
  await b.write(R.macLo, 0x11223344);
  await b.write(R.macLo, 0xFFFFFFFF, sel: 0);
  check(await b.read(R.macLo), 0x11223344, reason: 'no byte selected');
  await b.write(R.macLo, 0xAABBCCDD, sel: 0x4);
  check(await b.read(R.macLo), 0x11BB3344);
  await b.write(R.ctrl, 0x03);
  await b.write(R.ctrl, 0x80, sel: 0);
  check(await b.read(R.ctrl), 0x43, reason: 'no soft reset, no change');
  await b.write(R.ctrl, 0x00, sel: 0x2);
  check(await b.read(R.ctrl), 0x43, reason: 'CTRL is in byte 0');
  await b.write(R.mdioCtrl, 0x2 | (3 << 5));
  await b.write(R.mdioCtrl, 0x1 << 8, sel: 0x2);
  check(
    await b.read(R.mdioCtrl),
    0x2 | (3 << 5) | (1 << 8),
    reason: 'phy bit 8 written alone',
  );
  await b.finish();
}

Future<void> _fabric(HarborFabricKind kind) async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.rmii),
    link: EthLink.rmii100,
    kind: kind,
    loopback: false,
  );
  check(await b.read(R.id), R.idValue);
  check(await b.read(R.hwCaps), b.config.hwCaps);
  await b.write(R.macLo, 0xCAFEF00D);
  check(await b.read(R.macLo), 0xCAFEF00D);
  check(await b.read(0x104), 0);
  // Accesses back to back, each one right after the ack of the one before,
  // with the register file one cycle behind the request.
  final rng = Random(kind.index);
  for (var i = 0; i < 24; i++) {
    final lo = rng.nextInt(1 << 32);
    final hi = rng.nextInt(1 << 16);
    final div = rng.nextInt(256);
    await b.write(R.macLo, lo);
    await b.write(R.macHi, hi);
    await b.write(R.mdioDiv, div);
    check(await b.read(R.macHi), hi, reason: 'MAC_HI $i');
    check(await b.read(R.macLo), lo, reason: 'MAC_LO $i');
    check(await b.read(R.mdioDiv), div, reason: 'MDIO_DIV $i');
    check(await b.read(R.id), R.idValue, reason: 'ID $i');
  }
  await b.finish();
}

Future<void> _pollMdio(EthMacBench b) async {
  // Busy reads 1 at once after the start.
  check(await b.read(R.mdioCtrl) & (1 << 13), 1 << 13);
  for (var i = 0; i < 1000; i++) {
    if (await b.read(R.mdioCtrl) & (1 << 13) == 0) return;
    await b.cycles(20);
  }
  throw TestFailure('MDIO busy does not end');
}

Future<void> _mdio(bool c45) async {
  final b = await EthMacBench.start(
    config: HarborEthernetConfig(phy: HarborEthPhy.mii, mdioC45: c45),
    link: EthLink.mii100,
    loopback: false,
  );
  await b.write(R.mdioDiv, 1);
  await b.write(R.mdioData, 0xBEEF);
  await b.write(R.mdioCtrl, 4 | (3 << 5) | (1 << 10) | (1 << 12));
  await _pollMdio(b);
  check(b.mdio.c22[4], 0xBEEF);
  b.mdio.c22[9] = 0x1357;
  await b.write(R.mdioCtrl, 9 | (3 << 5) | (1 << 12));
  await _pollMdio(b);
  check(await b.read(R.mdioData) & 0xFFFF, 0x1357);
  if (c45) {
    await b.write(R.mdioData, (0x0807 << 16) | 0xCAFE);
    await b.write(
      R.mdioCtrl,
      (1 << 16) | (3 << 5) | (1 << 10) | (1 << 11) | (1 << 12),
    );
    await _pollMdio(b);
    check(b.mdio.c45[(1 << 16) | 0x0807], 0xCAFE);
    b.mdio.c45[(7 << 16) | 0x3C] = 0x4321;
    await b.write(R.mdioData, 0x3C << 16);
    await b.write(R.mdioCtrl, (7 << 16) | (3 << 5) | (1 << 11) | (1 << 12));
    await _pollMdio(b);
    check(await b.read(R.mdioData), (0x3C << 16) | 0x4321);
  }
  check(b.mdio.contention, 0);
  await b.finish();
}

Future<void> _waitFor(
  EthMacBench b,
  Future<bool> Function() done,
  String what, {
  int polls = 400,
}) async {
  for (var i = 0; i < polls; i++) {
    if (await done()) return;
    await b.cycles(50);
  }
  throw TestFailure('timed out: $what');
}

Future<void> _txRingErr(HarborFabricKind kind) async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    kind: kind,
    latency: EthWaistMem.dramLatency,
  );
  final d = EthDriver(b);
  b.mem.readErr.add((d.txRing, d.txRing + 16));
  await b.write(R.intEnable, 1 << 2);
  await d.init(ctrl: 0x1 | 0x10);
  d.send(List.generate(80, (i) => i), irq: false);
  await d.kickTx();
  await _waitFor(b, () async => await b.read(R.status) & 0x4 != 0, 'ring err');
  check(await b.read(R.intStatus), 1 << 2);
  await b.cycles(2);
  check(b.irq, isTrue);
  check(await b.read(R.txHead), 0);
  check(b.phy!.txFrames, isEmpty);
  // The first descriptor of the frame gets err 1.
  check(b.mem.word(d.txDesc(0) + 12), 1 | (1 << 1));
  check(b.mem.word(d.txDesc(0) + 8) >> 31, 0);
  // The ring stays stopped and the sticky bit clears on write 1.
  await b.write(R.status, 0x4);
  check(await b.read(R.status) & 0x4, 0);
  await b.cycles(500);
  check(await b.read(R.status) & 0x5, 0, reason: 'not running, no new err');
  // The driver gives the frame again and resets the ring with a base write.
  b.mem.readErr.clear();
  d.txGiven = 0;
  d.txDone = 0;
  d.send(List.generate(80, (i) => i), irq: false);
  await b.write(R.txRingLo, d.txRing);
  await d.kickTx();
  await _waitFor(b, () async => d.reclaimTx().isNotEmpty, 'frame sent');
  check(b.mem.word(d.txDesc(0) + 12), 1, reason: 'done, no error');
  await _waitFor(b, () async => b.phy!.txFrames.isNotEmpty, 'wire');
  check(await b.read(R.status) & 0x4, 0);
  await b.write(R.intStatus, 1 << 2);
  await b.cycles(2);
  check(b.irq, isFalse);
  await b.finish();
}

Future<void> _rxErrors(HarborFabricKind kind) async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    kind: kind,
    loopback: false,
  );
  final m = b.phy! as EthMiiModel;
  final d = EthDriver(b);
  final frame = [0x02, 0, 0, 0, 0, 0, for (var i = 6; i < 70; i++) i];
  await b.write(R.intEnable, 0x1F);
  // No RX descriptor: the frame is missed.
  await d.init(ctrl: 0x2 | 0x10, give: false);
  await m.sendFrame(ethWireFrame(frame));
  await _waitFor(b, () async => await b.read(R.rxMissed) == 1, 'missed');
  check(await b.read(R.intStatus), 1 << 4);
  await b.write(R.intStatus, 1 << 4);
  // A descriptor read error stops the ring.
  b.mem.readErr.add((d.rxRing, d.rxRing + 16));
  await d.giveRx();
  await m.sendFrame(ethWireFrame(frame));
  await _waitFor(b, () async => await b.read(R.status) & 0x8 != 0, 'ring err');
  check(await b.read(R.intStatus) & 0x8, 0x8);
  check(await b.read(R.rxHead), 0);
  await b.write(R.status, 0x8);
  check(await b.read(R.status) & 0x8, 0);
  // Recover: clear the error and reset the ring.
  b.mem.readErr.clear();
  await b.write(R.rxRingLo, d.rxRing);
  await b.write(R.rxTail, d.rxGiven % d.rxN);
  await b.cycles(20);
  await m.sendFrame(ethWireFrame(frame));
  await _waitFor(b, () async => d.pollRx().isNotEmpty, 'frame received');
  check(b.mem.getBytes(d.rxBuf(0), frame.length), frame);
  check(await b.read(R.rxHead), 1);
  check(await b.read(R.status) & 0x8, 0);
  check(await b.read(R.rxFrames), 3);
  await b.finish();
}

Future<void> _clockLoss() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    stopClocks: true,
  );
  final d = EthDriver(b);
  await b.write(R.intEnable, 1 << 2);
  await d.init(ctrl: 0x3 | 0x10);
  b.txClock!.running = false;
  await b.cycles(harborEthClkLostCycles + 200);
  check(await b.read(R.status), 0x20 | 0x3, reason: 'tx_clk_lost');
  // A frame for a lost TX clock comes back with err 4.
  d.send(List.generate(100, (i) => i));
  await d.kickTx();
  await _waitFor(b, () async => d.reclaimTx().isNotEmpty, 'write-back');
  check(b.mem.word(d.txDesc(0) + 12), 1 | (4 << 1));
  check(await b.read(R.intStatus) & 0x4, 0x4);
  check(await b.read(R.status) & 0x4, 0, reason: 'the ring goes on');
  b.txClock!.running = true;
  await b.cycles(100);
  await b.write(R.status, 0x20);
  check(await b.read(R.status) & 0x30, 0);
  // After recovery a frame goes out with no error.
  var txEn = false;
  b.top.output('mii_tx_en').posedge.listen((_) => txEn = true);
  d.send(List.generate(100, (i) => i));
  await d.kickTx();
  await _waitFor(b, () async => d.reclaimTx().isNotEmpty, 'second frame');
  check(b.mem.word(d.txDesc(1) + 12), 1);
  await _waitFor(b, () async => txEn, 'tx_en');
  // RX clock loss.
  b.rxClock!.running = false;
  await b.cycles(harborEthClkLostCycles + 200);
  check(await b.read(R.status) & 0x30, 0x10, reason: 'rx_clk_lost');
  b.rxClock!.running = true;
  await b.cycles(100);
  await b.write(R.status, 0x10);
  check(await b.read(R.status) & 0x30, 0);
  await b.finish();
}

Future<void> _softReset() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    loopback: false,
  );
  final m = b.phy! as EthMiiModel;
  final d = EthDriver(b);
  final frame = [0x02, 0, 0, 0, 0, 0, for (var i = 6; i < 70; i++) i];
  await b.write(R.intEnable, 0x10);
  await d.init(ctrl: 0x3 | 0x10, give: false);
  await m.sendFrame(ethWireFrame(frame));
  await _waitFor(b, () async => await b.read(R.rxMissed) == 1, 'missed');
  // Descriptors with OWN clear: the TX DMA waits on the first one.
  await b.write(R.txTail, 3);
  await b.write(R.rxTail, 5);
  check(await b.read(R.intStatus), 0x10);
  await b.write(R.ctrl, 0x83 | 0x10);
  await _waitFor(
    b,
    () async => await b.read(R.ctrl) & 0x80 == 0,
    'soft reset ends',
  );
  check(await b.read(R.ctrl), 0x53, reason: 'CTRL keeps its bits');
  check(await b.read(R.txTail), 0);
  check(await b.read(R.rxTail), 0);
  check(await b.read(R.txHead), 0);
  check(await b.read(R.intStatus), 0);
  check(await b.read(R.rxMissed), 1, reason: 'counters stay');
  check(await b.read(R.macLo), 2, reason: 'MAC address stays');
  check(await b.read(R.txRingLo), d.txRing);
  // The MAC works after the reset.
  d.rxGiven = 0;
  d.rxDone = 0;
  await d.giveRx();
  await m.sendFrame(ethWireFrame(frame));
  await _waitFor(b, () async => d.pollRx().isNotEmpty, 'frame received');
  check(b.mem.getBytes(d.rxBuf(0), frame.length), frame);
  await b.finish();
}

List<int> _frame(Random r, int len) => [
  for (var j = 0; j < len; j++) j < 6 ? (j == 0 ? 2 : 0) : r.nextInt(256),
];

Future<void> _running() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    sysPeriod: 20,
    loopback: false,
  );
  final m = b.phy! as EthMiiModel;
  final d = EthDriver(b);
  await d.init(ctrl: 0x1 | 0x10);
  final r = Random(9);
  d.send(_frame(r, 1514));
  d.send(_frame(r, 1514));
  await d.kickTx();
  final done = <EthTxDone>[];
  await _waitFor(
    b,
    () async {
      done.addAll(d.reclaimTx());
      return done.length == 2;
    },
    'both frames in the FIFO',
    polls: 4000,
  );
  // The DMA is done, the frames are still in the FIFO and on the wire.
  await b.write(R.ctrl, 0x10);
  check(await b.read(R.status) & 0x1, 1, reason: 'tx_running');
  check(m.txFrames.length, lessThan(2));
  await _waitFor(
    b,
    () async => await b.read(R.status) & 0x1 == 0,
    'tx stops',
    polls: 4000,
  );
  check(m.txFrames, hasLength(2), reason: 'TX stopped after the wire');
  check(b.top.output('mii_tx_en').value.toBool(), isFalse);

  // RX: rx_en goes low inside a frame.
  await b.write(R.ctrl, 0x12);
  final wire = ethWireFrame(_frame(r, 400));
  final sent = m.sendFrame(wire);
  await _waitFor(b, () async => b.busy('eth_mac_rx'), 'rx frame starts');
  await b.write(R.ctrl, 0x10);
  check(await b.read(R.status) & 0x2, 0x2, reason: 'rx_running');
  await _waitFor(
    b,
    () async => await b.read(R.status) & 0x2 == 0,
    'rx stops',
    polls: 4000,
  );
  check(b.busy('eth_mac_rx'), isFalse);
  check(await b.read(R.rxFrames), 1, reason: 'the frame ended first');
  await sent;
  await b.finish();
}

/// rx_running stays high until the RX MAC no longer sees rx_en. At 10 Mbps
/// that is more than 1 us after the CTRL write.
Future<void> _rxEnTail() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii10,
    sysPeriod: 20,
    loopback: false,
  );
  final d = EthDriver(b);
  await d.init(ctrl: 0x2);
  await b.cycles(200);
  await b.write(R.ctrl, 0);
  check(await b.read(R.status) & 0x2, 0x2, reason: 'RX MAC sees rx_en');
  await _waitFor(
    b,
    () async => await b.read(R.status) & 0x2 == 0,
    'rx stops',
    polls: 4000,
  );
  await b.finish();
}

Future<void> _ringMove() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    sysPeriod: 20,
    loopback: false,
    latency: EthWaistMem.dramLatency,
  );
  final m = b.phy! as EthMiiModel;
  final d = EthDriver(b);
  await d.init(ctrl: 0x1 | 0x10);
  final f = _frame(Random(5), 1514);
  d.send(f, pieces: 3);
  await d.kickTx();
  await _waitFor(b, () async => b.busy('eth_dma_tx'), 'tx dma busy');
  // The new ring base must not reach the frame in flight.
  const newRing = 0x3000;
  await b.write(R.txRingLo, newRing);
  final done = <EthTxDone>[];
  await _waitFor(
    b,
    () async {
      done.addAll(d.reclaimTx());
      return done.length == 3;
    },
    'write-backs in the old ring',
    polls: 4000,
  );
  for (final t in done) {
    check(t.word3, 1, reason: 'desc ${t.index} done, no error');
  }
  check(
    b.mem.bytes.keys.where((a) => a >= newRing && a < newRing + 0x100),
    isEmpty,
    reason: 'nothing written in the new ring',
  );
  await _waitFor(b, () async => m.txFrames.isNotEmpty, 'wire', polls: 4000);
  check(m.txFrames.single.bytes, ethWireFrame(f));
  check(await b.read(R.txHead), 0);
  check(await b.read(R.txTail), 0);
  check(await b.read(R.txRingLo), newRing);
  check(b.mem.errors, isEmpty);
  await b.finish();
}

Future<void> _softResetBusy() async {
  final b = await EthMacBench.start(
    config: _basic(HarborEthPhy.mii),
    link: EthLink.mii100,
    sysPeriod: 20,
    latency: EthWaistMem.dramLatency,
  );
  final m = b.phy! as EthMiiModel;
  final d = EthDriver(b);
  await d.init(ctrl: 0x3 | 0x10);
  final r = Random(11);
  for (var i = 0; i < 6; i++) {
    d.send(_frame(r, 1514));
  }
  await d.kickTx();
  var both = false;
  for (var i = 0; i < 200000 && !both; i++) {
    await b.clk.nextPosedge;
    both = b.busy('eth_dma_tx') && b.busy('eth_dma_rx');
  }
  check(both, isTrue, reason: 'both DMAs busy');
  await b.write(R.ctrl, 0x80 | 0x13);
  await _waitFor(
    b,
    () async => await b.read(R.ctrl) & 0x80 == 0,
    'soft reset ends',
  );
  await b.cycles(100);
  check(b.mem.errors, isEmpty);
  check(b.mem.idle, isTrue, reason: 'no open bus access');
  check(await b.read(R.txHead), 0);
  check(await b.read(R.rxHead), 0);
  // Let frames that were on the wire end, then start again.
  await b.cycles(8000);
  final d2 = EthDriver(b, txRing: 0x5000, rxRing: 0x6000, rxBufs: 0x80000);
  await d2.init(ctrl: 0x3 | 0x10);
  final frames = [_frame(r, 60), _frame(r, 1514), _frame(r, 64)];
  for (final f in frames) {
    d2.send(f);
  }
  await d2.kickTx();
  final got = <EthRxDone>[];
  await _waitFor(
    b,
    () async {
      got.addAll(d2.pollRx());
      return got.length >= frames.length;
    },
    'frames after the reset',
    polls: 4000,
  );
  for (var i = 0; i < frames.length; i++) {
    check(got[i].data, frames[i], reason: 'frame $i after the reset');
    check(got[i].err, 0);
  }
  check(m.txFrames.length, greaterThanOrEqualTo(frames.length));
  check(b.mem.errors, isEmpty);
  await b.finish();
}

void _iso(String name, Future<void> Function() body) =>
    test(name, () => Isolate.run(body));

void main() {
  for (final p in HarborEthPhy.values) {
    for (final full in [false, true]) {
      final tag = '${p.name} ${full ? 'full' : 'basic'}';
      _iso('reset values and HW_CAPS, $tag', () {
        return _resetValues(full ? _full(p) : _basic(p));
      });
    }
  }
  _iso('masks and options off read 0, mii basic', () {
    return _masks(_basic(HarborEthPhy.mii), 32);
  });
  _iso('masks, rgmii full, 40-bit DMA', () {
    return _masks(_full(HarborEthPhy.rgmii), 40);
  });
  _iso('masks, clause 45 and a 24-bit DMA', () {
    return _masks(
      HarborEthernetConfig(phy: HarborEthPhy.rmii, mdioC45: true),
      24,
    );
  });
  _iso('a write changes only the selected bytes', _byteLanes);
  for (final kind in HarborFabricKind.values) {
    _iso('register port on ${kind.name}', () => _fabric(kind));
  }
  _iso('MDIO clause 22 through the registers', () => _mdio(false));
  _iso('MDIO clause 45 through the registers', () => _mdio(true));
  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.axi4]) {
    _iso(
      'a TX bus error sets the sticky bit and the ring recovers, ${kind.name}',
      () => _txRingErr(kind),
    );
    _iso(
      'RX missed and an RX bus error, then the ring recovers, ${kind.name}',
      () => _rxErrors(kind),
    );
  }
  _iso('clock loss: STATUS bits and TX err 4', _clockLoss);
  _iso('soft reset', _softReset);
  _iso('soft reset while both DMAs are busy', _softResetBusy);
  _iso('STATUS running covers the FIFO and the MACs', _running);
  _iso('rx_running waits for rx_en on the RX clock', _rxEnTail);
  _iso('a ring base write waits for the frame in flight', _ringMove);

  group('top', () {
    tearDown(Simulator.reset);

    HarborEthernetMac mac(
      HarborEthernetConfig c, {
      HarborFabricKind kind = HarborFabricKind.wishbone,
      HarborDeviceTarget target = const HarborSimTarget(),
    }) => HarborEthernetMac(
      baseAddress: 0x40000000,
      config: c,
      fabricKind: kind,
      target: target,
    );

    test('device tree node', () {
      final m = mac(_basic(HarborEthPhy.rmii));
      final dt = m.dtNode;
      expect(dt.compatible, ['harbor,ethernet-1']);
      expect(dt.reg.start, 0x40000000);
      expect(dt.properties['phy-mode'], 'rmii');
      expect(dt.properties['max-speed'], 100);
      expect(dt.children.single.name, 'mdio');
      expect(
        mac(_full(HarborEthPhy.rgmii)).dtNode.properties['phy-mode'],
        'rgmii-rxid',
      );
      expect(
        mac(
          HarborEthernetConfig(
            phy: HarborEthPhy.rgmii,
            txClockShift: false,
            rgmiiPhyRxDelay: true,
          ),
        ).dtNode.properties['phy-mode'],
        'rgmii-id',
      );
    });

    test('pins follow the front end', () {
      final mii = mac(_basic(HarborEthPhy.mii));
      expect(mii.output('mii_txd').width, 4);
      expect(mii.inputs.keys, containsAll(['mii_tx_clk', 'mii_col']));
      final rmii = mac(_basic(HarborEthPhy.rmii));
      expect(rmii.output('rmii_txd').width, 2);
      expect(rmii.inputs.keys, isNot(contains('mii_tx_clk')));
      final rgmii = mac(_full(HarborEthPhy.rgmii));
      expect(rgmii.inputs.keys, containsAll(['clk125', 'clk125_90']));
      expect(rgmii.inputs.keys, isNot(contains('clk200')));
      expect(rgmii.constraints(), isNotEmpty);
      expect(mii.constraints(), isNotEmpty);
      final artix = mac(
        HarborEthernetConfig(
          phy: HarborEthPhy.rgmii,
          maxSpeed: HarborEthSpeed.mbps1000,
          rgmiiRxDelayTaps: 8,
        ),
        target: const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          speedGrade: '2',
        ),
      );
      expect(artix.inputs.keys, contains('clk200'));
      for (final m in [mii, rmii, rgmii]) {
        expect(m.outputs.keys, containsAll(['interrupt', 'mdc', 'mdio_oe']));
        expect(m.irq, m.interrupt);
      }
    });

    test('definition names differ per parameter set', () {
      final names = {
        mac(_basic(HarborEthPhy.mii)).definitionName,
        mac(_basic(HarborEthPhy.rmii)).definitionName,
        mac(_full(HarborEthPhy.mii)).definitionName,
        mac(
          _basic(HarborEthPhy.mii),
          kind: HarborFabricKind.axi4,
        ).definitionName,
        mac(
          HarborEthernetConfig(phy: HarborEthPhy.mii, mdioC45: true),
        ).definitionName,
      };
      expect(names, hasLength(5));
    });

    test('a DMA address width out of range throws', () {
      expect(
        () => HarborEthernetMac(
          baseAddress: 0,
          config: _basic(HarborEthPhy.mii),
          fabricKind: HarborFabricKind.wishbone,
          target: const HarborSimTarget(),
          dmaAddressWidth: 8,
        ),
        throwsArgumentError,
      );
    });

    test('a TX DMA too slow for 1000 Mbps throws at build', () async {
      HarborEthernetMac mac(int burst, int hz) => HarborEthernetMac(
        baseAddress: 0,
        config: HarborEthernetConfig(
          phy: HarborEthPhy.rgmii,
          maxSpeed: HarborEthSpeed.mbps1000,
          burstBeats: burst,
        ),
        fabricKind: HarborFabricKind.wishbone,
        target: const HarborSimTarget(),
        clockFrequency: hz,
      );
      // 1 beat each 4 cycles of 100 MHz is 25 M words/s.
      await expectLater(
        mac(1, 100000000).build(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('burstBeats 1'), contains('31.25')),
          ),
        ),
      );
      // 2 beats need 62.5 MHz.
      await expectLater(mac(2, 62000000).build(), throwsStateError);
      HarborEthernetMac.checkDmaRate(
        HarborEthernetConfig(
          phy: HarborEthPhy.rgmii,
          maxSpeed: HarborEthSpeed.mbps1000,
          burstBeats: 2,
        ),
        62500000,
      );
      // 100 Mbps has no limit here.
      HarborEthernetMac.checkDmaRate(
        HarborEthernetConfig(phy: HarborEthPhy.mii, burstBeats: 1),
        10000000,
      );
    });
  });
}
