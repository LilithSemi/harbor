/// Bench for the full HarborEthernetMac: a memory behind the DMA port, a
/// PHY model on the pins, an MDIO PHY and a register bus driver.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart' show MemSlaveShell;
import 'eth_mdio_model.dart';
import 'eth_phy_model.dart';
import 'reg_bus.dart';

/// The same as `expect`, for code that runs in its own isolate. There
/// `expect` fails because the isolate has no test.
void check(Object? actual, Object? matcher, {String? reason}) {
  final m = wrapMatcher(matcher);
  final state = {};
  if (m.matches(actual, state)) return;
  final d = StringDescription()
    ..add('Expected: ')
    ..addDescriptionOf(m)
    ..add('\n  Actual: ')
    ..addDescriptionOf(actual);
  final mm = StringDescription();
  m.describeMismatch(actual, mm, state, false);
  if (mm.length > 0) d.add('\n   Which: $mm');
  if (reason != null) d.add('\n$reason');
  throw TestFailure(d.toString());
}

/// The MAC with its `dma` port on a memory slave port of the same kind.
///
/// The memory waist comes up on ports `mem_*`, the register port on `bus`
/// and every other MAC port with its own name.
class EthMacTop extends BridgeModule {
  final HarborEthernetMac mac;

  EthMacTop(this.mac, HarborMemoryWaistConfig memConfig)
    : super('EthMacTop_${mac.definitionName}', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addSubModule(mac);
    final shell = addSubModule(
      MemSlaveShell(memConfig, kind: mac.fabricKind, burstBeats: 16),
    );
    for (final m in [mac, shell]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    connectInterfaces(mac.interface('dma'), shell.interface('bus'));
    pullUpInterface(mac.interface('bus'), newIntfName: 'bus');
    pullUpInterface(shell.interface('mem'), newIntfName: 'mem');
    bool inIntf(String p) => p.startsWith('bus_') || p.startsWith('dma_');
    for (final p in [...mac.inputs.keys, ...mac.outputs.keys]) {
      if (p == 'clk' || p == 'reset' || inIntf(p)) continue;
      pullUpPort(mac.port(p), newPortName: p);
    }
  }
}

class _Rd {
  final int id;
  final int addr;
  final int len;
  final int size;
  final int burst;
  final int readyAt;
  int beat = 0;
  _Rd(this.id, this.addr, this.len, this.size, this.burst, this.readyAt);
  int get beatAddr => burst == 0 ? addr : addr + (beat << size);
}

/// Memory behind the `mem_*` waist ports of an [EthMacTop].
///
/// Each request waits a random latency from [latency]. Responses keep the
/// order of their direction. The READY outputs stall at random with the
/// chance [stall].
class EthWaistMem {
  final BridgeModule top;
  final Logic clk;
  final Random rng;
  final int limit;

  /// Latency of one request in cycles.
  int Function(Random) latency;

  /// Chance that a READY or VALID output stalls for one cycle.
  double stall;

  final Map<int, int> bytes = {};

  /// Byte ranges [lo, hi) that answer reads with an error.
  final List<(int, int)> readErr = [];

  /// Byte ranges [lo, hi) that answer writes with an error.
  final List<(int, int)> writeErr = [];

  /// Protocol errors the model saw.
  final List<String> errors = [];

  int reads = 0;
  int writes = 0;
  int maxInflight = 0;

  final Queue<_Rd> _rq = Queue();
  final Queue<_Rd> _wq = Queue();
  final Queue<(int, bool, int)> _bq = Queue();
  int _inflight = 0;
  int _now = 0;
  bool _reqReady = false;
  bool _wReady = false;
  bool _rValid = false;
  bool _bValid = false;
  final Map<String, Logic> _drv = {};

  EthWaistMem(
    this.top,
    this.clk,
    this.rng, {
    required this.limit,
    int Function(Random)? latency,
    this.stall = 0,
  }) : latency = latency ?? ((_) => 0) {
    for (final n in [
      'REQ_READY',
      'WDATA_READY',
      'RDATA_VALID',
      'RDATA_ID',
      'RDATA_DATA',
      'RDATA_ERR',
      'RDATA_LAST',
      'RDATA_EXOKAY',
      'WRESP_VALID',
      'WRESP_ID',
      'WRESP_ERR',
      'WRESP_EXOKAY',
    ]) {
      final p = top.input('mem_$n');
      final l = Logic(name: 'drv_mem_$n', width: p.width);
      p.srcConnection! <= l;
      _drv[n] = l;
    }
  }

  /// A latency that is mostly short with some long DRAM-like waits.
  static int dramLatency(Random r) =>
      r.nextDouble() < 0.1 ? 20 + r.nextInt(50) : r.nextInt(4);

  void start() {
    for (final e in _drv.entries) {
      e.value.inject(0);
      _last[e.key] = 0;
    }
    clk.posedge.listen((_) => _rise());
    clk.negedge.listen((_) => _fall());
  }

  /// No request, data or response is open.
  bool get idle =>
      _rq.isEmpty && _wq.isEmpty && _bq.isEmpty && !_rValid && !_bValid;

  int byte(int a) => bytes[a] ?? 0;

  int word(int a) =>
      byte(a) | byte(a + 1) << 8 | byte(a + 2) << 16 | byte(a + 3) << 24;

  void putWord(int a, int v) {
    for (var i = 0; i < 4; i++) {
      bytes[a + i] = (v >> (8 * i)) & 0xff;
    }
  }

  void putBytes(int a, List<int> data) {
    for (var i = 0; i < data.length; i++) {
      bytes[a + i] = data[i];
    }
  }

  List<int> getBytes(int a, int n) => [for (var i = 0; i < n; i++) byte(a + i)];

  bool _in(List<(int, int)> rs, int a) => rs.any((r) => a >= r.$1 && a < r.$2);

  int _p(String n) {
    final v = top.output('mem_$n').previousValue;
    if (v == null || !v.isValid) return 0;
    return v.toBigInt().toInt();
  }

  bool get _go => rng.nextDouble() >= stall;

  void _rise() {
    _now++;
    if (_rValid && _p('RDATA_READY') == 1) {
      _rValid = false;
      final r = _rq.first;
      r.beat++;
      if (r.beat > r.len) {
        _rq.removeFirst();
        _inflight--;
      }
    }
    if (_bValid && _p('WRESP_READY') == 1) {
      _bValid = false;
      _bq.removeFirst();
      _inflight--;
    }
    if (_wReady && _p('WDATA_VALID') == 1) {
      if (_wq.isEmpty) {
        errors.add('write data with no request');
      } else {
        final w = _wq.first;
        final a = w.beatAddr & ~3;
        final strb = _p('WDATA_STRB');
        final data = _p('WDATA_DATA');
        if ((_p('WDATA_LAST') == 1) != (w.beat == w.len)) {
          errors.add('WDATA_LAST wrong at 0x${a.toRadixString(16)}');
        }
        if (!_in(writeErr, a)) {
          for (var i = 0; i < 4; i++) {
            if (strb & (1 << i) != 0) bytes[a + i] = (data >> (8 * i)) & 0xff;
          }
        }
        w.beat++;
        if (w.beat > w.len) {
          _wq.removeFirst();
          final err = [
            for (var k = 0; k <= w.len; k++)
              w.burst == 0 ? w.addr : w.addr + (k << w.size),
          ].any((x) => _in(writeErr, x & ~3));
          _bq.add((w.id, err, _now + latency(rng)));
        }
      }
    }
    if (_reqReady && _p('REQ_VALID') == 1) {
      final r = _Rd(
        _p('REQ_ID'),
        _p('REQ_ADDR'),
        _p('REQ_LEN'),
        _p('REQ_SIZE'),
        _p('REQ_BURST'),
        _now + latency(rng),
      );
      if (r.burst == 2) errors.add('WRAP burst');
      _inflight++;
      maxInflight = max(maxInflight, _inflight);
      if (_p('REQ_WRITE') == 1) {
        writes++;
        _wq.add(r);
      } else {
        reads++;
        _rq.add(r);
      }
    }
  }

  final Map<String, int> _last = {};

  // Only a change is injected. An inject adds a delta tick, and each tick
  // costs time for every wire of the design.
  void _set(String n, int v) {
    if (_last[n] == v) return;
    _last[n] = v;
    _drv[n]!.inject(v);
  }

  void _fall() {
    _reqReady = _inflight < limit && _go;
    _set('REQ_READY', _reqReady ? 1 : 0);
    _wReady = _wq.isNotEmpty && _go;
    _set('WDATA_READY', _wReady ? 1 : 0);
    if (!_rValid && _rq.isNotEmpty && _rq.first.readyAt <= _now && _go) {
      final r = _rq.first;
      final a = r.beatAddr & ~3;
      final err = _in(readErr, a);
      _rValid = true;
      _set('RDATA_ID', r.id);
      _set('RDATA_DATA', err ? 0 : word(a));
      _set('RDATA_ERR', err ? 1 : 0);
      _set('RDATA_EXOKAY', 0);
      _set('RDATA_LAST', r.beat == r.len ? 1 : 0);
    }
    _set('RDATA_VALID', _rValid ? 1 : 0);
    if (!_bValid && _bq.isNotEmpty && _bq.first.$3 <= _now && _go) {
      _bValid = true;
      _set('WRESP_ID', _bq.first.$1);
      _set('WRESP_ERR', _bq.first.$2 ? 1 : 0);
      _set('WRESP_EXOKAY', 0);
    }
    _set('WRESP_VALID', _bValid ? 1 : 0);
  }
}

/// Link of a bench: the front end and the speed.
enum EthLink {
  mii10(HarborEthPhy.mii, 10),
  mii100(HarborEthPhy.mii, 100),
  rmii10(HarborEthPhy.rmii, 10),
  rmii100(HarborEthPhy.rmii, 100),
  rgmii10(HarborEthPhy.rgmii, 10),
  rgmii100(HarborEthPhy.rgmii, 100),
  rgmii1000(HarborEthPhy.rgmii, 1000);

  final HarborEthPhy phy;
  final int mbps;
  const EthLink(this.phy, this.mbps);

  /// CTRL speed code.
  int get speedCode => switch (mbps) {
    1000 => 2,
    100 => 1,
    _ => 0,
  };
}

/// A clock the test can stop. One time unit is 1 ns.
class EthStopClock {
  final Logic clk;
  bool running = true;

  EthStopClock(String name, int period) : clk = Logic(name: name) {
    clk.inject(0);
    final half = period ~/ 2;
    void step() {
      if (Simulator.simulationHasEnded) return;
      if (running) clk.put(clk.value.toBool() ? 0 : 1);
      Simulator.registerAction(Simulator.time + half, step);
    }

    Simulator.registerAction(half, step);
  }
}

/// The full MAC with a memory, a PHY and an MDIO PHY.
class EthMacBench {
  final EthMacTop top;
  final HarborEthernetConfig config;
  final EthLink link;
  final Logic clk;
  final RegBus bus;
  final EthWaistMem mem;
  final EthMdioPhy mdio;

  /// The PHY model, or null with [stopClocks].
  final EthPhyModel? phy;

  /// The MII clocks with [stopClocks].
  final EthStopClock? txClock;
  final EthStopClock? rxClock;

  EthMacBench._(
    this.top,
    this.config,
    this.link,
    this.clk,
    this.bus,
    this.mem,
    this.mdio,
    this.phy,
    this.txClock,
    this.rxClock,
  );

  /// Builds and starts a bench. With [stopClocks] the link must be MII, and
  /// the MII clocks are [EthStopClock]s with no PHY model.
  static Future<EthMacBench> start({
    required HarborEthernetConfig config,
    required EthLink link,
    HarborFabricKind kind = HarborFabricKind.wishbone,
    int sysPeriod = 10,
    int dmaAddressWidth = 32,
    int seed = 1,
    int Function(Random)? latency,
    double stall = 0,
    bool loopback = true,
    bool stopClocks = false,
  }) async {
    if (config.phy != link.phy) {
      throw ArgumentError('config phy ${config.phy} is not ${link.phy}');
    }
    final mac = HarborEthernetMac(
      baseAddress: 0x10000000,
      config: config,
      fabricKind: kind,
      target: const HarborSimTarget(),
      dmaAddressWidth: dmaAddressWidth,
    );
    final memConfig = HarborMemoryWaistConfig(
      addressWidth: dmaAddressWidth,
      dataWidth: 32,
      idWidth: 2,
      outstanding: 8,
    );
    final top = EthMacTop(mac, memConfig);
    final clk = SimpleClockGenerator(sysPeriod).clk;
    final reset = Logic(name: 'reset');
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;
    final bus = RegBus.attach(top, clk);
    final rng = Random(seed);
    final mem = EthWaistMem(
      top,
      clk,
      rng,
      limit: memConfig.outstanding,
      latency: latency,
      stall: stall,
    );
    final mdio = EthMdioPhy(
      top.output('mdc'),
      top.output('mdio_out'),
      top.output('mdio_oe'),
    );
    top.input('mdio_in').srcConnection! <= mdio.mdioIn;

    void drive(String port, Logic src) => top.input(port).srcConnection! <= src;

    EthPhyModel? phy;
    EthStopClock? txc;
    EthStopClock? rxc;
    switch (link.phy) {
      case HarborEthPhy.mii:
        if (stopClocks) {
          final period = link.mbps == 10 ? 400 : 40;
          txc = EthStopClock('mii_tx_clk', period);
          rxc = EthStopClock('mii_rx_clk', period);
          drive('mii_tx_clk', txc.clk);
          drive('mii_rx_clk', rxc.clk);
          for (final p in ['mii_rxd', 'mii_rx_dv', 'mii_rx_er']) {
            drive(p, Const(0, width: top.input(p).width));
          }
          drive('mii_crs', Const(0));
          drive('mii_col', Const(0));
        } else {
          final m = EthMiiModel(fast: link.mbps == 100);
          drive('mii_tx_clk', m.txClk);
          drive('mii_rx_clk', m.rxClk);
          drive('mii_rxd', m.rxd);
          drive('mii_rx_dv', m.rxDv);
          drive('mii_rx_er', m.rxEr);
          drive('mii_crs', m.crs);
          drive('mii_col', m.col);
          m.attach(
            top.output('mii_txd'),
            top.output('mii_tx_en'),
            top.output('mii_tx_er'),
          );
          phy = m;
        }
      case HarborEthPhy.rmii:
        final m = EthRmiiModel(fast: link.mbps == 100);
        drive('rmii_ref_clk', m.refClk);
        drive('rmii_rxd', m.rxd);
        drive('rmii_crs_dv', m.crsDv);
        drive('rmii_rx_er', m.rxEr);
        m.attach(top.output('rmii_txd'), top.output('rmii_tx_en'));
        phy = m;
      case HarborEthPhy.rgmii:
        final m = EthRgmiiModel(
          mbps: link.mbps,
          txSampleDelay: config.txClockShift ? 0 : 2,
        );
        final clk125 = SimpleClockGenerator(8).clk;
        drive('clk125', clk125);
        // With no TX clock shift the front end does not use clk125_90.
        drive(
          'clk125_90',
          config.txClockShift
              ? ethShiftedClock(clk125, 2, name: 'clk125_90')
              : clk125,
        );
        drive('rgmii_rxc', m.rxc);
        drive('rgmii_rxd', m.rxd);
        drive('rgmii_rx_ctl', m.rxCtl);
        m.attach(
          top.output('rgmii_txc'),
          top.output('rgmii_txd'),
          top.output('rgmii_tx_ctl'),
        );
        phy = m;
    }
    phy?.loopback = loopback;

    await top.build();
    bus.idle();
    mem.start();
    mdio.start();
    reset.inject(1);
    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    phy?.start();
    // The slowest PHY clock is 400 ns. Its domain needs edges in reset.
    await ethSimDelay(2000);
    await clk.nextNegedge;
    reset.inject(0);
    await ethSimDelay(2000);
    await clk.nextPosedge;
    return EthMacBench._(top, config, link, clk, bus, mem, mdio, phy, txc, rxc);
  }

  // RegBus starts an access just after a rising edge of [clk]. A caller
  // that waited on a PHY clock can be at the time of that edge, before it.
  Future<void> write(int off, int v, {int? sel}) async {
    await clk.nextPosedge;
    await bus.write(off, v, sel: sel);
  }

  Future<int> read(int off) async {
    await clk.nextPosedge;
    return bus.read(off);
  }

  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  bool get irq => top.output('interrupt').value.toBool();

  /// The `busy` output of the MAC submodule [name], such as `eth_dma_tx`.
  bool busy(String name) => top.mac.subModules
      .firstWhere((m) => m.name == name)
      .output('busy')
      .value
      .toBool();

  Future<void> finish() async {
    phy?.stop();
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

/// One RX write-back the driver took.
class EthRxDone {
  final int index;
  final int word3;
  final List<int> data;
  EthRxDone(this.index, this.word3, this.data);
  int get length => word3 & 0xffff;
  int get err => (word3 >> 22) & 7;
}

/// One TX descriptor the driver took back.
class EthTxDone {
  final int index;
  final int word2;
  final int word3;
  EthTxDone(this.index, this.word2, this.word3);
  int get err => (word3 >> 1) & 7;
}

/// A driver that keeps the TX and RX rings in [EthMacBench.mem].
class EthDriver {
  final EthMacBench b;
  final Random rng;
  final int txRing;
  final int rxRing;
  final int txBufs;
  final int rxBufs;
  final int txLog;
  final int rxLog;

  /// RX buffer size.
  final int rxBufSize;

  int txGiven = 0;
  int txDone = 0;
  int rxGiven = 0;
  int rxDone = 0;

  static const own = 1 << 31;
  static const sop = 1 << 16;
  static const eop = 1 << 17;
  static const irqBit = 1 << 18;

  EthDriver(
    this.b, {
    int? seed,
    this.txRing = 0x1000,
    this.rxRing = 0x2000,
    this.txBufs = 0x10000,
    this.rxBufs = 0x40000,
    this.txLog = 4,
    this.rxLog = 4,
    this.rxBufSize = 1536,
  }) : rng = Random(seed ?? 5);

  int get txN => 1 << txLog;
  int get rxN => 1 << rxLog;
  int get _desc => b.config.descBytes;
  int txDesc(int i) => txRing + _desc * (i % txN);
  int rxDesc(int i) => rxRing + _desc * (i % rxN);
  int rxBuf(int i) => rxBufs + 0x800 * (i % rxN);

  /// Writes the rings and the MAC address and gives all RX buffers.
  Future<void> init({
    int mac = 0x000000000002,
    int ctrl = 0,
    bool give = true,
  }) async {
    final m = b.mem;
    for (var i = 0; i < txN; i++) {
      for (var w = 0; w < _desc; w += 4) {
        m.putWord(txDesc(i) + w, 0);
      }
    }
    for (var i = 0; i < rxN; i++) {
      for (var w = 0; w < _desc; w += 4) {
        m.putWord(rxDesc(i) + w, 0);
      }
    }
    await b.write(HarborEthReg.macLo, mac & 0xffffffff);
    await b.write(HarborEthReg.macHi, mac >> 32);
    await b.write(HarborEthReg.txRingLo, txRing);
    await b.write(HarborEthReg.txRingSize, txLog);
    await b.write(HarborEthReg.rxRingLo, rxRing);
    await b.write(HarborEthReg.rxRingSize, rxLog);
    if (give) await giveRx();
    await b.write(HarborEthReg.ctrl, ctrl);
  }

  /// Arms every free RX descriptor and moves RX_TAIL.
  Future<void> giveRx() async {
    var gave = false;
    while (rxGiven - rxDone < rxN - 1) {
      final d = rxDesc(rxGiven);
      b.mem.putWord(d, rxBuf(rxGiven));
      b.mem.putWord(d + 4, 0);
      b.mem.putWord(d + 12, 0);
      b.mem.putWord(d + 8, rxBufSize | own);
      rxGiven++;
      gave = true;
    }
    if (gave) await b.write(HarborEthReg.rxTail, rxGiven % rxN);
  }

  bool canSend(int pieces) => txGiven + pieces - txDone <= txN - 1;

  /// Puts [frame] in [pieces] TX descriptors. Call [kickTx] after.
  void send(List<int> frame, {int pieces = 1, bool irq = true}) {
    final cuts = <int>{0, frame.length};
    while (cuts.length < pieces + 1 && frame.length > cuts.length - 1) {
      cuts.add(1 + rng.nextInt(frame.length - 1));
    }
    final c = cuts.toList()..sort();
    for (var k = 0; k + 1 < c.length; k++) {
      final i = txGiven;
      final buf = txBufs + 0x800 * (i % txN) + rng.nextInt(4);
      final piece = frame.sublist(c[k], c[k + 1]);
      b.mem.putBytes(buf, piece);
      final d = txDesc(i);
      b.mem.putWord(d, buf);
      b.mem.putWord(d + 4, 0);
      b.mem.putWord(d + 12, 0);
      b.mem.putWord(
        d + 8,
        piece.length |
            (k == 0 ? sop : 0) |
            (k + 2 == c.length ? eop : 0) |
            (irq ? irqBit : 0) |
            own,
      );
      txGiven++;
    }
  }

  Future<void> kickTx() => b.write(HarborEthReg.txTail, txGiven % txN);

  /// TX descriptors that the MAC gave back, in order.
  List<EthTxDone> reclaimTx() {
    final out = <EthTxDone>[];
    while (txDone < txGiven) {
      final d = txDesc(txDone);
      final w2 = b.mem.word(d + 8);
      if (w2 & own != 0) break;
      out.add(EthTxDone(txDone, w2, b.mem.word(d + 12)));
      txDone++;
    }
    return out;
  }

  /// RX frames that the MAC wrote back, in order. Call [giveRx] after.
  List<EthRxDone> pollRx() {
    final out = <EthRxDone>[];
    while (rxDone < rxGiven) {
      final d = rxDesc(rxDone);
      if (b.mem.word(d + 8) & own != 0) break;
      final w3 = b.mem.word(d + 12);
      final len = w3 & 0xffff;
      out.add(EthRxDone(rxDone, w3, b.mem.getBytes(rxBuf(rxDone), len)));
      rxDone++;
    }
    return out;
  }
}
