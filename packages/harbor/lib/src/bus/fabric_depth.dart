import 'dart:math';

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';

import 'port/reg_fifo.dart';

/// The worst combinational path a [harborWorstDepth] walk finds.
class HarborDepthPath {
  /// LUT6-equivalent levels of the path.
  final int levels;

  /// The signals of the path, from the start point to the end point.
  final List<Logic> signals;

  const HarborDepthPath(this.levels, this.signals);

  /// The names of the start point, the named signals and the end point of
  /// [signals], each with its module instance.
  List<String> get names {
    final out = <String>[];
    for (var i = 0; i < signals.length; i++) {
      final s = signals[i];
      final ends = i == 0 || i == signals.length - 1;
      if (!ends && s.name.startsWith('_')) continue;
      final where = [
        for (final m in s.parentModule?.hierarchy() ?? const <Module>[])
          m.uniqueInstanceName,
      ];
      final n = [...where, s.name].join('.');
      if (out.isEmpty || out.last != n) out.add(n);
    }
    return out;
  }

  @override
  String toString() => '$levels levels: ${names.join(' -> ')}';
}

int _log3(int n) {
  var levels = 0;
  for (var reach = 1; reach < n; reach *= 3) {
    levels++;
  }
  return levels;
}

int _log6(int n) {
  var levels = 0;
  for (var reach = 1; reach < n; reach *= 6) {
    levels++;
  }
  return levels;
}

// The RAM models of HarborRegFifo and the CDC FIFO, found by type or by
// the definition name of the private CDC RAM.
bool _isRam(Module m) =>
    m is HarborFifoRam || m.definitionName.startsWith('HarborWaistCdcRam_');

bool _isWire(Module m) => m is BusSubset || m is Concat || m is ReplicationOp;

bool _isGate(Module m) =>
    m is And2Gate ||
    m is Or2Gate ||
    m is Xor2Gate ||
    m is NotGate ||
    m is AndUnary ||
    m is OrUnary ||
    m is XorUnary ||
    m is Equals ||
    m is NotEquals;

/// Select bits of a mux of [n] inputs.
int _selectBits(int n) => max(1, (n - 1).bitLength);

/// The LUT6-equivalent levels of [leaf] when all its inputs arrive at once.
///
/// - Wires (BusSubset, Concat, ReplicationOp) and NotGate cost 0.
/// - An n-input AND, OR or XOR, or a reduction of n bits, costs
///   `ceil(log6 n)`. A 2-input gate costs 1.
/// - A 2:1 Mux costs 1, as does a Combinational block of one If and an
///   else that only assign, as `harborBitMux` builds.
/// - Equality and compare of w bits cost `ceil(log6 (2 * w))`.
/// - Add and Subtract of w bits cost `1 + ceil(w / 16)`. A tree of k
///   operands, where each inner result goes only to the next Add or
///   Subtract, costs `ceil(log3 k) + ceil(w / 16)` at its last cell.
/// - A variable shift or IndexGate costs 1 per 2 select bits.
/// - A FIFO RAM read costs 1 up to 64 entries, plus 1 per 4 times more.
/// - Sequential and FlipFlop cost 0, because they end a path.
///
/// Any other leaf throws [UnsupportedError] with its type.
@visibleForTesting
int harborGateLevels(Module leaf) {
  if (leaf.subModules.isNotEmpty) {
    throw ArgumentError.value(leaf.name, 'leaf', 'has submodules');
  }
  if (leaf is Sequential || leaf is FlipFlop || _isWire(leaf)) return 0;
  if (leaf is NotGate) return 0;
  if (_isRam(leaf)) {
    // The RAM depth is taken as a power of two of the address width.
    final depth = 1 << leaf.input('rd_addr').width;
    var levels = 1;
    for (var d = 64; d < depth; d *= 4) {
      levels++;
    }
    return levels;
  }
  final ins = leaf.inputs.values.toList();
  if (leaf is AndUnary || leaf is OrUnary || leaf is XorUnary) {
    return _log6(ins.first.width);
  }
  if (leaf is And2Gate || leaf is Or2Gate || leaf is Xor2Gate) return 1;
  if (leaf is Mux) return 1;
  if (leaf is Equals ||
      leaf is NotEquals ||
      leaf is LessThan ||
      leaf is GreaterThan ||
      leaf is LessThanOrEqual ||
      leaf is GreaterThanOrEqual) {
    return _log6(2 * ins.first.width);
  }
  if (leaf is Add || leaf is Subtract) {
    return 1 + (ins.first.width + 15) ~/ 16;
  }
  if (leaf is LShift || leaf is RShift || leaf is ARShift) {
    if (ins.length < 2) return 0;
    final bits = min(ins[1].width, _selectBits(ins.first.width));
    return (bits + 1) ~/ 2;
  }
  if (leaf is Combinational &&
      leaf.conditionals.length == 1 &&
      leaf.outputs.length == 1 &&
      switch (leaf.conditionals.first) {
        final If c =>
          c.iffs.length <= 2 &&
              c.iffs.every((i) => i.then.every((x) => x is ConditionalAssign)),
        _ => false,
      }) {
    return 1;
  }
  if (leaf is IndexGate) {
    return (_selectBits(ins.first.width) + 1) ~/ 2;
  }
  throw UnsupportedError(
    'no depth cost for ${leaf.runtimeType} (${leaf.definitionName})',
  );
}

// The arrival of a bit. [level] is the LUT level of its value. [fill] is
// the Kraft sum of the open logic cone at that level: 1 for a full LUT or a
// single source pin, below 1 for a LUT that can take more inputs. A constant
// has fill 0. [via] and [viaBit] give the bit it came from.
class _Arrival {
  final int level;
  final double fill;
  final Logic? via;
  final int viaBit;

  const _Arrival(this.level, this.fill, [this.via, this.viaBit = 0]);

  static const constant = _Arrival(0, 0);
  static const source = _Arrival(0, 1);

  bool get isConstant => fill == 0;

  // Fill at [at] levels, for a cone that ends at [level].
  double fillAt(int at) => fill * pow(6, level - at);

  _Arrival from(Logic s, int bit) => _Arrival(level, fill, s, bit);
}

// The worst bit of a signal, as one input of a cell.
typedef _In = (_Arrival, Logic);

class _Walker {
  final Module root;
  final Map<Logic, List<_Arrival>> _memo = {};
  final Set<Logic> _open = {};

  _Walker(this.root);

  // The arrival of each bit of [s], low bit first.
  List<_Arrival> bits(Logic s) {
    final known = _memo[s];
    if (known != null) return known;
    if (!_open.add(s)) {
      throw StateError('combinational loop through ${s.name}');
    }
    final a = _compute(s);
    assert(a.length == s.width, 'bit count of ${s.name}');
    _open.remove(s);
    _memo[s] = a;
    return a;
  }

  // The worst bit of [s].
  _Arrival worst(Logic s) {
    final b = bits(s);
    var at = 0;
    for (var i = 1; i < b.length; i++) {
      if (_later(b[i], b[at])) at = i;
    }
    return b.isEmpty ? _Arrival.constant : b[at].from(s, at);
  }

  List<_Arrival> _compute(Logic s) {
    final w = s.width;
    if (s is Const) return List.filled(w, _Arrival.constant);
    final m = s.parentModule;
    if (s.isInput && m == root) return List.filled(w, _Arrival.source);
    if (s is LogicStructure && s.elements.isNotEmpty) {
      return [
        for (final e in s.elements)
          for (final (i, a) in bits(e).indexed) a.from(e, i),
      ];
    }
    final src = s.srcConnection;
    if (src != null) {
      return [for (final (i, a) in bits(src).indexed) a.from(src, i)];
    }
    if (m != null && s.isOutput && m.subModules.isEmpty) return _leaf(m, s);
    // An undriven signal has no logic in front of it.
    if (s.value.isValid) return List.filled(w, _Arrival.constant);
    return List.filled(w, _Arrival.source);
  }

  List<_Arrival> _leaf(Module leaf, Logic out) {
    final w = out.width;
    if (leaf is Sequential || leaf is FlipFlop) {
      return List.filled(w, _Arrival.source);
    }
    if (leaf is BusSubset) {
      final i = leaf.original;
      final b = bits(i);
      if (i.width == 1) return [b.first.from(i, 0)];
      final step = leaf.startIndex <= leaf.endIndex ? 1 : -1;
      return [
        for (var k = 0; k < w; k++)
          b[leaf.startIndex + step * k].from(i, leaf.startIndex + step * k),
      ];
    }
    if (leaf is Concat) {
      return [
        for (final p in leaf.inputs.values)
          for (final (i, a) in bits(p).indexed) a.from(p, i),
      ];
    }
    if (leaf is ReplicationOp) {
      final p = leaf.inputs.values.first;
      final b = bits(p);
      return [for (var k = 0; k < w; k++) b[k % p.width].from(p, k % p.width)];
    }
    return List.filled(w, _cell(leaf));
  }

  // A cell whose output bits all depend on its input bits as a whole.
  _Arrival _cell(Module leaf) {
    final cost = harborGateLevels(leaf);
    if (_isRam(leaf)) {
      final addr = leaf.input('rd_addr');
      return _closed([(worst(addr), addr)], cost);
    }
    final ins = [for (final p in leaf.inputs.values) (worst(p), p)];
    if (leaf is Add || leaf is Subtract) {
      final ops = [
        for (final o in _operands(leaf))
          if (!worst(o).isConstant) (worst(o), o),
      ];
      if (ops.isEmpty) return _Arrival.constant;
      final w = leaf.outputs.values.first.width;
      return _closed(ops, _log3(max(2, ops.length)) + (w + 15) ~/ 16);
    }
    if (_isGate(leaf)) {
      // A reduction or an equality takes every bit of its inputs, a bitwise
      // gate one bit of each input.
      final perBit =
          leaf is AndUnary ||
          leaf is OrUnary ||
          leaf is XorUnary ||
          leaf is Equals ||
          leaf is NotEquals;
      return _pack([
        for (final (a, p) in ins)
          (
            _Arrival(
              a.level,
              perBit ? a.fill * p.width : a.fill,
              a.via,
              a.viaBit,
            ),
            p,
          ),
      ]);
    }
    if (leaf is LShift || leaf is RShift || leaf is ARShift) {
      final (data, _) = ins.first;
      final amount = ins.skip(1).toList();
      if (amount.every((i) => i.$1.isConstant)) return data;
      if (data.isConstant) {
        return _pack([
          for (final (a, p) in amount)
            (_Arrival(a.level, a.fill * p.width, a.via, a.viaBit), p),
        ]);
      }
    }
    return _closed(ins, cost);
  }

  bool _isAdder(Module? m) =>
      m != null && m.subModules.isEmpty && (m is Add || m is Subtract);

  // The driver of [s] through wires, a zero or sign extension, or a Concat
  // with one live input, where each wire on the way has one consumer.
  Logic _through(Logic s) {
    var src = s;
    for (;;) {
      final up = src.srcConnection;
      if (up != null) {
        src = up;
        continue;
      }
      final m = src.parentModule;
      if (src.isOutput && m is Concat && _consumers(src) == 1) {
        final live = [
          for (final p in m.inputs.values)
            if (!worst(p).isConstant) p,
        ];
        if (live.length == 1) {
          src = live.single;
          continue;
        }
      }
      return src;
    }
  }

  // The operands of the adder tree that ends at [leaf]. An inner Add or
  // Subtract whose result goes only to the next one adds its operands.
  List<Logic> _operands(Module leaf) {
    final out = <Logic>[];
    for (final p in leaf.inputs.values) {
      final src = _through(p);
      final m = src.parentModule;
      if (src.isOutput && _isAdder(m) && _consumers(src) == 1) {
        out.addAll(_operands(m!));
      } else {
        out.add(p);
      }
    }
    return out;
  }

  // The number of leaf inputs and root outputs that [s] drives.
  int _consumers(Logic s) {
    var n = 0;
    final todo = [...s.dstConnections];
    while (todo.isNotEmpty) {
      final d = todo.removeLast();
      final m = d.parentModule;
      if (d.isInput && m != null && m.subModules.isEmpty) {
        n++;
      } else if (d.isOutput && m == root) {
        n++;
      } else {
        todo.addAll(d.dstConnections);
      }
    }
    return n;
  }

  // Ends a LUT: the output is full at the latest input plus [cost].
  _Arrival _closed(List<_In> ins, int cost) {
    final live = ins.where((i) => !i.$1.isConstant).toList();
    if (live.isEmpty) return _Arrival.constant;
    final a = _latest(live);
    return _Arrival(a.level + cost, 1, a.via, a.viaBit);
  }

  // Packs the inputs into the fewest LUT levels: the first level `t` at
  // which the Kraft sum of the inputs is at most 1.
  _Arrival _pack(List<_In> ins) {
    final live = ins.where((i) => !i.$1.isConstant).toList();
    if (live.isEmpty) return _Arrival.constant;
    final a = _latest(live);
    for (var t = a.level; ; t++) {
      var sum = 0.0;
      for (final (b, _) in live) {
        sum += b.fillAt(t);
      }
      if (sum <= 1 + 1e-9) return _Arrival(t, sum, a.via, a.viaBit);
    }
  }

  bool _later(_Arrival x, _Arrival y) =>
      x.level > y.level || (x.level == y.level && x.fill > y.fill);

  _Arrival _latest(List<_In> ins) =>
      ins.map((i) => i.$1).reduce((x, y) => _later(y, x) ? y : x);

  List<Logic> path(Logic end, int bit) {
    final out = <Logic>[];
    Logic? s = end;
    var b = bit;
    while (s != null) {
      out.add(s);
      final a = bits(s)[b];
      s = a.via;
      b = a.viaBit;
    }
    return out.reversed.toList();
  }
}

/// The ends of paths inside [root]: the inputs of Sequential, FlipFlop and
/// RAM write ports, and the outputs of [root].
List<Logic> _endPoints(Module root) {
  final ends = <Logic>[...root.outputs.values];
  void visit(Module m) {
    if (m.subModules.isEmpty) {
      if (m is Sequential || m is FlipFlop) {
        ends.addAll(m.inputs.values);
      } else if (_isRam(m)) {
        ends.addAll([m.input('wr_en'), m.input('wr_addr'), m.input('wr_data')]);
      }
      return;
    }
    m.subModules.forEach(visit);
  }

  visit(root);
  return ends;
}

/// Worst combinational path between sequential elements inside [root],
/// in LUT6-equivalent levels.
///
/// A path starts at an input of [root], a Sequential or FlipFlop output, or
/// a constant. It ends at an output of [root], a Sequential or FlipFlop
/// input, or a RAM write port. A RAM read goes on from its address to its
/// data. Wires keep the arrival of each bit apart. Cells cost as
/// [harborGateLevels] gives, except that AND, OR, XOR, NOT and equality
/// cells pack into shared LUT6 levels, and a tree of Add and Subtract cells
/// counts as one adder of all its operands. [root] must be built.
HarborDepthPath harborWorstDepth(Module root) {
  final w = _Walker(root);
  Logic? worst;
  var bit = 0;
  var levels = -1;
  for (final end in _endPoints(root)) {
    final b = w.bits(end);
    for (var i = 0; i < b.length; i++) {
      if (b[i].level > levels) {
        levels = b[i].level;
        worst = end;
        bit = i;
      }
    }
  }
  if (worst == null) return const HarborDepthPath(0, []);
  return HarborDepthPath(levels, w.path(worst, bit));
}
