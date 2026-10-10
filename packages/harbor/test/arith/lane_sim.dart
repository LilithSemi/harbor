import 'dart:math';

import 'package:rohd/rohd.dart';

/// Evaluates a built combinational ROHD module for 64 cases at once.
///
/// Each bit of each signal is one Dart int, and bit `j` of that int belongs to
/// case `j`. Gates run once per pass in dependency order. The ROHD event
/// simulator runs a gate again for each input change, which is very slow for
/// a compression tree.
///
/// Only plain ROHD gates and [FlipFlop]s are supported. A Combinational,
/// Sequential or any other module with its own behavior throws at
/// construction. A flop output is state: [clock] loads it, and each lane
/// starts at 0. A flop must have a synchronous reset to 0, if any. Every
/// flop must be on one clock: [clock] when it is given, else the clock of
/// the first flop. A flop on another clock throws at construction.
class LaneSim {
  static const lanes = 64;

  final Map<Logic, int> _ids = {};
  final Map<Logic, Module> _driver = {};
  final List<List<int>> _values = [];
  final List<void Function()> _steps = [];
  final Set<Logic> _inputs;

  // Signals on the current walk, to find a combinational loop.
  final Set<Logic> _busy = {};

  final Map<Logic, FlipFlop> _flopOf = {};
  final List<FlipFlop> _pending = [];
  final List<(List<int>, List<int>, List<int>?, List<int>?)> _flops = [];

  /// Compiles the cone of [outputs] in [top]. [inputs] are the free signals
  /// that [set] drives.
  LaneSim(Module top, List<Logic> inputs, List<Logic> outputs, {Logic? clock})
    : _inputs = inputs.toSet() {
    Logic root(Logic l) {
      var r = l;
      while (r.srcConnection != null) {
        r = r.srcConnection!;
      }
      return r;
    }

    var clk = clock == null ? null : root(clock);
    void walk(Module m) {
      for (final s in m.subModules) {
        if (s is FlipFlop) {
          _flopOf[s.q] = s;
          continue;
        }
        if (s.subModules.isEmpty) {
          for (final o in s.outputs.values) {
            _driver[o] = s;
          }
        }
        walk(s);
      }
    }

    walk(top);
    inputs.forEach(_alloc);
    for (final o in outputs) {
      _node(o);
    }
    while (_pending.isNotEmpty) {
      final f = _pending.removeLast();
      if (f.asyncReset ||
          f.tryInput(Naming.unpreferredName('resetValue')) != null) {
        throw UnsupportedError('LaneSim: $f needs a sync reset to 0');
      }
      final fc = root(f.input(Naming.unpreferredName('clk')));
      clk ??= fc;
      if (fc != clk) {
        throw UnsupportedError('LaneSim: $f is on clock $fc, not $clk');
      }
      List<int>? opt(String name) {
        final l = f.tryInput(Naming.unpreferredName(name));
        return l == null ? null : _values[_node(l)];
      }

      _flops.add((
        _values[_ids[f.q]!],
        _values[_node(f.input(Naming.unpreferredName('d')))],
        opt('en'),
        opt('reset'),
      ));
    }
  }

  /// Number of flops in the compiled cones.
  int get flopCount => _flops.length;

  /// One rising clock edge: every flop loads from the values of the last
  /// [run]. Call [run] again to see the new outputs.
  void clock() {
    final next = [
      for (final (q, d, en, rst) in _flops)
        [
          for (var i = 0; i < q.length; i++)
            (en == null ? d[i] : (d[i] & en[0]) | (q[i] & ~en[0])) &
                (rst == null ? -1 : ~rst[0]),
        ],
    ];
    for (var k = 0; k < _flops.length; k++) {
      _flops[k].$1.setAll(0, next[k]);
    }
  }

  /// Sets a 1 bit [input]: bit `j` of [mask] is the value of lane `j`.
  void setMask(Logic input, int mask) {
    _values[_ids[input]!][0] = mask;
  }

  /// A 1 bit [signal] as a lane mask.
  int getMask(Logic signal) => _values[_ids[signal]!][0];

  /// Sets [input] to [cases], one value per lane. Missing lanes read 0.
  void set(Logic input, List<BigInt> cases) {
    final bits = _values[_ids[input]!];
    bits.fillRange(0, bits.length, 0);
    final mask = BigInt.from(0xffffffff);
    for (var j = 0; j < cases.length; j++) {
      for (var k = 0; k < input.width; k += 32) {
        var chunk = ((cases[j] >> k) & mask).toInt();
        for (var i = k; chunk != 0; i++, chunk >>= 1) {
          if (chunk & 1 != 0) {
            bits[i] |= 1 << j;
          }
        }
      }
    }
  }

  /// Runs every gate once.
  void run() {
    for (final s in _steps) {
      s();
    }
  }

  /// The first [count] lane values of [signal].
  List<BigInt> get(Logic signal, int count) {
    final bits = _values[_ids[signal]!];
    return [
      for (var j = 0; j < count; j++)
        () {
          var v = BigInt.zero;
          for (var k = (bits.length - 1) ~/ 32 * 32; k >= 0; k -= 32) {
            var chunk = 0;
            for (var i = min(k + 32, bits.length) - 1; i >= k; i--) {
              chunk = (chunk << 1) | ((bits[i] >> j) & 1);
            }
            v = (v << 32) | BigInt.from(chunk);
          }
          return v;
        }(),
    ];
  }

  int _alloc(Logic l) {
    final id = _values.length;
    _values.add(List.filled(l.width, 0));
    _ids[l] = id;
    return id;
  }

  int _node(Logic l) {
    final known = _ids[l];
    if (known != null) {
      return known;
    }
    if (_inputs.contains(l)) {
      return _alloc(l);
    }
    final f = _flopOf[l];
    if (f != null) {
      _pending.add(f);
      return _alloc(l);
    }
    if (l is Const) {
      final v = l.value;
      if (!v.isValid) {
        throw StateError('LaneSim: $l has X or Z bits');
      }
      final id = _alloc(l);
      for (var i = 0; i < l.width; i++) {
        _values[id][i] = v[i] == LogicValue.one ? -1 : 0;
      }
      return id;
    }
    if (!_busy.add(l)) {
      throw StateError('LaneSim: combinational loop through $l');
    }
    try {
      final src = l.srcConnection;
      if (src != null) {
        final id = _node(src);
        _ids[l] = id;
        return id;
      }
      final g = _driver[l];
      if (g == null) {
        throw StateError('LaneSim: $l has no driver');
      }
      final ins = [for (final i in g.inputs.values) _values[_node(i)]];
      final outs = [for (final o in g.outputs.values) _values[_alloc(o)]];
      _steps.add(_gate(g, ins, outs));
      return _ids[l]!;
    } finally {
      _busy.remove(l);
    }
  }

  static void Function() _gate(
    Module g,
    List<List<int>> ins,
    List<List<int>> outs,
  ) {
    final out = outs.first;
    final w = out.length;
    if (g is NotGate) {
      final a = ins[0];
      return () {
        for (var i = 0; i < w; i++) {
          out[i] = ~a[i];
        }
      };
    }
    if (g is And2Gate || g is Or2Gate || g is Xor2Gate) {
      final a = ins[0];
      final b = ins[1];
      if (g is And2Gate) {
        return () {
          for (var i = 0; i < w; i++) {
            out[i] = a[i] & b[i];
          }
        };
      }
      if (g is Or2Gate) {
        return () {
          for (var i = 0; i < w; i++) {
            out[i] = a[i] | b[i];
          }
        };
      }
      return () {
        for (var i = 0; i < w; i++) {
          out[i] = a[i] ^ b[i];
        }
      };
    }
    if (g is AndUnary || g is OrUnary || g is XorUnary) {
      final a = ins[0];
      return () {
        var acc = g is AndUnary ? -1 : 0;
        for (final x in a) {
          acc = g is AndUnary ? acc & x : (g is OrUnary ? acc | x : acc ^ x);
        }
        out[0] = acc;
      };
    }
    if (g is Mux) {
      final c = ins[0];
      final d0 = ins[1];
      final d1 = ins[2];
      return () {
        final s = c[0];
        for (var i = 0; i < w; i++) {
          out[i] = (d1[i] & s) | (d0[i] & ~s);
        }
      };
    }
    if (g is Add || g is Subtract) {
      final a = ins[0];
      final b = ins[1];
      final sub = g is Subtract;
      final carryOut = g is Add ? outs[1] : null;
      return () {
        var carry = sub ? -1 : 0;
        for (var i = 0; i < w; i++) {
          final y = sub ? ~b[i] : b[i];
          final t = a[i] ^ y;
          out[i] = t ^ carry;
          carry = (a[i] & y) | (carry & t);
        }
        if (carryOut != null) {
          carryOut[0] = carry;
        }
      };
    }
    if (g is Equals || g is NotEquals) {
      final a = ins[0];
      final b = ins[1];
      final eq = g is Equals;
      return () {
        var diff = 0;
        for (var i = 0; i < a.length; i++) {
          diff |= a[i] ^ b[i];
        }
        out[0] = eq ? ~diff : diff;
      };
    }
    if (g is LessThan ||
        g is GreaterThan ||
        g is LessThanOrEqual ||
        g is GreaterThanOrEqual) {
      final swap = g is GreaterThan || g is LessThanOrEqual;
      final a = swap ? ins[1] : ins[0];
      final b = swap ? ins[0] : ins[1];
      final invert = g is LessThanOrEqual || g is GreaterThanOrEqual;
      return () {
        // a < b when a - b borrows.
        var carry = -1;
        for (var i = 0; i < a.length; i++) {
          final y = ~b[i];
          carry = (a[i] & y) | (carry & (a[i] ^ y));
        }
        out[0] = invert ? carry : ~carry;
      };
    }
    if (g is LShift || g is RShift || g is ARShift) {
      final a = ins[0];
      final amt = ins[1];
      return () {
        var cur = List.of(a);
        for (var j = 0; j < amt.length; j++) {
          final s = amt[j];
          if (s == 0) {
            continue;
          }
          final fill = g is ARShift ? cur[w - 1] : 0;
          final by = j < 30 ? 1 << j : w;
          final next = List.filled(w, 0);
          for (var i = 0; i < w; i++) {
            final int moved;
            if (g is LShift) {
              moved = i - by >= 0 ? cur[i - by] : 0;
            } else {
              moved = i + by < w ? cur[i + by] : fill;
            }
            next[i] = (moved & s) | (cur[i] & ~s);
          }
          cur = next;
        }
        for (var i = 0; i < w; i++) {
          out[i] = cur[i];
        }
      };
    }
    if (g is BusSubset) {
      final a = ins[0];
      final lo = g.startIndex;
      final hi = g.endIndex;
      return () {
        for (var i = 0; i < w; i++) {
          out[i] = a.length == 1 ? a[0] : (hi < lo ? a[lo - i] : a[lo + i]);
        }
      };
    }
    if (g is Swizzle) {
      return () {
        var k = 0;
        for (final part in ins) {
          for (final x in part) {
            out[k++] = x;
          }
        }
      };
    }
    if (g is ReplicationOp) {
      final a = ins[0];
      return () {
        for (var i = 0; i < w; i++) {
          out[i] = a[i % a.length];
        }
      };
    }
    if (g is Multiply) {
      final a = ins[0];
      final b = ins[1];
      // Each lane on its own. An int product wraps modulo 2^64, so its low
      // bits are correct up to 63 bits.
      return () {
        for (var i = 0; i < w; i++) {
          out[i] = 0;
        }
        for (var lane = 0; lane < lanes; lane++) {
          if (w <= 63) {
            var x = 0;
            var y = 0;
            for (var i = w - 1; i >= 0; i--) {
              x = (x << 1) | ((a[i] >> lane) & 1);
              y = (y << 1) | ((b[i] >> lane) & 1);
            }
            final p = x * y;
            for (var i = 0; i < w; i++) {
              out[i] |= ((p >> i) & 1) << lane;
            }
          } else {
            var x = BigInt.zero;
            var y = BigInt.zero;
            for (var i = w - 1; i >= 0; i--) {
              x = (x << 1) | BigInt.from((a[i] >> lane) & 1);
              y = (y << 1) | BigInt.from((b[i] >> lane) & 1);
            }
            final p = x * y;
            for (var i = 0; i < w; i++) {
              if ((p >> i).isOdd) {
                out[i] |= 1 << lane;
              }
            }
          }
        }
      };
    }
    throw UnsupportedError('LaneSim: ${g.runtimeType} is not supported');
  }
}
