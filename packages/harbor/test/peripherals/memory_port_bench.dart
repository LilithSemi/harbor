import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';

/// A memory master port of [kind] on `clk` with its waist on ports `up_*`.
class PortRequester extends BridgeModule {
  PortRequester(HarborMemoryWaistConfig config, HarborFabricKind kind)
    : super(
        'MemPortRequester_${kind.name}_a${config.addressWidth}'
        '_d${config.dataWidth}_i${config.idWidth}_n${config.outstanding}',
        name: 'requester',
      ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    exposeWaist(this, port.waist, 'up', PairRole.consumer);
  }
}

/// Wires a [PortRequester] on the top clock to the native port `bus` of
/// [device], and pulls the requester waist up to the top as `up_*`.
void linkRequester(
  BridgeModule top,
  BridgeModule device,
  HarborMemoryWaistConfig config,
  HarborFabricKind kind,
) {
  final req = top.addSubModule(PortRequester(config, kind));
  req.input('clk').srcConnection! <= top.input('clk');
  req.input('reset').srcConnection! <= top.input('reset');
  connectInterfaces(req.interface('bus'), device.interface('bus'));
  top.pullUpInterface(req.interface('up'));
}

/// Random bursts through a requester waist on `up_*`, checked against a
/// golden memory. The memory below [span] starts with the [WordMemory]
/// start values, written by full INCR bursts first.
class MemoryPortCheck {
  final Sim s;
  final Random rng;
  final int busBytes;
  final int idWidth;
  final int span;
  final int timeout;
  final errors = <String>[];
  late final WaistRequester req;
  late final BurstGen gen;
  late final WordMemory want = WordMemory(busBytes);

  MemoryPortCheck(
    this.s,
    this.rng, {
    required this.busBytes,
    required this.idWidth,
    required this.span,
    this.timeout = 400000,
  }) {
    req = WaistRequester(s, 'up', rng, errors: errors);
    gen = BurstGen(
      rng,
      busBytes: busBytes,
      idWidth: idWidth,
      span: span - 256 * busBytes,
      errBase: 1 << 40,
    );
  }

  int get _busSize => busBytes.bitLength - 1;

  Future<void> _drain() => waitUntil(
    s,
    () => req.done && req.req.idleNow && req.wdata.idleNow,
    limit: timeout,
  );

  /// Writes the start value of every word below [span].
  Future<void> fill() async {
    for (var a = 0; a < span; a += 256 * busBytes) {
      req.send(
        Burst(
          id: 0,
          write: true,
          addr: a,
          len: 255,
          size: _busSize,
          burst: 1,
          data: [for (var i = 0; i < 256; i++) want.read(a + i * busBytes)],
          strb: List.filled(256, (1 << busBytes) - 1),
        ),
      );
    }
    await _drain();
  }

  /// Sends [count] random writes, then [count] random reads, then reads
  /// everything below [span] back, and checks every response.
  Future<List<String>> run(int count, {List<Burst> extra = const []}) async {
    final writes = [
      for (var i = 0; i < count; i++) gen.next(write: true),
      ...extra.where((b) => b.write),
    ];
    for (final b in writes) {
      req.send(b);
    }
    await _drain();
    for (final x in writes) {
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      for (var i = 0; i < x.beats; i++) {
        want.write(addrs[i], x.data[i], x.strb[i]);
      }
    }
    final reads = [
      for (var i = 0; i < count; i++) gen.next(write: false),
      ...extra.where((b) => !b.write),
      for (var a = 0; a < span; a += 256 * busBytes)
        Burst(id: 0, write: false, addr: a, len: 255, size: _busSize, burst: 1),
    ];
    for (final b in reads) {
      req.send(b);
    }
    await _drain();
    return [
      ...errors,
      for (final r in req.writeResp)
        if (r.$2 != 0) 'write response with ERR: $r',
      ..._readErrors(),
    ];
  }

  List<String> _readErrors() {
    final bad = <String>[];
    // The fill bursts have no reads, so read slots line up with req.reads.
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      final got = req.readResp[k];
      if (got.length != x.beats) {
        bad.add('$x: ${got.length} beats');
        continue;
      }
      for (var i = 0; i < x.beats; i++) {
        final lanes = _lanes(addrs[i], x.size);
        final w = want.read(addrs[i]) & lanes;
        final (id, data, err, last) = got[i];
        if (id != x.id || data & lanes != w || err != 0) {
          bad.add(
            '$x beat $i at 0x${addrs[i].toRadixString(16)}: got '
            '(id $id, 0x${(data & lanes).toRadixString(16)}, err $err) '
            'want 0x${w.toRadixString(16)}',
          );
        }
        if ((last == 1) != (i == x.len)) bad.add('$x beat $i: LAST $last');
      }
      if (bad.length > 20) break;
    }
    return bad;
  }

  int _lanes(int addr, int size) {
    final mask = busBytes == 8 ? -1 : (1 << (busBytes * 8)) - 1;
    if (size >= _busSize) return mask;
    final bytes = 1 << size;
    final lo = (addr & ~(bytes - 1)) % busBytes;
    var m = 0;
    for (var i = lo; i < lo + bytes; i++) {
      m |= 0xff << (8 * i);
    }
    return m & mask;
  }
}

/// Long bursts of every type, one of them all strobes low.
List<Burst> longBursts(Random rng, int busBytes) {
  final size = busBytes.bitLength - 1;
  final strb = (1 << busBytes) - 1;
  Burst w(int addr, int burst, int len, {bool zero = false}) => Burst(
    id: 0,
    write: true,
    addr: addr,
    len: len,
    size: size,
    burst: burst,
    data: [for (var i = 0; i <= len; i++) rng.nextInt(1 << 31)],
    strb: List.filled(len + 1, zero ? 0 : strb),
  );
  Burst r(int addr, int burst, int len) => Burst(
    id: 0,
    write: false,
    addr: addr,
    len: len,
    size: size,
    burst: burst,
  );
  return [
    w(0x40, 1, 255),
    w(0x10 * busBytes, 2, 15),
    w(0x300, 0, 15),
    w(0x500, 1, 31, zero: true),
    r(0x40, 1, 255),
    r(0x10 * busBytes + 4 * busBytes, 2, 15),
    r(0x300, 0, 15),
    r(0x500, 1, 31),
  ];
}
