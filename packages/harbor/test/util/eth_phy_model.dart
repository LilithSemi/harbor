/// PHY models and a core probe for Ethernet front end tests.
library;

import 'dart:async';
import 'dart:collection';

import 'package:rohd/rohd.dart';

import 'eth_frames.dart';

/// A frame the model saw on the transmit pins.
class EthPhyTxFrame {
  /// Bytes from the first preamble byte to the last FCS byte.
  final List<int> bytes;

  /// True when `tx_er` was high at any time in the frame.
  final bool er;

  /// True when the frame had a half byte, or a pair that did not hold.
  final bool malformed;

  /// Indexes in [bytes] of the bytes with `tx_er`, when the model records
  /// them.
  final List<int> erBytes;

  EthPhyTxFrame(
    this.bytes, {
    required this.er,
    required this.malformed,
    this.erBytes = const [],
  });
}

/// Frame bytes as they go on the wire: preamble, SFD, [data] and the FCS.
List<int> ethWireFrame(List<int> data) => [
  ...List.filled(7, 0x55),
  0xD5,
  ...data,
  ...ethFcsBytes(data),
];

/// Common part of the PHY models.
abstract class EthPhyModel {
  /// Frames seen on the transmit pins.
  final List<EthPhyTxFrame> txFrames = [];

  /// When true, the transmit pins feed the receive pins.
  bool loopback = false;

  bool _stop = false;

  /// Starts the monitor. Call after the simulation runs.
  void start() {
    unawaited(_monitor());
  }

  /// Stops the monitor.
  void stop() => _stop = true;

  bool get _running => !_stop;

  Future<void> _monitor();
}

/// MII PHY. The clocks run at 25 MHz for 100 Mbps and 2.5 MHz for 10 Mbps.
/// One simulation time unit is 1 ns.
class EthMiiModel extends EthPhyModel {
  /// Clock period in time units.
  final int period;

  final Logic txClk;
  final Logic rxClk;

  /// Pins into the front end.
  final Logic rxd = Logic(name: 'm_rxd', width: 4);
  final Logic rxDv = Logic(name: 'm_rx_dv');
  final Logic rxEr = Logic(name: 'm_rx_er');
  final Logic crs = Logic(name: 'm_crs');
  final Logic col = Logic(name: 'm_col');

  /// Pins from the front end.
  late final Logic txd;
  late final Logic txEn;
  late final Logic txEr;

  EthMiiModel({required bool fast})
    : period = fast ? 40 : 400,
      txClk = SimpleClockGenerator(fast ? 40 : 400).clk,
      rxClk = SimpleClockGenerator(fast ? 40 : 400).clk {
    rxd.inject(0);
    rxDv.inject(0);
    rxEr.inject(0);
    crs.inject(0);
    col.inject(0);
  }

  /// Connects the front end outputs.
  void attach(Logic txd, Logic txEn, Logic txEr) {
    this.txd = txd;
    this.txEn = txEn;
    this.txEr = txEr;
  }

  @override
  Future<void> _monitor() async {
    final nibbles = <int>[];
    var er = false;
    while (_running) {
      await txClk.nextNegedge;
      if (!txEn.value.isValid) continue;
      if (txEn.value.toBool()) {
        nibbles.add(txd.value.toInt());
        er |= txEr.value.toBool();
      } else if (nibbles.isNotEmpty) {
        txFrames.add(
          EthPhyTxFrame(
            [
              for (var i = 0; i + 1 < nibbles.length; i += 2)
                nibbles[i] | (nibbles[i + 1] << 4),
            ],
            er: er,
            malformed: nibbles.length.isOdd,
          ),
        );
        nibbles.clear();
        er = false;
      }
      if (loopback) {
        rxd.put(txd.value);
        rxDv.put(txEn.value);
        rxEr.put(txEr.value);
        crs.put(txEn.value);
      }
    }
  }

  /// Sends [wire] on the receive pins, with [idleClocks] idle clocks before
  /// and [idleBytes] idle byte times after. [dribble] adds a half byte.
  Future<void> sendFrame(
    List<int> wire, {
    int idleClocks = 8,
    int idleBytes = 14,
    bool dribble = false,
    int? erAtNibble,
    int skipNibbles = 0,
  }) async {
    final pins = <(int, bool, bool)>[
      for (var i = 0; i < idleClocks; i++) (0, false, false),
    ];
    var n = 0;
    for (final b in wire) {
      pins.add((b & 0xF, true, erAtNibble == n++));
      pins.add((b >> 4, true, erAtNibble == n++));
    }
    pins.removeRange(idleClocks, idleClocks + skipNibbles);
    if (dribble) pins.add((0x5, true, false));
    for (var i = 0; i < idleBytes * 2; i++) {
      pins.add((0, false, false));
    }
    for (final (d, v, e) in pins) {
      await rxClk.nextNegedge;
      rxd.put(d);
      rxDv.put(v);
      rxEr.put(e);
      crs.put(v);
    }
  }
}

/// RMII PHY on a 50 MHz reference clock. One simulation time unit is 1 ns.
/// At 10 Mbps each pair on the pins lasts 10 clocks.
class EthRmiiModel extends EthPhyModel {
  /// Clocks for each pair: 1 at 100 Mbps, 10 at 10 Mbps.
  final int repeat;

  final Logic refClk = SimpleClockGenerator(20).clk;

  /// Pins into the front end.
  final Logic rxd = Logic(name: 'r_rxd', width: 2);
  final Logic crsDv = Logic(name: 'r_crs_dv');
  final Logic rxEr = Logic(name: 'r_rx_er');

  /// Pins from the front end.
  late final Logic txd;
  late final Logic txEn;

  EthRmiiModel({required bool fast}) : repeat = fast ? 1 : 10 {
    rxd.inject(0);
    crsDv.inject(0);
    rxEr.inject(0);
  }

  /// Connects the front end outputs.
  void attach(Logic txd, Logic txEn) {
    this.txd = txd;
    this.txEn = txEn;
  }

  @override
  Future<void> _monitor() async {
    final pairs = <int>[];
    var window = <int>[];
    var phase = 0;
    var unstable = false;
    var inFrame = false;
    while (_running) {
      await refClk.nextNegedge;
      if (!txEn.value.isValid) continue;
      final en = txEn.value.toBool();
      if (loopback) {
        rxd.put(txd.value);
        crsDv.put(txEn.value);
      }
      if (!inFrame) {
        if (!en) continue;
        inFrame = true;
        phase = 0;
        window = [];
      }
      if (!en && phase == 0) {
        final bytes = [
          for (var i = 0; i + 3 < pairs.length; i += 4)
            pairs[i] |
                (pairs[i + 1] << 2) |
                (pairs[i + 2] << 4) |
                (pairs[i + 3] << 6),
        ];
        txFrames.add(
          EthPhyTxFrame(
            bytes,
            er: false,
            malformed: pairs.length % 4 != 0 || unstable,
          ),
        );
        pairs.clear();
        unstable = false;
        inFrame = false;
        continue;
      }
      window.add(en ? txd.value.toInt() : -1);
      phase++;
      if (phase == repeat) {
        if (window.any((v) => v != window.first)) unstable = true;
        pairs.add(window.first & 3);
        window = [];
        phase = 0;
      }
    }
  }

  /// Sends [wire] on the receive pins.
  ///
  /// [earlyPairs] pairs of carrier with data 0 go first. The last
  /// [toggleBytes] bytes have `crs_dv` toggling at the nibble rate. [dribble]
  /// adds a half byte. [idleClocks] shifts the pair boundaries. [skipPairs]
  /// removes pairs from the start of the preamble. [erAtPair] puts `rx_er` on
  /// one pair, and at 10 Mbps on one clock of it.
  ///
  /// At 10 Mbps the first and last 2 clocks of each pair show the value of
  /// the previous and the next pair. Only the middle clocks are clean.
  Future<void> sendFrame(
    List<int> wire, {
    int idleClocks = 8,
    int idleBytes = 14,
    int earlyPairs = 0,
    int toggleBytes = 0,
    bool dribble = false,
    int skipPairs = 0,
    int? erAtPair,
  }) async {
    final data = <int>[
      for (final b in wire)
        for (var i = 0; i < 4; i++) (b >> (2 * i)) & 3,
      if (dribble) ...[1, 1],
    ];
    final toggleFrom = data.length - 4 * toggleBytes;
    final pairs = <(int, bool, bool)>[
      for (var i = 0; i < earlyPairs; i++) (0, true, false),
      for (var i = skipPairs; i < data.length; i++)
        (data[i], i < toggleFrom || i.isOdd, erAtPair == i),
    ];
    final idle = (0, false, false);
    final skew = repeat > 1 ? 2 : 0;
    final pins = <(int, bool, bool)>[
      for (var i = 0; i < idleClocks; i++) idle,
      for (var p = 0; p < pairs.length; p++)
        for (var r = 0; r < repeat; r++)
          if (r < skew && p > 0)
            (pairs[p - 1].$1, pairs[p - 1].$2, false)
          else if (r < skew)
            idle
          else if (r >= repeat - skew)
            p + 1 < pairs.length
                ? (pairs[p + 1].$1, pairs[p + 1].$2, false)
                : idle
          else
            (pairs[p].$1, pairs[p].$2, pairs[p].$3 && (repeat == 1 || r == 4)),
      for (var i = 0; i < idleBytes * 4 * repeat; i++) idle,
    ];
    for (final (d, c, e) in pins) {
      await refClk.nextNegedge;
      rxd.put(d);
      crsDv.put(c);
      rxEr.put(e);
    }
  }
}

/// Waits [t] time units.
Future<void> ethSimDelay(int t) {
  final c = Completer<void>();
  Simulator.registerAction(Simulator.time + t, c.complete);
  return c.future;
}

/// A copy of [clk] that changes [delay] time units after it.
Logic ethShiftedClock(Logic clk, int delay, {String name = 'clk_shift'}) {
  final out = Logic(name: name)..inject(0);
  clk.changed.listen((e) {
    final v = e.newValue;
    Simulator.registerAction(Simulator.time + delay, () => out.put(v));
  });
  return out;
}

/// RGMII PHY. One simulation time unit is 1 ns.
///
/// The receive clock runs at 125, 25 or 2.5 MHz from [mbps]. Data and
/// control change a quarter clock before each edge, as a PHY that adds the
/// RX clock delay sends them. The transmit pins are sampled
/// [txSampleDelay] after each `txc` edge. Use 0 when the MAC shifts the TX
/// clock and 2 when the PHY must add the delay.
class EthRgmiiModel extends EthPhyModel {
  /// Link speed in Mbps. Change it only while the link is idle.
  int mbps;

  /// Delay from a `txc` edge to the sample of the transmit pins.
  final int txSampleDelay;

  /// Pins into the front end.
  final Logic rxc = Logic(name: 'g_rxc');
  final Logic rxd = Logic(name: 'g_rxd', width: 4);
  final Logic rxCtl = Logic(name: 'g_rx_ctl');

  /// Pins from the front end.
  late final Logic txc;
  late final Logic txd;
  late final Logic txCtl;

  /// One receive clock: rise data, fall data, rise control, fall control.
  final Queue<(int, int, bool, bool)> _rxQueue = Queue();

  static const _idle = (0, 0, false, false);

  EthRgmiiModel({this.mbps = 1000, this.txSampleDelay = 0}) {
    rxc.inject(0);
    rxd.inject(0);
    rxCtl.inject(0);
  }

  /// Connects the front end outputs.
  void attach(Logic txc, Logic txd, Logic txCtl) {
    this.txc = txc;
    this.txd = txd;
    this.txCtl = txCtl;
  }

  /// Receive clock period in time units.
  int get period => switch (mbps) {
    1000 => 8,
    100 => 40,
    _ => 400,
  };

  @override
  Future<void> _monitor() async {
    unawaited(_rxClock());
    var r = 0;
    var cr = false;
    final bytes = <int>[];
    final nibbles = <int>[];
    final erAt = <int>[];
    var er = false;
    var malformed = false;

    void at(void Function() f) {
      if (txSampleDelay == 0) {
        f();
      } else {
        Simulator.registerAction(Simulator.time + txSampleDelay, f);
      }
    }

    void rise() {
      if (!txd.value.isValid || !txCtl.value.isValid) return;
      r = txd.value.toInt();
      cr = txCtl.value.toBool();
    }

    void fall() {
      if (!_running || !txd.value.isValid || !txCtl.value.isValid) return;
      final f = txd.value.toInt();
      final cf = txCtl.value.toBool();
      if (loopback) _rxQueue.add((r, f, cr, cf));
      final cycleEr = cr ^ cf;
      if (cr) {
        if (mbps == 1000) {
          if (cycleEr) erAt.add(bytes.length);
          bytes.add(r | (f << 4));
        } else {
          if (cycleEr) erAt.add(nibbles.length ~/ 2);
          if (r != f) malformed = true;
          nibbles.add(r);
        }
        er |= cycleEr;
      } else if (bytes.isNotEmpty || nibbles.isNotEmpty) {
        txFrames.add(
          EthPhyTxFrame(
            mbps == 1000
                ? List.of(bytes)
                : [
                    for (var i = 0; i + 1 < nibbles.length; i += 2)
                      nibbles[i] | (nibbles[i + 1] << 4),
                  ],
            er: er,
            malformed: malformed || nibbles.length.isOdd,
            erBytes: erAt.toSet().toList(),
          ),
        );
        bytes.clear();
        nibbles.clear();
        erAt.clear();
        er = false;
        malformed = false;
      }
    }

    txc.posedge.listen((_) => at(rise));
    txc.negedge.listen((_) => at(fall));
  }

  Future<void> _rxClock() async {
    while (_running) {
      final q = period ~/ 4;
      final (r, f, cr, cf) = _rxQueue.isEmpty ? _idle : _rxQueue.removeFirst();
      rxd.put(r);
      rxCtl.put(cr);
      await ethSimDelay(q);
      rxc.put(1);
      await ethSimDelay(q);
      rxd.put(f);
      rxCtl.put(cf);
      await ethSimDelay(q);
      rxc.put(0);
      await ethSimDelay(q);
    }
  }

  /// Sends [wire] on the receive pins, with [idleClocks] idle clocks before
  /// and [idleBytes] idle byte times after. [erAtByte] sets `rx_er` on one
  /// byte. [skipNibbles] removes nibbles from the start of the preamble, at
  /// 10 and 100 Mbps only.
  Future<void> sendFrame(
    List<int> wire, {
    int idleClocks = 8,
    int idleBytes = 14,
    int? erAtByte,
    int skipNibbles = 0,
  }) async {
    final gig = mbps == 1000;
    final syms = <(int, int, bool, bool)>[
      for (var i = 0; i < idleClocks; i++) _idle,
    ];
    final data = <(int, int, bool, bool)>[];
    for (var i = 0; i < wire.length; i++) {
      final b = wire[i];
      final cf = erAtByte != i;
      if (gig) {
        data.add((b & 0xF, b >> 4, true, cf));
      } else {
        data.add((b & 0xF, b & 0xF, true, cf));
        data.add((b >> 4, b >> 4, true, cf));
      }
    }
    syms.addAll(data.skip(skipNibbles));
    for (var i = 0; i < idleBytes * (gig ? 1 : 2); i++) {
      syms.add(_idle);
    }
    _rxQueue.addAll(syms);
    while (_rxQueue.isNotEmpty) {
      await rxc.nextNegedge;
    }
  }
}

/// Drives the MAC transmit input and reads the MAC receive output.
class EthCoreProbe {
  final Logic inValid;
  final Logic inData;
  final Logic inLast;
  final Logic inErr;
  final Logic inReady;
  final Logic outValid;
  final Logic outData;
  final Logic outLast;
  final Logic outStatus;

  /// Frames from the receive output.
  final List<List<int>> rxFrames = [];

  /// Status of each frame in [rxFrames].
  final List<int> rxStatus = [];

  bool _stop = false;

  EthCoreProbe({
    required this.inValid,
    required this.inData,
    required this.inLast,
    required this.inErr,
    required this.inReady,
    required this.outValid,
    required this.outData,
    required this.outLast,
    required this.outStatus,
  }) {
    inValid.inject(0);
    inData.inject(0);
    inLast.inject(0);
    inErr.inject(0);
  }

  /// Stops the loops.
  void stop() => _stop = true;

  /// Gives [frames] to the transmit input, back to back.
  void feed(Logic clk, List<List<int>> frames) {
    unawaited(_feed(clk, frames));
  }

  Future<void> _feed(Logic clk, List<List<int>> frames) async {
    var fi = 0;
    var bi = 0;
    var taken = false;
    while (!_stop) {
      await clk.nextNegedge;
      if (taken) {
        taken = false;
        if (++bi == frames[fi].length) {
          fi++;
          bi = 0;
        }
      }
      if (fi < frames.length) {
        inValid.put(1);
        inData.put(frames[fi][bi]);
        inLast.put(bi == frames[fi].length - 1);
        taken = inReady.value.isValid && inReady.value.toBool();
      } else {
        inValid.put(0);
      }
    }
  }

  /// Collects the receive output frames.
  void collect(Logic clk) {
    unawaited(_collect(clk));
  }

  Future<void> _collect(Logic clk) async {
    var cur = <int>[];
    while (!_stop) {
      await clk.nextNegedge;
      if (!outValid.value.isValid || !outValid.value.toBool()) continue;
      cur.add(outData.value.toInt());
      if (outLast.value.toBool()) {
        rxFrames.add(cur);
        rxStatus.add(outStatus.value.toInt());
        cur = [];
      }
    }
  }

  /// Waits until [done] is true, for at most [clocks] cycles of [clk].
  Future<void> waitFor(Logic clk, bool Function() done, int clocks) async {
    for (var i = 0; i < clocks && !done(); i++) {
      await clk.nextNegedge;
    }
  }
}
