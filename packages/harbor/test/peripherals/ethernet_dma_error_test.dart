import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import '../util/reg_bus.dart';

// Register byte offsets, matching ethernet_test.dart.
const _intStatus = 0x20;
const _rxCtrl = 0x60;
const _rxDescBase = 0x70;
const _txCtrl = 0x40;
const _txDescBase = 0x50;

const _dmaConfig = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  idWidth: 1,
  outstanding: 1,
);

/// A one-outstanding memory slave that answers every request with ERR set:
/// data 0 on a read, a bad write response on a write. Used in place of
/// [BeatMemory] (see test/util/mem_target.dart), which can never raise ERR,
/// to prove the DMA engine latches the sticky status bit and still finishes
/// instead of hanging.
class _AlwaysErrSlave extends BridgeModule {
  _AlwaysErrSlave(HarborFabricKind kind, HarborMemoryWaistConfig config)
    : super('EthDmaAlwaysErrSlave_${kind.name}', name: 'err_slave') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final clk = input('clk');
    final reset = input('reset');
    final port = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: clk,
      reset: reset,
    );
    final w = port.waist;

    final busy = Logic(name: 'busy');
    final isWrite = Logic(name: 'is_write');
    final gotData = Logic(name: 'got_data');

    w.reqReady <= ~busy;
    final reqFire = w.reqValid & w.reqReady;
    w.wdataReady <= (busy & isWrite & ~gotData);
    final wdataFire = w.wdataValid & w.wdataReady;
    w.rdataValid <= (busy & ~isWrite);
    w.rdataId <= Const(0, width: config.idWidth);
    w.rdataData <= Const(0, width: config.dataWidth);
    w.rdataErr <= Const(1);
    w.rdataExOkay <= Const(0);
    w.rdataLast <= Const(1);
    final rdataFire = w.rdataValid & w.rdataReady;
    w.wrespValid <= (busy & isWrite & gotData);
    w.wrespId <= Const(0, width: config.idWidth);
    w.wrespErr <= Const(1);
    w.wrespExOkay <= Const(0);
    final wrespFire = w.wrespValid & w.wrespReady;

    Sequential(clk, [
      If(
        reset,
        then: [busy < Const(0), isWrite < Const(0), gotData < Const(0)],
        orElse: [
          If(
            reqFire,
            then: [busy < Const(1), isWrite < w.reqWrite, gotData < Const(0)],
          ),
          If(wdataFire, then: [gotData < Const(1)]),
          If(rdataFire | wrespFire, then: [busy < Const(0)]),
        ],
      ),
    ]);
  }
}

/// Wraps a [HarborEthernetMac] whose `dma` master port always sees an error
/// response, with every other interface and port pulled up by its own name.
class _ErrTop extends BridgeModule {
  late final HarborEthernetMac eth;

  _ErrTop(HarborFabricKind kind)
    : super('EthDmaErrTop_${kind.name}', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    eth = HarborEthernetMac(
      config: const HarborEthernetConfig(
        maxSpeed: HarborEthernetSpeed.speed100,
      ),
      baseAddress: 0x40000000,
      fabricKind: kind,
    );
    addSubModule(eth);
    final slave = addSubModule(_AlwaysErrSlave(kind, _dmaConfig));
    for (final m in [eth, slave]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    connectInterfaces(eth.interface('dma'), slave.interface('bus'));
    pullUpInterface(eth.interface('bus'), newIntfName: 'bus');
    for (final p in [...eth.inputs.keys, ...eth.outputs.keys]) {
      if (p == 'clk' ||
          p == 'reset' ||
          p.startsWith('bus_') ||
          p.startsWith('dma_')) {
        continue;
      }
      pullUpPort(eth.port(p), newPortName: p);
    }
  }
}

/// An [HarborEthernetMac] on its own, with the `dma` Wishbone master
/// answered from Dart at each falling edge. [respond] gives the error flag
/// and the read data for a beat. Every beat goes into [log] as
/// (write, byte address, data).
class _DartSlaveBench {
  final HarborEthernetMac eth;
  final Logic clk = SimpleClockGenerator(10).clk;
  final Logic reset = Logic(name: 'reset');
  final Logic rxDv = Logic(name: 'rx_dv_sig');
  final Logic rxd;
  final Logic _ack = Logic(name: 'tb_ack');
  final Logic _err = Logic(name: 'tb_err');
  final Logic _rdata = Logic(name: 'tb_rdata', width: 32);
  final (bool, int) Function(bool write, int addr) respond;
  final List<(bool, int, int)> log = [];
  final Map<String, Logic> _bus = {};
  bool txEnSeen = false;

  /// TXD nibbles sent while TX_EN is high.
  final List<int> txNibbles = [];

  _DartSlaveBench(this.respond)
    : eth = HarborEthernetMac(
        config: const HarborEthernetConfig(
          maxSpeed: HarborEthernetSpeed.speed100,
        ),
        baseAddress: 0x40000000,
      ),
      rxd = Logic(name: 'rxd_sig', width: 4) {
    eth.input('clk').srcConnection! <= clk;
    eth.input('reset').srcConnection! <= reset;
    eth.input('mdio_in').srcConnection! <= Const(0);
    eth.input('rx_clk').srcConnection! <= clk;
    eth.input('rx_dv').srcConnection! <= rxDv;
    eth.input('rxd').srcConnection! <= rxd;
    for (final p in eth.inputs.keys.toList()) {
      if (p.startsWith('bus_')) {
        final l = Logic(name: 'tb_$p', width: eth.input(p).width);
        eth.input(p).srcConnection! <= l;
        _bus[p.substring(4)] = l;
      }
    }
    for (final p in eth.inputs.keys.toList()) {
      if (!p.startsWith('dma_')) continue;
      eth.input(p).srcConnection! <=
          switch (p) {
            'dma_ACK' => _ack,
            'dma_ERR' => _err,
            'dma_DAT_MISO' => _rdata,
            _ => Const(0, width: eth.input(p).width),
          };
    }
  }

  Future<void> start() async {
    await eth.build();
    reset.inject(1);
    rxDv.inject(0);
    rxd.inject(0);
    _ack.inject(0);
    _err.inject(0);
    _rdata.inject(0);
    for (final e in _bus.entries) {
      e.value.inject(e.key == 'SEL' ? 0xF : 0);
    }
    clk.negedge.listen((_) => _step());
    clk.posedge.listen((_) {
      if (eth.output('tx_en').value.toBool()) {
        txNibbles.add(eth.output('txd').value.toInt());
      }
    });
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
  }

  void _step() {
    if (eth.output('tx_en').value.toBool()) txEnSeen = true;
    if (_ack.value.toBool() || _err.value.toBool()) {
      _ack.inject(0);
      _err.inject(0);
      return;
    }
    if (!(eth.output('dma_CYC').value.toBool() &&
        eth.output('dma_STB').value.toBool())) {
      return;
    }
    final we = eth.output('dma_WE').value.toBool();
    final addr = eth.output('dma_ADR').value.toInt();
    final (err, data) = respond(we, addr);
    log.add((we, addr, we ? eth.output('dma_DAT_MOSI').value.toInt() : data));
    _rdata.inject(data);
    (err ? _err : _ack).inject(1);
  }

  Future<void> write(int addr, int data) async {
    _bus['ADR']!.inject(addr);
    _bus['DAT_MOSI']!.inject(data);
    _bus['WE']!.inject(1);
    _bus['CYC']!.inject(1);
    _bus['STB']!.inject(1);
    do {
      await clk.nextPosedge;
    } while (!eth.output('bus_ACK').value.toBool());
    _bus['CYC']!.inject(0);
    _bus['STB']!.inject(0);
    _bus['WE']!.inject(0);
    await clk.nextPosedge;
  }

  Future<int> read(int addr) async {
    _bus['ADR']!.inject(addr);
    _bus['WE']!.inject(0);
    _bus['CYC']!.inject(1);
    _bus['STB']!.inject(1);
    do {
      await clk.nextPosedge;
    } while (!eth.output('bus_ACK').value.toBool());
    final v = eth.output('bus_DAT_MISO').value.toInt();
    _bus['CYC']!.inject(0);
    _bus['STB']!.inject(0);
    await clk.nextPosedge;
    return v;
  }

  Future<void> cycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }
}

const _fifoConfig = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  idWidth: 1,
  outstanding: 1,
);

/// Ethernet FCS CRC32 (reflected, 0xEDB88320) of [bytes].
int _ethCrc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final by in bytes) {
    for (var i = 0; i < 8; i++) {
      final x = ((by >> i) & 1) ^ (c & 1);
      c >>= 1;
      if (x != 0) c ^= 0xEDB88320;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// True when the frame in [nibbles] (MII, low nibble first) has a good FCS
/// over the bytes after the SFD.
bool _fcsGood(List<int> nibbles) {
  final bytes = [
    for (var i = 0; i + 1 < nibbles.length; i += 2)
      nibbles[i] | (nibbles[i + 1] << 4),
  ];
  final frame = bytes.sublist(bytes.indexOf(0xD5) + 1);
  final n = frame.length - 4;
  final fcs =
      frame[n] | frame[n + 1] << 8 | frame[n + 2] << 16 | frame[n + 3] << 24;
  return _ethCrc32(frame.sublist(0, n)) == fcs;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    test('an RX DMA fabric error sets the sticky bit and never hangs '
        '(${kind.name})', () async {
      final top = _ErrTop(kind);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final rxdSig = Logic(name: 'rxd_sig', width: top.input('rxd').width);
      final rxDvSig = Logic(name: 'rx_dv_sig');

      top.input('clk').srcConnection! <= clk;
      top.input('reset').srcConnection! <= reset;
      final bus = RegBus.attach(top, clk);
      top.input('mdio_in').srcConnection! <= Const(0);
      top.input('rx_clk').srcConnection! <= clk;
      top.input('rx_dv').srcConnection! <= rxDvSig;
      top.input('rxd').srcConnection! <= rxdSig;

      await top.build();

      reset.inject(1);
      bus.idle();
      rxdSig.inject(0);
      rxDvSig.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      await bus.write(_rxDescBase, 0);
      await bus.write(_rxCtrl, 0x1 | 0x2); // enable + RX DMA enable

      // Preamble + SFD + one payload byte is enough to make the RX engine
      // kick the descriptor DMA, which the always-error slave answers
      // immediately.
      final stream = [...List.filled(15, 0x5), 0xD, 0x1, 0x2];
      for (final n in stream) {
        rxdSig.inject(n);
        rxDvSig.inject(1);
        await clk.nextPosedge;
      }
      rxDvSig.inject(0);
      rxdSig.inject(0);

      var sawErr = false;
      for (var i = 0; i < 200 && !sawErr; i++) {
        final v = await bus.read(_intStatus);
        if (v & 0x10 != 0) sawErr = true;
      }
      expect(sawErr, isTrue);
      await Simulator.endSimulation();
    });
  }

  for (final latency in [0, 20]) {
    test('TX writes the descriptor back when the frame ends during the '
        'last word read (latency $latency)', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(
          maxSpeed: HarborEthernetSpeed.speed100,
        ),
        baseAddress: 0x40000000,
      );
      final top = MasterTop(
        eth,
        iface: 'dma',
        kind: HarborFabricKind.wishbone,
        config: _fifoConfig,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      top.input('clk').srcConnection! <= clk;
      top.input('reset').srcConnection! <= reset;
      final bus = RegBus.attach(top, clk);
      top.input('mdio_in').srcConnection! <= Const(0);
      top.input('rx_clk').srcConnection! <= clk;
      top.input('rx_dv').srcConnection! <= Const(0);
      top.input('rxd').srcConnection! <=
          Const(0, width: top.input('rxd').width);
      // Descriptor at 0: a 5-byte buffer at 0x20.
      final image = [0x20, 5, 0, 0, 0, 0, 0, 0, 0x04030201, 0x05];
      final mem = BeatMemory(
        top,
        clk,
        latency: latency,
        fill: (i) => i < image.length ? image[i] : 0,
      );
      await top.build();
      mem.start();
      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      await bus.write(_txDescBase, 0);
      await bus.write(_txCtrl, 0x1 | 0x4);
      for (var i = 0; i < 3000; i++) {
        await clk.nextPosedge;
      }
      expect(mem.readWord(4), 0, reason: 'descriptor written back');
      expect(mem.log.last.$1, isTrue, reason: 'the write-back is last');
      await Simulator.endSimulation();
    });
  }

  test(
    'a TX descriptor read error ends the descriptor and sends nothing',
    () async {
      // The buffer address read fails with garbage data 0x300.
      final tb = _DartSlaveBench(
        (write, addr) => (!write && addr == 0, addr == 4 ? 5 : 0x300),
      );
      await tb.start();
      await tb.write(_txDescBase, 0);
      await tb.write(_txCtrl, 0x1 | 0x4);
      await tb.cycles(2000);
      expect(tb.log.where((e) => e.$2 >= 0x300), isEmpty);
      expect(tb.log.where((e) => e.$1).map((e) => e.$2), [4]);
      expect(tb.txEnSeen, isFalse);
      expect(
        await tb.read(_intStatus) & 0x12,
        0x12,
        reason: 'TX done, DMA err',
      );
      await Simulator.endSimulation();
    },
  );

  test('an RX descriptor read error drops the frame and writes the length '
      'back', () async {
    final tb = _DartSlaveBench((write, addr) => (!write && addr == 0, 0x300));
    await tb.start();
    await tb.write(_rxDescBase, 0);
    await tb.write(_rxCtrl, 0x1 | 0x2);
    // Preamble, SFD and 8 payload bytes.
    for (final n in [...List.filled(15, 0x5), 0xD, ...List.filled(16, 0xA)]) {
      tb.rxd.inject(n);
      tb.rxDv.inject(1);
      await tb.clk.nextPosedge;
    }
    tb.rxDv.inject(0);
    tb.rxd.inject(0);
    await tb.cycles(500);
    expect(tb.log.where((e) => e.$1).map((e) => e.$2), [4]);
    expect(await tb.read(_intStatus) & 0x18, 0x18, reason: 'RX done, DMA err');
    await Simulator.endSimulation();
  });

  for (final feedErr in [false, true]) {
    test(
      feedErr
          ? 'a TX feed read error sends a bad FCS'
          : 'a TX frame with no error has a good FCS',
      () async {
        // An 8-byte buffer at 0x20. The second word comes from a feed read.
        final tb = _DartSlaveBench(
          (write, addr) => switch (addr) {
            0 => (false, 0x20),
            4 => (false, 8),
            0x20 => (false, 0x13121110),
            0x24 => (feedErr, 0x17161514),
            _ => (false, 0),
          },
        );
        await tb.start();
        await tb.write(_txDescBase, 0);
        await tb.write(_txCtrl, 0x1 | 0x4);
        await tb.cycles(1500);
        expect(tb.txEnSeen, isTrue);
        expect(_fcsGood(tb.txNibbles), !feedErr);
        expect(await tb.read(_intStatus) & 0x10, feedErr ? 0x10 : 0);
        await Simulator.endSimulation();
      },
    );
  }
}
