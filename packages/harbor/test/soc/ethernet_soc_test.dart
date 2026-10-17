// The Linux driver flow on a HarborSoC: a CPU-like master sets up the rings
// in an SRAM, sends frames through the MAC in RGMII PHY loopback, takes the
// interrupt, reads the received frames and stops the MAC for a speed change.

import 'dart:async';
import 'dart:isolate';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/eth_frames.dart';
import '../util/eth_mac_bench.dart' show check;
import '../util/eth_mdio_model.dart';
import '../util/eth_phy_model.dart';
import '../util/reg_bus.dart';

const _sram = 0x80000000;
const _sramSize = 0x1000;
const _eth = 0x30000000;

const _txRing = _sram + 0x000;
const _rxRing = _sram + 0x100;
const _txBufs = _sram + 0x200;
const _rxBufs = _sram + 0x800;
const _txLog = 4;
const _rxLog = 3;
const _rxBufSize = 0x100;

const _own = 1 << 31;
const _sop = 1 << 16;
const _eop = 1 << 17;
const _irq = 1 << 18;

const _mac = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01];
const _mcHit = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x01];
const _mcMiss = [0x33, 0x33, 0x00, 0x00, 0x00, 0x01];
const _other = [0x02, 0x00, 0x00, 0x00, 0x00, 0x99];
const _bcast = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

/// Linux `ether_crc(6, addr) >> 26`, from `bitrev32(crc32_le(~0, addr, 6))`.
int _hashIndex(List<int> addr) {
  final state = ~ethCrc32(addr) & 0xFFFFFFFF;
  var rev = 0;
  for (var i = 0; i < 32; i++) {
    if ((state >> i) & 1 != 0) rev |= 1 << (31 - i);
  }
  return rev >> 26;
}

/// A register master whose native port pins are plain `p_<PORT>` ports.
class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('EthSocCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

const _macIn = [
  'clk125',
  'clk125_90',
  'rgmii_rxc',
  'rgmii_rxd',
  'rgmii_rx_ctl',
  'mdio_in',
];
const _macOut = [
  'rgmii_txc',
  'rgmii_txd',
  'rgmii_tx_ctl',
  'mdc',
  'mdio_out',
  'mdio_oe',
  'interrupt',
];

/// Frames with their destination, the number of TX pieces and if the RX
/// filter keeps them.
final _frames = [
  (_frame(_mac, 60, 1), 1, true),
  (_frame(_bcast, 100, 2), 2, true),
  (_frame(_mcHit, 64, 3), 1, true),
  (_frame(_mcMiss, 64, 4), 1, false),
  (_frame(_other, 64, 5), 1, false),
  (_frame(_mac, 30, 6), 3, true),
];

List<int> _frame(List<int> da, int len, int seed) => [
  ...da,
  ..._mac,
  0x08,
  0x00,
  for (var i = 14; i < len; i++) (i * 7 + seed * 13) & 0xFF,
];

List<int> _padded(List<int> f) => [...f, for (var i = f.length; i < 60; i++) 0];

Future<void> _driverFlow(HarborFabricKind kind) async {
  final soc = HarborSoC(
    name: 'eth_soc_${kind.name}',
    compatible: 'test,eth-soc',
    fabricKind: kind,
    target: const HarborSimTarget(frequency: 100000000),
  );
  final cpu = soc.addMaster(_Cpu(kind));
  final config = HarborEthernetConfig.ax7203();
  final mac = HarborEthernetMac(
    baseAddress: _eth,
    config: config,
    fabricKind: kind,
    target: const HarborSimTarget(),
    busAddressWidth: 32,
  );
  soc.addPeripheral(mac);
  soc.addMaster(
    mac,
    busInterfaceName: 'dma',
    memory: true,
    // A Wishbone fabric port takes one request at a time.
    outstanding: kind == HarborFabricKind.wishbone ? 1 : config.outstanding,
  );
  soc.addPeripheral(
    HarborSram(
      baseAddress: _sram,
      size: _sramSize,
      busAddressWidth: 32,
      protocol: kind,
    ),
  );
  cpu.pullUp(soc);
  for (final p in [..._macIn, ..._macOut]) {
    soc.exposePin(mac, p, externalName: 'eth_$p');
  }
  soc.buildFabric();
  final busError = soc.exposeBusError();

  final clk = SimpleClockGenerator(10).clk;
  final bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
  final phy = EthRgmiiModel()..loopback = true;
  final clk125 = SimpleClockGenerator(8).clk;
  final mdio = EthMdioPhy(
    soc.output('eth_mdc'),
    soc.output('eth_mdio_out'),
    soc.output('eth_mdio_oe'),
    address: 1,
  );
  mdio.c22[2] = 0x0022;
  void drive(String p, Logic src) => soc.input('eth_$p').srcConnection! <= src;
  drive('clk125', clk125);
  drive('clk125_90', ethShiftedClock(clk125, 2, name: 'clk125_90'));
  drive('rgmii_rxc', phy.rxc);
  drive('rgmii_rxd', phy.rxd);
  drive('rgmii_rx_ctl', phy.rxCtl);
  drive('mdio_in', mdio.mdioIn);
  phy.attach(
    soc.output('eth_rgmii_txc'),
    soc.output('eth_rgmii_txd'),
    soc.output('eth_rgmii_tx_ctl'),
  );

  final reset = Logic(name: 'reset')..inject(1);
  soc.input('clk').srcConnection! <= clk;
  soc.input('reset').srcConnection! <= reset;
  await soc.build();
  bus.idle();
  mdio.start();
  Simulator.setMaxSimTime(200000000);
  unawaited(Simulator.run());
  phy.start();
  await ethSimDelay(2000);
  await clk.nextNegedge;
  reset.inject(0);
  await ethSimDelay(2000);
  await clk.nextPosedge;

  Future<int> rd(int off) => bus.read(_eth + off);
  Future<void> wr(int off, int v) => bus.write(_eth + off, v);
  Future<void> idle(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  // Poll with idle cycles between reads, so that a Wishbone CPU does not
  // hold the bus that the DMA needs.
  Future<int> poll(
    Future<int> Function() read,
    bool Function(int) done, {
    int tries = 400,
    String what = '',
  }) async {
    var v = await read();
    for (var i = 0; i < tries && !done(v); i++) {
      await idle(50);
      v = await read();
    }
    check(done(v), isTrue, reason: '$what: ${v.toRadixString(16)}');
    return v;
  }

  Future<void> putBytes(int addr, List<int> bytes) async {
    final start = addr & ~3;
    final end = (addr + bytes.length + 3) & ~3;
    for (var w = start; w < end; w += 4) {
      var v = 0;
      for (var b = 0; b < 4; b++) {
        final i = w + b - addr;
        if (i >= 0 && i < bytes.length) v |= bytes[i] << (8 * b);
      }
      await bus.write(w, v);
    }
  }

  Future<List<int>> getBytes(int addr, int len) async {
    final out = <int>[];
    for (var w = addr; w < addr + len; w += 4) {
      final v = await bus.read(w);
      for (var b = 0; b < 4; b++) {
        out.add((v >> (8 * b)) & 0xFF);
      }
    }
    return out.sublist(0, len);
  }

  // Probe: ID and the capabilities the driver reads.
  check(await rd(HarborEthReg.id), HarborEthReg.idValue);
  final caps = await rd(HarborEthReg.hwCaps);
  check(caps, config.hwCaps);
  final desc = 1 << ((caps >> 12) & 0xF);
  check(desc, 16);

  // Stop and soft reset the MAC.
  await wr(HarborEthReg.ctrl, 0x80);
  await poll(
    () => rd(HarborEthReg.ctrl),
    (v) => v & 0x80 == 0,
    what: 'soft reset',
  );

  // The DMA width shows in the ring base bits that a write of ones keeps.
  await wr(HarborEthReg.txRingLo, 0xFFFFFFFF);
  await wr(HarborEthReg.txRingHi, 0xFFFFFFFF);
  check(await rd(HarborEthReg.txRingLo), 0xFFFFFFF0);
  check(await rd(HarborEthReg.txRingHi), 0);

  // MDIO read of the PHY ID through MDIO_CTRL and MDIO_DATA.
  await wr(HarborEthReg.mdioCtrl, (1 << 12) | (1 << 5) | 2);
  await poll(
    () => rd(HarborEthReg.mdioCtrl),
    (v) => v & 0x3000 == 0,
    tries: 1000,
    what: 'mdio busy',
  );
  check(await rd(HarborEthReg.mdioData) & 0xFFFF, 0x0022);

  // MAC address with rx_en low, and the multicast hash.
  await wr(HarborEthReg.macLo, 0x00000002);
  await wr(HarborEthReg.macHi, 0x0100);
  final bit = _hashIndex(_mcHit);
  check(_hashIndex(_mcMiss), isNot(bit));
  await wr(
    bit < 32 ? HarborEthReg.mcHashLo : HarborEthReg.mcHashHi,
    1 << (bit % 32),
  );

  // RX descriptors, all armed, and the rings. TAIL goes after the ring.
  final rxN = 1 << _rxLog;
  for (var i = 0; i < rxN; i++) {
    final d = _rxRing + desc * i;
    await bus.write(d, _rxBufs + _rxBufSize * i);
    await bus.write(d + 4, 0);
    await bus.write(d + 12, 0);
    await bus.write(d + 8, _own | _rxBufSize);
  }
  final txN = 1 << _txLog;
  for (var i = 0; i < txN; i++) {
    await bus.write(_txRing + desc * i + 8, 0);
  }
  for (final (base, ring, log, tail) in [
    (HarborEthReg.txRingLo, _txRing, _txLog, 0),
    (HarborEthReg.rxRingLo, _rxRing, _rxLog, rxN - 1),
  ]) {
    await wr(base, ring);
    await wr(base + 4, 0);
    await wr(base + 8, log);
    await wr(base + 12, tail);
  }
  check(await rd(HarborEthReg.rxTail), rxN - 1);
  check(await rd(HarborEthReg.rxHead), 0);

  await wr(HarborEthReg.intEnable, 0x1F);
  // tx_en, rx_en, 1000 Mbps, full duplex.
  await wr(HarborEthReg.ctrl, 0x63);
  await idle(100);

  // Send: one descriptor for each piece, IRQ on the last.
  var txi = 0;
  var bufOff = 0;
  for (final (f, pieces, _) in _frames) {
    final cut = [
      0,
      for (var k = 1; k < pieces; k++) f.length * k ~/ pieces,
      f.length,
    ];
    for (var k = 0; k < pieces; k++) {
      final piece = f.sublist(cut[k], cut[k + 1]);
      // Odd buffer addresses, as an skb fragment can have.
      final buf = _txBufs + bufOff + (k & 3);
      bufOff += 0x80;
      await putBytes(buf, piece);
      final d = _txRing + desc * txi;
      await bus.write(d, buf);
      await bus.write(d + 4, 0);
      await bus.write(d + 12, 0);
      await bus.write(
        d + 8,
        _own |
            piece.length |
            (k == 0 ? _sop : 0) |
            (k == pieces - 1 ? _eop | _irq : 0),
      );
      txi++;
    }
  }
  await wr(HarborEthReg.txTail, txi);

  // The interrupt comes for the first done frame.
  final irq = soc.output('eth_interrupt');
  var cyc = 0;
  while (!irq.value.toBool() && cyc < 20000) {
    await clk.nextPosedge;
    cyc++;
  }
  check(irq.value.toBool(), isTrue, reason: 'interrupt');

  // TX reclaim: every descriptor done with no error, OWN clear.
  for (var i = 0; i < txi; i++) {
    final d = _txRing + desc * i;
    await poll(
      () => bus.read(d + 8),
      (v) => v & _own == 0,
      what: 'tx desc $i OWN',
    );
    final w3 = await bus.read(d + 12);
    check(w3 & 1, 1, reason: 'tx $i done');
    check((w3 >> 1) & 7, 0, reason: 'tx $i err');
  }

  // RX: the kept frames in order, the others dropped by the filter.
  final kept = [
    for (final (f, _, keep) in _frames)
      if (keep) f,
  ];
  for (final (i, f) in kept.indexed) {
    final d = _rxRing + desc * i;
    await poll(
      () => bus.read(d + 8),
      (v) => v & _own == 0,
      what: 'rx desc $i OWN',
    );
    final w3 = await bus.read(d + 12);
    final len = w3 & 0xFFFF;
    check((w3 >> 22) & 7, 0, reason: 'rx $i err');
    check((w3 >> 16) & 3, 3, reason: 'rx $i SOP and EOP');
    check(len, _padded(f).length, reason: 'rx $i length');
    check(await getBytes(_rxBufs + _rxBufSize * i, len), _padded(f));
  }
  await idle(2000);
  check(await rd(HarborEthReg.rxHead), kept.length);
  final next = _rxRing + desc * kept.length;
  check(await bus.read(next + 8) & _own, _own, reason: 'no extra frame');

  // Acknowledge: INT_STATUS is write 1 to clear and the line goes low.
  final ints = await rd(HarborEthReg.intStatus);
  check(ints & 0x3, 0x3, reason: 'tx_done and rx_done');
  check(ints & 0x1C, 0, reason: 'no error and no miss');
  await wr(HarborEthReg.intStatus, ints);
  await idle(4);
  check(irq.value.toBool(), isFalse);

  // Counters for ethtool.
  check(await rd(HarborEthReg.txFrames), _frames.length);
  check(await rd(HarborEthReg.rxFrames), kept.length);
  check(await rd(HarborEthReg.rxMissed), 0);
  check(await rd(HarborEthReg.rxOverflow), 0);

  // Speed change: stop TX and RX, wait for both running bits, set speed.
  await wr(HarborEthReg.ctrl, 0x60);
  await poll(
    () => rd(HarborEthReg.status),
    (v) => v & 0x3 == 0,
    what: 'running',
  );
  await wr(HarborEthReg.ctrl, 0x50);
  check(await rd(HarborEthReg.ctrl) & 0xF3, 0x50);
  check(await rd(HarborEthReg.status) & 0xC, 0, reason: 'ring errors');

  check(busError.value.toInt(), 0);
  phy.stop();
  await Simulator.endSimulation();
}

void main() {
  // Each case runs in its own isolate. ROHD keeps a listener for every wire
  // it ever made, so the design of the first case would slow the second.
  for (final kind in [HarborFabricKind.wishbone, HarborFabricKind.axi4]) {
    test(
      '${kind.name}: the driver flow sends and receives in loopback',
      () => Isolate.run(() => _driverFlow(kind)),
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}
