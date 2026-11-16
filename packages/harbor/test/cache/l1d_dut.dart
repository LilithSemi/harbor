import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:harbor/harbor.dart';

/// Shared [HarborL1DCache] test bench: the cache, its request ports and a
/// multi-cycle backing memory that counts every access it is given.
class Backing {
  Backing({
    required this.cache,
    required this.memDone,
    required this.memValid,
    required this.memLast,
    required this.memRdata,
    required this.memFault,
    required this.latency,
  });

  final HarborL1DCache cache;
  final Logic memDone;
  final Logic memValid;
  final Logic memLast;
  final Logic memRdata;
  final Logic memFault;
  final int latency;

  /// When set, every memory response is a FAULT (`mem_done` with `mem_valid`
  /// low), which is how the MMU reports a page fault.
  var faultResponse = false;

  /// Classification for [faultResponse]: true is page fault, false is physical
  /// access fault.
  var faultIsPage = true;

  final mem = <int, BigInt>{};

  /// Base address of every read request, in order.
  final readLog = <int>[];
  final writeLog = <(int, BigInt)>[];
  var writes = 0;

  /// Read requests served. A line refill is one request.
  var reads = 0;

  /// Memory accesses started, faulting ones included.
  var accesses = 0;

  /// Beats given, faulting ones included.
  var beats = 0;
  var _armed = false;
  var _pending = 0;
  var _addr = 0;
  var _len = 0;
  var _beat = 0;
  var _size = 3;
  var _pendWe = false;
  BigInt _pendW = BigInt.zero;

  /// One clock step with the multi-cycle memory model. The memory takes an
  /// access whenever `mem_en` is high and it is idle. It answers [latency]
  /// cycles later with `mem_len + 1` one-cycle `mem_done` pulses, the last
  /// with `mem_last`. `mem_en` stays high across a line refill, so arming is
  /// level based, not edge based.
  Future<void> step() async {
    await cache.input('clk').srcConnection!.nextPosedge;
    final en = cache.output('mem_en').value.toBool();
    if (!_armed && en) {
      _armed = true;
      accesses++;
      _pending = latency;
      _beat = 0;
      _addr = cache.output('mem_addr').value.toInt();
      _len = cache.output('mem_len').value.toInt();
      _size = cache.output('mem_size').value.toInt();
      _pendWe = cache.output('mem_we').value.toBool();
      final w = cache.output('mem_wdata').value;
      _pendW = w.isValid ? w.toBigInt() : BigInt.zero;
      if (!_pendWe) {
        reads++;
        readLog.add(_addr & ~7);
      }
    }
    var doneNow = false;
    if (_armed) {
      _pending--;
      if (_pending <= 0) doneNow = true;
    }
    if (!doneNow) {
      memDone.inject(0);
      memValid.inject(0);
      memLast.inject(0);
      memFault.inject(0);
      return;
    }
    final last = _beat == _len;
    beats++;
    memLast.inject(last ? 1 : 0);
    memDone.inject(1);
    if (faultResponse) {
      memValid.inject(0);
      memFault.inject(faultIsPage ? 1 : 0);
    } else {
      memValid.inject(1);
      memFault.inject(0);
      final base = _addr & ~7;
      if (_pendWe) {
        final bytes = 1 << _size;
        final shift = 8 * (_addr - base);
        final mask = ((BigInt.one << (8 * bytes)) - BigInt.one) << shift;
        final old = mem[base] ?? BigInt.zero;
        mem[base] = (old & ~mask) | ((_pendW << shift) & mask);
        writeLog.add((base, mem[base]!));
        writes++;
      } else {
        final word = mem[base + _beat * 8] ?? BigInt.zero;
        final shift = _len == 0 ? 8 * (_addr - base) : 0;
        memRdata.inject(word >> shift);
      }
    }
    _beat++;
    if (last) {
      _armed = false;
    } else {
      _pending = 1;
    }
  }
}

class Dut {
  Dut(this.cache, this.ports, this.backing);
  final HarborL1DCache cache;
  final Map<String, Logic> ports;
  final Backing backing;

  Logic operator [](String n) => ports[n]!;
  bool get respValid => cache.output('resp_valid').value.toBool();
  bool get respFault => cache.output('resp_fault').value.toBool();
  bool get respFaultIsAccess =>
      cache.output('resp_fault_is_access').value.toBool();
  bool get busy => cache.output('busy').value.toBool();
}

Future<Dut> makeDut({
  int latency = 6,
  int ctxBits = 0,
  int size = 256,
  int lineSize = 8,
  int? reqAddrBits = 32,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final ports = <String, Logic>{
    'reset': Logic(name: 'reset'),
    'req_addr': Logic(name: 'req_addr', width: 64),
    'req_valid': Logic(name: 'req_valid'),
    'req_write': Logic(name: 'req_write'),
    'req_data': Logic(name: 'req_data', width: 64),
    'req_size': Logic(name: 'req_size', width: 3),
    'flush': Logic(name: 'flush'),
    'mem_done': Logic(name: 'mem_done'),
    'mem_valid': Logic(name: 'mem_valid'),
    'mem_last': Logic(name: 'mem_last'),
    'mem_rdata': Logic(name: 'mem_rdata', width: 64),
    'mem_fault': Logic(name: 'mem_fault'),
    if (ctxBits > 0) 'req_ctx': Logic(name: 'req_ctx', width: ctxBits),
  };

  final cache = HarborL1DCache(
    config: HarborL1dCacheConfig(size: size, ways: 1, lineSize: lineSize),
    xlen: 64,
    ctxBits: ctxBits,
    reqAddrBits: reqAddrBits,
    memFaultIn: ports['mem_fault'],
  );
  cache.port('clk').getsLogic(clk);
  ports.forEach((n, l) {
    if (n != 'mem_fault') cache.port(n).getsLogic(l);
  });
  await cache.build();

  ports['reset']!.inject(1);
  ports['req_valid']!.inject(0);
  ports['req_write']!.inject(0);
  ports['req_addr']!.inject(0);
  ports['req_data']!.inject(0);
  ports['req_size']!.inject(3);
  ports['flush']!.inject(0);
  ports['mem_done']!.inject(0);
  ports['mem_valid']!.inject(0);
  ports['mem_last']!.inject(0);
  ports['mem_rdata']!.inject(0);
  ports['mem_fault']!.inject(0);
  if (ctxBits > 0) ports['req_ctx']!.inject(0);

  unawaited(Simulator.run());

  final backing = Backing(
    cache: cache,
    memDone: ports['mem_done']!,
    memValid: ports['mem_valid']!,
    memLast: ports['mem_last']!,
    memRdata: ports['mem_rdata']!,
    memFault: ports['mem_fault']!,
    latency: latency,
  );
  await backing.step();
  ports['reset']!.inject(0);
  await backing.step();
  return Dut(cache, ports, backing);
}
