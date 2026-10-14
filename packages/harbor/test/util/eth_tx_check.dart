import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'mem_target.dart';
import 'reg_bus.dart';

const _intStatus = 0x20;
const _txCtrl = 0x40;
const _txDescBase = 0x50;

/// TX_UNDERRUN status bit (INT_STATUS[5]).
const txUnderrunBit = 0x20;

const _dmaConfig = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  idWidth: 1,
  outstanding: 1,
);

/// Reference Ethernet FCS CRC32 (reflected, 0xEDB88320), matching the
/// hardware.
int ethCrc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final by in bytes) {
    for (var i = 0; i < 8; i++) {
      final x = ((by >> i) & 1) ^ (c & 1);
      c >>= 1;
      if (x != 0) c ^= 0xEDB88320;
    }
  }
  return c & 0xFFFFFFFF;
}

/// What a TX DMA run of [len] payload bytes (0x10, 0x11, ...) at the given
/// fabric [latency] put on the MII.
class TxFrameResult {
  /// The payload this frame was asked to send.
  final List<int> payload;

  /// True when TX_EN stayed high, with no gap, for exactly one preamble
  /// (7 bytes) + SFD (1 byte) + [payload] + a 4-byte FCS. On MII, a gap
  /// here means the frame was read as having ended early.
  final bool continuous;

  /// The bytes between the SFD and the FCS, in the order sent. Only
  /// meaningful when [continuous] is true.
  final List<int> data;

  /// The 4-byte FCS, assembled low byte first. Only meaningful when
  /// [continuous] is true.
  final int fcs;

  /// INT_STATUS after the frame.
  final int status;

  TxFrameResult(
    this.payload,
    this.continuous,
    this.data,
    this.fcs,
    this.status,
  );
}

/// Runs a TX DMA frame of [len] payload bytes (0x10, 0x11, ...) at the given
/// fabric [latency] and [depth] (the default `HarborEthernetConfig` TX
/// prefetch depth unless overridden), and reports what went out on the MII.
Future<TxFrameResult> runTxFrame(int len, int latency, {int? depth}) async {
  final eth = HarborEthernetMac(
    config: HarborEthernetConfig(
      maxSpeed: HarborEthernetSpeed.speed100,
      txPrefetchDepth: depth ?? const HarborEthernetConfig().txPrefetchDepth,
    ),
    baseAddress: 0x40000000,
  );
  final top = MasterTop(
    eth,
    iface: 'dma',
    kind: HarborFabricKind.wishbone,
    config: _dmaConfig,
  );
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  final bus = RegBus.attach(top, clk);
  top.input('mdio_in').srcConnection! <= Const(0);
  top.input('rx_clk').srcConnection! <= clk;
  top.input('rx_dv').srcConnection! <= Const(0);
  top.input('rxd').srcConnection! <= Const(0, width: top.input('rxd').width);

  final payload = [for (var i = 0; i < len; i++) (0x10 + i) & 0xFF];
  final words = <int>[];
  for (var w = 0; w * 4 < len; w++) {
    var word = 0;
    for (var b = 0; b < 4; b++) {
      final idx = w * 4 + b;
      word |= (idx < len ? payload[idx] : 0) << (8 * b);
    }
    words.add(word);
  }
  // Descriptor at word 0: [bufAddr=0x20, len]. Buffer starts at word 8.
  final dmaMem = [0x20, len, 0, 0, 0, 0, 0, 0, ...words];
  final mem = BeatMemory(
    top,
    clk,
    latency: latency,
    fill: (i) => i < dmaMem.length ? dmaMem[i] : 0,
  );
  await top.build();
  mem.start();
  reset.inject(1);
  bus.idle();
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;

  final w = top.output('txd').width;
  final txEnLog = <bool>[];
  final txdLog = <int>[];
  final sub = clk.posedge.listen((_) {
    txEnLog.add(top.output('tx_en').value.toBool());
    txdLog.add(top.output('txd').value.toInt());
  });

  await bus.write(_txDescBase, 0);
  await bus.write(_txCtrl, 0x1 | 0x4); // enable + DMA start

  // A word boundary costs roughly one fetch round trip plus a settle
  // cycle. Give every boundary that much headroom, with margin.
  final boundaries = (len + 3) ~/ 4;
  final budget = 200 + len * 3 + (boundaries + 3) * (latency + 15) * 3;
  for (var i = 0; i < budget; i++) {
    await clk.nextPosedge;
  }
  await sub.cancel();
  final status = await bus.read(_intStatus);

  final perByte = 8 ~/ w;
  // On MII, tx_en low mid-frame reads as the frame having ended: it must
  // stay high, without a gap, from the first preamble nibble to the last
  // FCS nibble. Measure the contiguous high run, not just the nibbles
  // seen while it happened to be high.
  final start = txEnLog.indexOf(true);
  if (start < 0) {
    return TxFrameResult(payload, false, const [], 0, status);
  }
  var end = start;
  while (end < txEnLog.length && txEnLog[end]) {
    end++;
  }
  final wantNibbles = (8 + len + 4) * perByte; // preamble+SFD, payload, FCS
  final continuous = (end - start) == wantNibbles;

  final nibbles = txdLog.sublist(start, end);
  final bytes = <int>[];
  for (var i = 0; i + perByte <= nibbles.length; i += perByte) {
    var b = 0;
    for (var k = 0; k < perByte; k++) {
      b |= nibbles[i + k] << (k * w);
    }
    bytes.add(b);
  }

  await Simulator.endSimulation();

  if (!continuous) return TxFrameResult(payload, false, const [], 0, status);
  final sfd = bytes.indexOf(0xD5);
  if (sfd < 0 || bytes.length < sfd + 1 + len + 4) {
    return TxFrameResult(payload, false, const [], 0, status);
  }
  final afterSfd = bytes.sublist(sfd + 1);
  final data = afterSfd.sublist(0, len);
  final fcsBytes = afterSfd.sublist(len, len + 4);
  final fcs =
      fcsBytes[0] |
      (fcsBytes[1] << 8) |
      (fcsBytes[2] << 16) |
      (fcsBytes[3] << 24);
  return TxFrameResult(payload, true, data, fcs, status);
}

/// Runs a TX DMA frame of [len] bytes at [latency] and checks the exact
/// bytes and FCS seen on the MII, with TX_EN continuous throughout.
Future<void> checkTxFrame(int len, int latency, {int? depth}) async {
  final r = await runTxFrame(len, latency, depth: depth);
  expect(
    r.continuous,
    isTrue,
    reason:
        'tx_en gap: it must stay high with no gap from the first preamble '
        'nibble to the last FCS nibble',
  );
  expect(r.data, equals(r.payload), reason: 'TX payload bytes');
  expect(r.fcs, equals(ethCrc32(r.payload) ^ 0xFFFFFFFF), reason: 'FCS');
}

/// Runs a TX DMA frame of [len] bytes at [latency] expected to outrun the
/// TX prefetch, and checks that TX_EN still never gaps, the FCS is
/// corrupted (not the one a correct frame would carry), and TX_UNDERRUN
/// is reported.
Future<void> checkTxUnderrun(int len, int latency, {int? depth}) async {
  final r = await runTxFrame(len, latency, depth: depth);
  expect(
    r.continuous,
    isTrue,
    reason: 'tx_en must stay high even through an underrun',
  );
  expect(
    r.fcs,
    isNot(equals(ethCrc32(r.data) ^ 0xFFFFFFFF)),
    reason: 'an underrun must corrupt the FCS, not send stale data as good',
  );
  expect(
    r.status & txUnderrunBit,
    equals(txUnderrunBit),
    reason: 'TX_UNDERRUN must be reported',
  );
}
