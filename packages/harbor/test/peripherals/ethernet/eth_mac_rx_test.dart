import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_rx.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_frames.dart';

const _ownMac = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];

int _macValue(List<int> mac) {
  var v = 0;
  for (var i = 0; i < 6; i++) {
    v |= mac[i] << (8 * i);
  }
  return v;
}

/// Linux `ether_crc(6, addr) >> 26`.
int _hashIndex(List<int> addr) {
  final state = ~ethCrc32(addr) & 0xFFFFFFFF;
  var rev = 0;
  for (var i = 0; i < 32; i++) {
    if ((state >> i) & 1 != 0) rev |= 1 << (31 - i);
  }
  return rev >> 26;
}

class _Wire {
  /// Frame bytes after the SFD, with the FCS.
  final List<int> bytes;
  final int preamble;
  final int? erAt;
  _Wire(this.bytes, {this.preamble = 7, this.erAt});
}

/// Register side change before slot [_run] index.
class _Event {
  final bool? rxEn;
  final List<int>? mac;
  final int? hash;
  const _Event({this.rxEn, this.mac, this.hash});
}

/// Slot index of the SFD of frame [f] in [_run].
int _sfdSlot(List<_Wire> frames, int f) {
  var slot = 0;
  for (var i = 0; i < f; i++) {
    slot += 12 + frames[i].preamble + 1 + frames[i].bytes.length;
  }
  return slot + 12 + frames[f].preamble;
}

class _Out {
  final List<int> data = [];
  int status = 0;
}

List<int> _withFcs(List<int> data) => [...data, ...ethFcsBytes(data)];

List<int> _payload(Random rand, List<int> da, int len) => [
  ...da,
  ..._ownMac.reversed,
  for (var i = 12; i < len; i++) rand.nextInt(256),
];

Future<List<_Out>> _run(
  List<_Wire> frames, {
  HarborEthernetConfig? config,
  int period = 1,
  int mcHash = 0,
  bool promisc = false,
  bool rxEnFirst = true,
  Map<int, _Event> events = const {},
}) async {
  final cfg = config ?? HarborEthernetConfig.basic(phy: HarborEthPhy.mii);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic();
  final strobe = Logic();
  final data = Logic(width: 8);
  final dv = Logic();
  final er = Logic();
  final mac = Logic(width: 48);
  final hash = Logic(width: 64);
  final prom = Logic();
  final rxEn = Logic();
  final dut = HarborEthMacRx(
    clk,
    reset,
    config: cfg,
    rxStrobe: strobe,
    rxData: data,
    rxDv: dv,
    rxEr: er,
    rxEn: rxEn,
    macAddr: mac,
    mcHash: cfg.multicastHash ? hash : null,
    promisc: cfg.promiscuous ? prom : null,
  );
  await dut.build();

  reset.inject(1);
  strobe.inject(0);
  data.inject(0);
  dv.inject(0);
  er.inject(0);
  mac.inject(_macValue(_ownMac));
  hash.inject(mcHash);
  prom.inject(promisc);
  rxEn.inject(rxEnFirst);
  Simulator.setMaxSimTime(1000000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  // Slots of (data, dv, er), 12 idle slots before each frame.
  final slots = <(int, bool, bool)>[];
  for (final f in frames) {
    for (var i = 0; i < 12; i++) {
      slots.add((0, false, false));
    }
    for (var i = 0; i < f.preamble; i++) {
      slots.add((0x55, true, false));
    }
    slots.add((0xD5, true, false));
    for (var i = 0; i < f.bytes.length; i++) {
      slots.add((f.bytes[i], true, f.erAt == i));
    }
  }
  for (var i = 0; i < 12; i++) {
    slots.add((0, false, false));
  }

  final outs = <_Out>[];
  var cur = _Out();
  var si = 0;
  var cycle = 0;
  var tail = 0;
  while (tail < 8 * period) {
    await clk.nextNegedge;
    if (dut.outValid.value.toBool()) {
      cur.data.add(dut.outData.value.toInt());
      if (dut.outLast.value.toBool()) {
        cur.status = dut.outStatus.value.toInt();
        outs.add(cur);
        cur = _Out();
      } else {
        expect(dut.outStatus.value.toInt(), 0);
      }
    } else {
      expect(dut.outLast.value.toBool(), isFalse);
    }

    final s = cycle % period == 0;
    cycle++;
    strobe.put(s);
    if (s) {
      final ev = events[si];
      if (ev != null) {
        if (ev.rxEn != null) rxEn.put(ev.rxEn);
        if (ev.mac != null) mac.put(_macValue(ev.mac!));
        if (ev.hash != null) hash.put(ev.hash);
      }
      if (si < slots.length) {
        final (d, v, e) = slots[si++];
        data.put(d);
        dv.put(v);
        er.put(e);
      } else {
        tail++;
      }
    } else {
      // Values between strobes are not data.
      data.put(0xA5);
      er.put(1);
    }
  }
  expect(cur.data, isEmpty, reason: 'bytes after the last out_last');
  await Simulator.endSimulation();
  return outs;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborEthMacRx', () {
    test('good frames of 64 to 1522 bytes pass with clean status', () async {
      final rand = Random(3);
      final lens = [60, 61, 100, 333, 1000, 1514, 1517, 1518];
      final datas = [for (final l in lens) _payload(rand, _ownMac, l)];
      final outs = await _run([for (final d in datas) _Wire(_withFcs(d))]);
      expect(outs, hasLength(datas.length));
      for (var i = 0; i < datas.length; i++) {
        expect(outs[i].data, equals(datas[i]), reason: 'len ${lens[i]}');
        expect(outs[i].status, 0, reason: 'len ${lens[i]}');
      }
    });

    test('works with a strobe on every fourth cycle', () async {
      final rand = Random(4);
      final datas = [
        for (final l in [60, 200]) _payload(rand, _ownMac, l),
      ];
      final outs = await _run([
        for (final d in datas) _Wire(_withFcs(d)),
      ], period: 4);
      expect([for (final o in outs) o.data], equals(datas));
      expect([for (final o in outs) o.status], equals([0, 0]));
    });

    test('ARP broadcast vector passes with bcast status', () async {
      final wire = [
        ...ethArpRequest,
        for (var i = 0; i < 4; i++) (ethArpRequestFcs >> (8 * i)) & 0xFF,
      ];
      final outs = await _run([_Wire(wire)]);
      expect(outs, hasLength(1));
      expect(outs[0].data, equals(ethArpRequest));
      expect(outs[0].status, HarborEthMacRx.statusBcast);
    });

    test('bad FCS gives fcs_err', () async {
      final rand = Random(5);
      final data = _payload(rand, _ownMac, 80);
      for (final flip in [12, 79, 80, 83]) {
        final wire = _withFcs(data);
        wire[flip] ^= 0x10;
        final outs = await _run([_Wire(wire)]);
        await Simulator.reset();
        expect(outs, hasLength(1));
        expect(outs[0].data, equals(wire.sublist(0, 80)));
        expect(outs[0].status, HarborEthMacRx.statusFcsErr, reason: '$flip');
      }
    });

    test('63 bytes gives runt, 64 does not', () async {
      final rand = Random(6);
      final short = _payload(rand, _ownMac, 59);
      final ok = _payload(rand, _ownMac, 60);
      final outs = await _run([_Wire(_withFcs(short)), _Wire(_withFcs(ok))]);
      expect(outs, hasLength(2));
      expect(outs[0].data, equals(short));
      expect(outs[0].status, HarborEthMacRx.statusRunt);
      expect(outs[1].status, 0);
    });

    test('tiny frames give runt or nothing', () async {
      final outs = await _run([
        _Wire(_ownMac.sublist(0, 5)),
        _Wire(_withFcs(_ownMac.sublist(0, 6))),
        _Wire(_ownMac),
      ]);
      expect(outs, hasLength(2));
      expect(outs[0].data, equals(_ownMac.sublist(0, 6)));
      expect(outs[0].status, HarborEthMacRx.statusRunt);
      expect(outs[1].data, equals(_ownMac.sublist(0, 2)));
      expect(
        outs[1].status,
        HarborEthMacRx.statusRunt | HarborEthMacRx.statusFcsErr,
      );
    });

    test('1523 bytes or more gives oversize and a cut at 1522', () async {
      final rand = Random(8);
      final good = _payload(rand, _ownMac, 60);
      for (final len in [1519, 1600]) {
        final data = _payload(rand, _ownMac, len);
        final outs = await _run([_Wire(_withFcs(data)), _Wire(_withFcs(good))]);
        await Simulator.reset();
        expect(outs, hasLength(2), reason: '$len');
        expect(outs[0].data, equals(data.sublist(0, 1518)));
        expect(
          outs[0].status & HarborEthMacRx.statusOversize,
          isNonZero,
          reason: '$len',
        );
        expect(
          outs[0].status &
              (HarborEthMacRx.statusRunt | HarborEthMacRx.statusRxEr),
          0,
        );
        expect(outs[1].data, equals(good));
        expect(outs[1].status, 0);
      }
    });

    test('rx_er gives status bit 3', () async {
      final rand = Random(9);
      final data = _payload(rand, _ownMac, 70);
      final outs = await _run([
        _Wire(_withFcs(data), erAt: 40),
        _Wire(_withFcs(data), erAt: 73),
        _Wire(_withFcs(data)),
      ]);
      expect(outs, hasLength(3));
      expect(outs[0].data, equals(data));
      expect(outs[0].status, HarborEthMacRx.statusRxEr);
      expect(outs[1].status, HarborEthMacRx.statusRxEr);
      expect(outs[2].status, 0);
    });

    test('preamble with 5 to 7 bytes of 0x55 is accepted', () async {
      final rand = Random(10);
      final datas = [for (var i = 0; i < 3; i++) _payload(rand, _ownMac, 64)];
      final outs = await _run([
        for (var i = 0; i < 3; i++) _Wire(_withFcs(datas[i]), preamble: 5 + i),
      ]);
      expect([for (final o in outs) o.data], equals(datas));
      expect([for (final o in outs) o.status], equals([0, 0, 0]));
    });
  });

  group('HarborEthMacRx rx_en', () {
    test('a frame with its SFD while rx_en is low gives no output', () async {
      final rand = Random(20);
      final datas = [for (var i = 0; i < 3; i++) _payload(rand, _ownMac, 60)];
      final frames = [for (final d in datas) _Wire(_withFcs(d))];
      final outs = await _run(
        frames,
        rxEnFirst: false,
        events: {
          // High in the middle of frame 0, low in the middle of frame 1.
          _sfdSlot(frames, 0) + 10: const _Event(rxEn: true),
          _sfdSlot(frames, 1) + 10: const _Event(rxEn: false),
        },
      );
      expect(outs, hasLength(1));
      expect(outs[0].data, equals(datas[1]));
      expect(outs[0].status, 0);
    });

    test('a new MAC is complete when rx_en goes high', () async {
      const newMac = [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE];
      final rand = Random(21);
      final toNew = _payload(rand, newMac, 60);
      final toOld = _payload(rand, _ownMac, 60);
      var accepted = 0;
      for (var off = 1; off <= 8; off++) {
        for (final data in [toNew, toOld]) {
          final frames = [_Wire(_withFcs(data))];
          final outs = await _run(
            frames,
            rxEnFirst: false,
            events: {
              // The driver writes the MAC and rx_en in the same cycle.
              _sfdSlot(frames, 0) - off: const _Event(rxEn: true, mac: newMac),
            },
          );
          await Simulator.reset();
          if (data == toOld) {
            expect(outs, isEmpty, reason: 'old MAC kept, offset $off');
          } else if (outs.isNotEmpty) {
            expect(outs.single.data, equals(toNew));
            accepted++;
          }
        }
      }
      // The slots just before the SFD are too late for rx_en.
      expect(accepted, inInclusiveRange(1, 7));
    });
  });

  group('HarborEthMacRx edges', () {
    test('1522 bytes pass and 1523 bytes are cut', () async {
      final rand = Random(3);
      final a = _payload(rand, _ownMac, 1518);
      final b = _payload(rand, _ownMac, 1519);
      final outs = await _run([_Wire(_withFcs(a)), _Wire(_withFcs(b))]);
      expect(outs, hasLength(2));
      expect(outs[0].data, equals(a));
      expect(outs[0].status, 0);
      expect(outs[1].data, equals(b.sublist(0, 1518)));
      expect(outs[1].status & HarborEthMacRx.statusOversize, isNonZero);
    });

    test('two frames with no rx_dv gap are one bad frame', () async {
      final rand = Random(2);
      final a = _payload(rand, _ownMac, 60);
      final b = _payload(rand, _ownMac, 60);
      final wire = [
        ..._withFcs(a),
        for (var i = 0; i < 7; i++) 0x55,
        0xD5,
        ..._withFcs(b),
      ];
      final outs = await _run([_Wire(wire)]);
      expect(outs, hasLength(1));
      expect(outs[0].data, equals(wire.sublist(0, wire.length - 4)));
      expect(outs[0].status, HarborEthMacRx.statusFcsErr);
    });

    final hashCfg = HarborEthernetConfig(
      phy: HarborEthPhy.mii,
      multicastHash: true,
    );
    // Hash bits from Linux ether_crc(6, addr) >> 26.
    for (final (da, bit) in [
      ([0x01, 0x00, 0x5E, 0x00, 0x00, 0x01], 31),
      ([0x33, 0x33, 0x00, 0x00, 0x00, 0x01], 62),
    ]) {
      for (final (first, mid) in [(1 << bit, 0), (0, 1 << bit)]) {
        test('multicast $da: MC_HASH ${first == 0 ? 'set' : 'cleared'} '
            'in the frame', () async {
          final rand = Random(2);
          final d = _payload(rand, da, 100);
          final next = _payload(rand, _ownMac, 70);
          final frames = [_Wire(_withFcs(d)), _Wire(_withFcs(next))];
          // The new table comes in the middle of the first frame.
          final outs = await _run(
            frames,
            config: hashCfg,
            mcHash: first,
            events: {_sfdSlot(frames, 0) + 40: _Event(hash: mid)},
          );
          final want = [if (first != 0) d, next];
          expect(outs.map((o) => o.data).toList(), want);
          for (final o in outs) {
            expect(o.status & 0x0F, 0, reason: 'good status');
          }
        });
      }

      test('multicast $da uses hash bit $bit', () async {
        expect(_hashIndex(da), bit);
        final rand = Random(1);
        final d = _payload(rand, da, 60);
        var outs = await _run(
          [_Wire(_withFcs(d))],
          config: hashCfg,
          mcHash: 1 << bit,
        );
        expect(outs, hasLength(1));
        await Simulator.reset();
        outs = await _run(
          [_Wire(_withFcs(d))],
          config: hashCfg,
          mcHash: ~(1 << bit),
        );
        expect(outs, isEmpty);
      });
    }
  });

  test('full config generates SystemVerilog', () async {
    final cfg = HarborEthernetConfig(
      phy: HarborEthPhy.mii,
      multicastHash: true,
      promiscuous: true,
    );
    final dut = HarborEthMacRx(
      Logic(),
      Logic(),
      config: cfg,
      rxStrobe: Logic(),
      rxData: Logic(width: 8),
      rxDv: Logic(),
      rxEr: Logic(),
      rxEn: Logic(),
      macAddr: Logic(width: 48),
      mcHash: Logic(width: 64),
      promisc: Logic(),
    );
    await dut.build();
    final sv = dut.generateSynth();
    expect(sv, contains('module HarborEthMacRx_Hash_Promisc'));
    expect(sv, contains('module HarborEthRxFilter_Hash_Promisc'));
    expect(sv, contains('module HarborCdcSync_S2_W48'));
    expect(sv, contains('module HarborCdcSync_S2_W64'));
    expect(sv, contains('module HarborCdcSync_S3_W1'));
  });

  group('HarborEthMacRx filter', () {
    final full = HarborEthernetConfig(
      phy: HarborEthPhy.mii,
      multicastHash: true,
      promiscuous: true,
    );
    const other = [0x02, 0x11, 0x22, 0x33, 0x44, 0x56];
    const mcHit = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x01];
    const mcMiss = [0x33, 0x33, 0x00, 0x00, 0x00, 0x01];
    final hitBit = _hashIndex(mcHit);

    Future<List<List<int>>> kept(
      HarborEthernetConfig cfg, {
      bool promisc = false,
    }) async {
      final rand = Random(11);
      final das = [_ownMac, other, ethArpRequest.sublist(0, 6), mcHit, mcMiss];
      final datas = [for (final da in das) _payload(rand, da, 64)];
      final outs = await _run(
        [for (final d in datas) _Wire(_withFcs(d))],
        config: cfg,
        mcHash: 1 << hitBit,
        promisc: promisc,
      );
      for (final o in outs) {
        final i = datas.indexWhere((d) => _listEq(d, o.data));
        expect(i, isNot(-1), reason: 'output is not a sent frame');
        final da = das[i];
        final bc = da.every((b) => b == 0xFF);
        final mc = (da[0] & 1) == 1 && !bc;
        expect(
          o.status,
          (bc ? HarborEthMacRx.statusBcast : 0) |
              (mc ? HarborEthMacRx.statusMcast : 0),
        );
      }
      return [for (final o in outs) o.data.sublist(0, 6)];
    }

    test('hash bits of the test addresses differ', () {
      expect(_hashIndex(mcMiss), isNot(hitBit));
    });

    test('basic keeps own and broadcast only', () async {
      final das = await kept(HarborEthernetConfig.basic(phy: HarborEthPhy.mii));
      expect(das, equals([_ownMac, List.filled(6, 0xFF)]));
    });

    test('hash keeps multicast only on a hash hit', () async {
      final das = await kept(full);
      expect(das, equals([_ownMac, List.filled(6, 0xFF), mcHit]));
    });

    test('promisc keeps everything', () async {
      final das = await kept(full, promisc: true);
      expect(das, hasLength(5));
    });

    test('multicast without the hash option needs promisc', () async {
      final cfg = HarborEthernetConfig(
        phy: HarborEthPhy.mii,
        promiscuous: true,
      );
      expect(await kept(cfg), equals([_ownMac, List.filled(6, 0xFF)]));
      await Simulator.reset();
      expect(await kept(cfg, promisc: true), hasLength(5));
    });

    test('a dropped bad frame shows nothing', () async {
      final rand = Random(12);
      final data = _payload(rand, other, 30);
      final good = _payload(rand, _ownMac, 60);
      final outs = await _run([
        _Wire(data, erAt: 3),
        _Wire(_withFcs(_payload(rand, other, 2000))),
        _Wire(_withFcs(good)),
      ]);
      expect(outs, hasLength(1));
      expect(outs[0].data, equals(good));
    });
  });
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
