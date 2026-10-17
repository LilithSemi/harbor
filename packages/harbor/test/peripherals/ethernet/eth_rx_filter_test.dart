import 'dart:async';

import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_rx_filter.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_frames.dart';

const _ownMac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
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

var _running = false;

class _Result {
  final bool keep;
  final bool mcast;
  final bool bcast;
  _Result(this.keep, this.mcast, this.bcast);
}

class _Filter {
  final Logic clk = SimpleClockGenerator(10).clk;
  final Logic reset = Logic();
  final Logic start = Logic();
  final Logic inValid = Logic();
  final Logic inData = Logic(width: 8);
  final Logic crcNext = Logic(width: 32);
  final Logic mac = Logic(width: 48);
  final Logic hash = Logic(width: 64);
  final Logic promisc = Logic();
  late final HarborEthRxFilter dut;

  Future<void> init(HarborEthernetConfig cfg) async {
    dut = HarborEthRxFilter(
      clk,
      reset,
      config: cfg,
      start: start,
      inValid: inValid,
      inData: inData,
      macAddr: mac,
      crcNext: cfg.multicastHash ? crcNext : null,
      mcHash: cfg.multicastHash ? hash : null,
      promisc: cfg.promiscuous ? promisc : null,
    );
    await dut.build();
    reset.inject(1);
    start.inject(0);
    inValid.inject(0);
    inData.inject(0);
    crcNext.inject(0);
    var m = 0;
    for (var i = 0; i < 6; i++) {
      m |= _ownMac[i] << (8 * i);
    }
    mac.inject(m);
    hash.inject(0);
    promisc.inject(0);
    Simulator.setMaxSimTime(100000000);
    unawaited(Simulator.run());
    _running = true;
    await clk.nextPosedge;
    reset.inject(0);
  }

  Future<_Result> check(
    List<int> da, {
    int mcHash = 0,
    bool prom = false,
    int? midHash,
  }) async {
    await clk.nextNegedge;
    hash.put(mcHash);
    promisc.put(prom);
    start.put(1);
    await clk.nextNegedge;
    start.put(0);
    for (var i = 0; i < 6; i++) {
      expect(dut.done.value.toBool(), isFalse);
      inValid.put(1);
      inData.put(da[i]);
      crcNext.put(~ethCrc32(da.sublist(0, i + 1)) & 0xFFFFFFFF);
      await clk.nextNegedge;
      // A gap between bytes, with junk on the data.
      inValid.put(0);
      inData.put(0xFF);
      await clk.nextNegedge;
    }
    expect(dut.done.value.toBool(), isTrue);
    // More bytes do not change the result.
    final r = _Result(
      dut.keep.value.toBool(),
      dut.mcast.value.toBool(),
      dut.bcast.value.toBool(),
    );
    // A new MC_HASH in the frame does not change the decision.
    if (midHash != null) hash.put(midHash);
    for (var i = 0; i < 8; i++) {
      inValid.put(i.isEven ? 1 : 0);
      inData.put(0x00);
      await clk.nextNegedge;
      expect(dut.keep.value.toBool(), r.keep, reason: 'cycle $i');
    }
    inValid.put(0);
    return r;
  }
}

void main() {
  tearDown(() async {
    if (_running) await Simulator.endSimulation();
    _running = false;
    await Simulator.reset();
  });

  final full = HarborEthernetConfig(
    phy: HarborEthPhy.mii,
    multicastHash: true,
    promiscuous: true,
  );
  const other = [0x02, 0x11, 0x22, 0x33, 0x45, 0x55];
  const mc = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x01];

  test('basic keeps own unicast and broadcast', () async {
    final f = _Filter();
    await f.init(HarborEthernetConfig.basic(phy: HarborEthPhy.mii));
    var r = await f.check(_ownMac);
    expect([r.keep, r.mcast, r.bcast], [true, false, false]);
    r = await f.check(other);
    expect(r.keep, isFalse);
    r = await f.check(_bcast);
    expect([r.keep, r.mcast, r.bcast], [true, false, true]);
    r = await f.check(mc);
    expect([r.keep, r.mcast, r.bcast], [false, true, false]);
    // A difference in any one byte drops the frame.
    for (var i = 0; i < 6; i++) {
      final da = [..._ownMac];
      da[i] ^= 0x80;
      expect((await f.check(da)).keep, isFalse, reason: 'byte $i');
    }
  });

  test('each hash bit keeps only its own addresses', () async {
    final f = _Filter();
    await f.init(full);
    // One multicast address for each of the 64 hash bits.
    final byBit = <int, List<int>>{};
    for (var n = 0; byBit.length < 64; n++) {
      final da = [0x01, 0x00, 0x5E, n & 0x7F, (n >> 7) & 0xFF, n & 0xFF];
      byBit.putIfAbsent(_hashIndex(da), () => da);
    }
    for (var bit = 0; bit < 64; bit++) {
      final da = byBit[bit]!;
      expect((await f.check(da, mcHash: 1 << bit)).keep, isTrue);
      final r = await f.check(da, mcHash: ~(1 << bit));
      expect(r.keep, isFalse, reason: 'bit $bit');
      expect(r.mcast, isTrue);
    }
    // Unicast does not use the table.
    expect((await f.check(other, mcHash: -1)).keep, isFalse);
    expect((await f.check(_bcast)).keep, isTrue);
  });

  test('MC_HASH written in a frame keeps the decision', () async {
    final f = _Filter();
    await f.init(full);
    final bit = 1 << _hashIndex(mc);
    expect((await f.check(mc, mcHash: bit, midHash: 0)).keep, isTrue);
    expect((await f.check(mc, mcHash: 0, midHash: bit)).keep, isFalse);
    expect((await f.check(mc, mcHash: bit, midHash: ~bit)).keep, isTrue);
    expect((await f.check(mc, mcHash: ~bit, midHash: -1)).keep, isFalse);
    // The next frame takes the table as it is then.
    expect((await f.check(mc, mcHash: bit)).keep, isTrue);
  });

  test('promisc keeps everything', () async {
    final f = _Filter();
    await f.init(full);
    for (final da in [_ownMac, other, _bcast, mc]) {
      expect((await f.check(da, prom: true)).keep, isTrue);
    }
    expect((await f.check(other)).keep, isFalse);
  });

  test('without the hash option multicast needs promisc', () async {
    final f = _Filter();
    await f.init(
      HarborEthernetConfig(phy: HarborEthPhy.mii, promiscuous: true),
    );
    expect((await f.check(mc)).keep, isFalse);
    expect((await f.check(mc, prom: true)).keep, isTrue);
  });

  test('module names differ per option set', () {
    final names = <String>{};
    for (final h in [false, true]) {
      for (final p in [false, true]) {
        final cfg = HarborEthernetConfig(
          phy: HarborEthPhy.mii,
          multicastHash: h,
          promiscuous: p,
        );
        names.add(
          HarborEthRxFilter(
            Logic(),
            Logic(),
            config: cfg,
            start: Logic(),
            inValid: Logic(),
            inData: Logic(width: 8),
            macAddr: Logic(width: 48),
            crcNext: Logic(width: 32),
            mcHash: Logic(width: 64),
            promisc: Logic(),
          ).definitionName,
        );
      }
    }
    expect(names, hasLength(4));
  });
}
