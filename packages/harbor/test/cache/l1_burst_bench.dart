import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// One request the memory model took.
typedef BurstRequest = ({int addr, int len, bool write, int size});

/// Memory model for the burst port of an L1 cache.
///
/// It takes a request when `mem_en` is high and it is idle, then gives
/// `mem_len + 1` beats: the first after [latency] cycles, the next ones after
/// [gap] cycles each. Beat k of a burst reads the word at `mem_addr` plus k
/// words. Memory is a map of bytes, so a store writes only its bytes.
class BurstMemory {
  BurstMemory(this.cache, {required this.xlen, this.latency = 3, this.gap = 0})
    : wordBytes = xlen ~/ 8;

  final Module cache;
  final int xlen;
  final int wordBytes;

  /// Cycles from the request to the first beat.
  int latency;

  /// Idle cycles between two beats. A negative value picks 0 to 2 at random.
  int gap;

  final _rng = Random(7);

  /// Bytes of memory. A missing byte reads as the low byte of its address.
  final bytes = <int, int>{};

  /// Every request in the order the model took it.
  final requests = <BurstRequest>[];

  /// Beats given for each request.
  final beatsGiven = <int>[];

  /// Returns true to give an error on beat [beat] of request [req].
  bool Function(int req, int beat)? error;

  /// Error beats are page faults when true, else access faults.
  bool errorIsPage = false;

  /// Beat that carries mem_last, when set. It models a broken memory port
  /// that ends a burst early or late.
  int? lastBeat;

  /// Called on the cycle the model takes a write, before it changes memory.
  void Function(BurstRequest req)? onWrite;

  bool _active = false;
  int _wait = 0;
  int _beat = 0;
  BurstRequest? _req;
  BigInt _wdata = BigInt.zero;

  bool get busy => _active;

  void _drive(String name, Object value) =>
      cache.input(name).srcConnection!.inject(value);

  int byteAt(int a) => bytes[a] ?? (a & 0xff);

  BigInt wordAt(int a) {
    var v = BigInt.zero;
    for (var i = wordBytes - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(byteAt(a + i));
    }
    return v;
  }

  /// Value of [size] bytes at [a], as a load gives it.
  BigInt valueAt(int a, int size) {
    var v = BigInt.zero;
    for (var i = (1 << size) - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(byteAt(a + i));
    }
    return v;
  }

  void writeValue(int a, int size, BigInt v) {
    for (var i = 0; i < 1 << size; i++) {
      bytes[a + i] = ((v >> (8 * i)) & BigInt.from(0xff)).toInt();
    }
  }

  void reset() {
    _drive('mem_done', 0);
    _drive('mem_valid', 0);
    _drive('mem_last', 0);
    _drive('mem_rdata', 0);
    if (cache.inputs.containsKey('mem_fault')) _drive('mem_fault', 0);
  }

  int _nextGap() => gap >= 0 ? gap : _rng.nextInt(3);

  /// Samples the request on the rising edge and drives the beat for the next
  /// cycle. Call it once per cycle, right after the edge.
  void tick() {
    final en = cache.output('mem_en').value;
    if (!_active && en.isValid && en.toBool()) {
      final hasWe = cache.outputs.containsKey('mem_we');
      final req = (
        addr: cache.output('mem_addr').value.toInt(),
        len: cache.output('mem_len').value.toInt(),
        write: hasWe && cache.output('mem_we').value.toBool(),
        size: cache.outputs.containsKey('mem_size')
            ? cache.output('mem_size').value.toInt()
            : wordBytes.bitLength - 1,
      );
      final w = hasWe ? cache.output('mem_wdata').value : LogicValue.zero;
      _wdata = w.isValid ? w.toBigInt() : BigInt.zero;
      _req = req;
      requests.add(req);
      beatsGiven.add(0);
      _active = true;
      _beat = 0;
      _wait = latency;
    }
    if (!_active || _wait > 0) {
      if (_active) _wait--;
      _drive('mem_done', 0);
      _drive('mem_valid', 0);
      _drive('mem_last', 0);
      return;
    }
    final req = _req!;
    final n = requests.length - 1;
    final bad = error?.call(n, _beat) ?? false;
    final last = _beat == (lastBeat ?? req.len);
    _drive('mem_done', 1);
    _drive('mem_valid', bad ? 0 : 1);
    _drive('mem_last', last ? 1 : 0);
    if (cache.inputs.containsKey('mem_fault')) {
      _drive('mem_fault', bad && errorIsPage ? 1 : 0);
    }
    if (req.write) {
      onWrite?.call(req);
      if (!bad) writeValue(req.addr, req.size, _wdata);
      _drive('mem_rdata', 0);
    } else {
      final base = req.addr & ~(wordBytes - 1);
      final word = wordAt(base + _beat * wordBytes);
      // A one-beat read gives its bytes in lane 0, as the MMU does. For an
      // aligned full word that is the raw word.
      final shift = req.len == 0 ? 8 * (req.addr - base) : 0;
      _drive('mem_rdata', LogicValue.ofBigInt(word >> shift, xlen));
    }
    beatsGiven[n]++;
    _beat++;
    if (last) {
      _active = false;
    } else {
      _wait = _nextGap();
    }
  }
}

/// Cache under test with its clock and the burst memory model.
class BurstDut {
  BurstDut._(this.cache, this.mem, this.clk);

  final Module cache;
  final BurstMemory mem;
  final Logic clk;
  var cycle = 0;

  /// The error that stopped the simulation, if any.
  Object? simError;

  /// Extra work for each cycle, after the memory model.
  final perCycle = <void Function()>[];

  void drive(String name, Object value) =>
      cache.input(name).srcConnection!.inject(value);
  bool out(String name) => cache.output(name).value.toBool();
  BigInt outBig(String name) => cache.output(name).value.toBigInt();

  /// One clock cycle.
  Future<void> step() async {
    if (simError != null) throw StateError('simulation stopped: $simError');
    await clk.nextPosedge.timeout(const Duration(seconds: 30));
    cycle++;
    mem.tick();
    for (final f in perCycle) {
      f();
    }
  }

  Future<void> steps(int n) async {
    for (var i = 0; i < n; i++) {
      await step();
    }
  }

  static Future<BurstDut> make({
    required bool instruction,
    required int xlen,
    required int lineSize,
    int size = 1024,
    bool checkMemLast = true,
    bool physical = false,
    bool snoop = false,
    void Function(Module cache, Logic clk)? connect,
    int latency = 3,
    int gap = 0,
  }) async {
    final Module cache = instruction
        ? HarborL1ICache(
            config: HarborL1iCacheConfig(
              size: size,
              ways: 1,
              lineSize: lineSize,
            ),
            xlen: xlen,
            checkMemLast: checkMemLast,
          )
        : HarborL1DCache(
            config: HarborL1dCacheConfig(
              size: size,
              ways: 1,
              lineSize: lineSize,
            ),
            xlen: xlen,
            physicalAddresses: physical,
            snoop: snoop,
            checkMemLast: checkMemLast,
            memFaultIn: Logic(name: 'mem_fault_in'),
          );
    final clk = SimpleClockGenerator(10).clk;
    cache.input('clk').srcConnection! <= clk;
    connect?.call(cache, clk);
    for (final input in cache.inputs.values) {
      final src = input.srcConnection!;
      if (input.name != 'clk' && src.srcConnection == null) src.put(0);
    }
    await cache.build();
    final mem = BurstMemory(cache, xlen: xlen, latency: latency, gap: gap);
    final dut = BurstDut._(cache, mem, clk);
    dut.drive('reset', 1);
    if (!instruction) dut.drive('req_size', (xlen ~/ 8).bitLength - 1);
    mem.reset();
    Simulator.setMaxSimTime(4000000);
    unawaited(
      Simulator.run().catchError((Object e) {
        dut.simError = e;
      }),
    );
    await dut.steps(2);
    dut.drive('reset', 0);
    final sweep = cache is HarborL1ICache
        ? cache.sweepCycles
        : (cache as HarborL1DCache).sweepCycles;
    await dut.steps(sweep + 4);
    return dut;
  }

  /// Fetch or load of [size] bytes at [addr]. Returns the data, or null on a
  /// fault. A fetch returns the raw word.
  Future<BigInt?> read(int addr, {int? size, int limit = 2000}) async {
    final instruction = cache is HarborL1ICache;
    drive('req_addr', addr);
    if (!instruction) {
      drive('req_write', 0);
      drive('req_size', size ?? (mem.wordBytes.bitLength - 1));
    }
    drive('req_valid', 1);
    for (var i = 0; i < limit; i++) {
      await step();
      if (out('resp_valid')) {
        final v = outBig('resp_data');
        drive('req_valid', 0);
        await step();
        return v;
      }
      if (out('resp_fault')) {
        drive('req_valid', 0);
        await step();
        return null;
      }
    }
    throw StateError('read of 0x${addr.toRadixString(16)} did not end');
  }

  /// Store of [size] bytes at [addr]. Returns false on a fault.
  Future<bool> write(
    int addr,
    int size,
    BigInt data, {
    int limit = 2000,
  }) async {
    drive('req_addr', addr);
    drive('req_write', 1);
    drive('req_size', size);
    drive('req_data', LogicValue.ofBigInt(data, mem.xlen));
    drive('req_valid', 1);
    for (var i = 0; i < limit; i++) {
      await step();
      final ok = out('resp_valid');
      final fault = out('resp_fault');
      if (ok || fault) {
        drive('req_valid', 0);
        drive('req_write', 0);
        await step();
        return ok;
      }
    }
    throw StateError('store to 0x${addr.toRadixString(16)} did not end');
  }
}
