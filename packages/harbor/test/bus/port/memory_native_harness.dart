import 'dart:collection';
import 'dart:math';

import 'package:rohd/rohd.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

/// Value of [port] now, or null when it is not a valid number.
int? now(Sim s, String port) {
  final v = (s.dut.tryOutput(port) ?? s.dut.input(port).srcConnection!).value;
  return v.isValid ? v.toInt() : null;
}

int log2(int v) => v.bitLength - 1;

/// Byte lanes a beat of `2^size` bytes at [addr] covers, as the ports
/// compute it: the lanes of the size aligned block that holds [addr].
int laneMask(int addr, int size, int busBytes) {
  final all = (1 << busBytes) - 1;
  if ((1 << size) >= busBytes) return all;
  final bytes = 1 << size;
  final base = (addr % busBytes) & ~(bytes - 1);
  return ((1 << bytes) - 1) << base;
}

// ---------------------------------------------------------------------------
// TileLink

const tlGet = 4;
const tlPutFull = 0;
const tlPutPartial = 1;
const tlArithmetic = 2;
const tlLogical = 3;
const tlIntent = 5;
const tlAcquire = 6;
const tlAccessAck = 0;
const tlAccessAckData = 1;
const tlHintAck = 2;

/// Beats of a TileLink message of [size] that carries data.
int tlBeats(int size, int busBytes) =>
    (1 << size) > busBytes ? (1 << size) ~/ busBytes : 1;

/// A beat on D as (opcode, size, source, data, denied, corrupt).
typedef DBeat = (int, int, int, int, int, int);

/// One TileLink A message and the D beats that answered it.
class TlMsg {
  final int op;
  final int size;
  int source;
  final int addr;
  final List<int> data;
  final List<int> mask;
  final List<int> corrupt;
  final List<DBeat> d = [];

  TlMsg({
    required this.op,
    required this.size,
    required this.addr,
    this.source = 0,
    this.data = const [0],
    this.mask = const [0],
    List<int>? corrupt,
  }) : corrupt = corrupt ?? List.filled(data.length, 0);

  bool get isPut => op == tlPutFull || op == tlPutPartial;
  bool get carriesData => op <= tlLogical;

  /// D beats a full answer has.
  int dBeats(int busBytes) =>
      op == tlGet || op == tlArithmetic || op == tlLogical
      ? tlBeats(size, busBytes)
      : 1;

  @override
  String toString() =>
      'TL(op $op size $size src $source addr 0x${addr.toRadixString(16)} '
      'beats ${data.length})';
}

/// A TileLink manager on the ports `<p>_*` of a slave. A message goes on A
/// once a free source is found, and holds that source until its last D
/// beat.
class TlManager {
  final Sim s;
  final String p;
  final Random rng;
  final int sources;
  final List<String> errors;
  late final Source a;
  late final Sink d;
  final Queue<TlMsg> pending = Queue();
  final List<TlMsg> sent = [];
  final Map<int, TlMsg> inflight = {};
  final int busBytes;
  TlMsg? _dCur;

  TlManager(
    this.s,
    this.p,
    this.rng, {
    required this.sources,
    required this.busBytes,
    required this.errors,
    double idle = 0.2,
    double stall = 0.3,
  }) {
    a = Source(s, '${p}_A_VALID', '${p}_A_READY', rng, idle: idle);
    d = Sink(
      s,
      '${p}_D_VALID',
      '${p}_D_READY',
      [
        for (final f in [
          'OPCODE',
          'SIZE',
          'SOURCE',
          'DATA',
          'DENIED',
          'CORRUPT',
        ])
          '${p}_D_$f',
      ],
      rng,
      _onD,
      stall: stall,
      latchOnFall: true,
    );
    s.onFall(_feed);
  }

  void send(TlMsg m) => pending.add(m);

  void _feed() {
    if (pending.isEmpty || a.queue.isNotEmpty) return;
    final free = [
      for (var i = 0; i < sources; i++)
        if (!inflight.containsKey(i)) i,
    ];
    if (free.isEmpty) return;
    final m = pending.removeFirst();
    m.source = free[rng.nextInt(free.length)];
    inflight[m.source] = m;
    sent.add(m);
    for (var i = 0; i < m.data.length; i++) {
      a.queue.add({
        '${p}_A_OPCODE': m.op,
        '${p}_A_PARAM': 0,
        '${p}_A_SIZE': m.size,
        '${p}_A_SOURCE': m.source,
        '${p}_A_ADDRESS': m.addr,
        '${p}_A_MASK': m.mask[i],
        '${p}_A_DATA': m.data[i],
        '${p}_A_CORRUPT': m.corrupt[i],
      });
    }
  }

  void _onD(Map<String, int> f) {
    final src = f['${p}_D_SOURCE']!;
    final m = inflight[src];
    if (m == null) {
      errors.add('D for source $src with nothing in flight');
      return;
    }
    if (_dCur != null && _dCur != m) {
      errors.add('D beats of two messages interleave');
    }
    _dCur = m;
    m.d.add((
      f['${p}_D_OPCODE']!,
      f['${p}_D_SIZE']!,
      src,
      f['${p}_D_DATA']!,
      f['${p}_D_DENIED']!,
      f['${p}_D_CORRUPT']!,
    ));
    final want = m.d.first.$1 == tlAccessAckData
        ? tlBeats(m.d.first.$2, busBytes)
        : 1;
    if (m.d.length == want) {
      inflight.remove(src);
      _dCur = null;
    }
  }

  bool get done => pending.isEmpty && inflight.isEmpty && a.idleNow;
}

/// Random TileLink-UH messages for a slave port on a bus of [busBytes].
class TlGen {
  final Random rng;
  final int busBytes;
  final int span;
  final int errBase;
  final double errors;
  final double denied;
  final double long;

  TlGen(
    this.rng, {
    required this.busBytes,
    this.span = 0x2000,
    this.errBase = 0xf000,
    this.errors = 0.05,
    this.denied = 0.1,
    this.long = 0.03,
  });

  int get beatLog2 => log2(busBytes);

  int _data() => busBytes == 8
      ? (rng.nextInt(1 << 32) << 32) | rng.nextInt(1 << 32)
      : rng.nextInt(1 << (busBytes * 8));

  int _addr(int size) {
    var a = rng.nextInt(span) & ~((1 << size) - 1);
    if (rng.nextDouble() < errors) {
      a = errBase + (rng.nextInt(0x800) & ~((1 << size) - 1));
    }
    return a;
  }

  TlMsg _put(int op, int size, int addr, {bool partial = false}) {
    final n = tlBeats(size, busBytes);
    final lanes = laneMask(addr, size, busBytes);
    return TlMsg(
      op: op,
      size: size,
      addr: addr,
      data: [for (var i = 0; i < n; i++) _data()],
      mask: [
        for (var i = 0; i < n; i++)
          partial ? lanes & rng.nextInt(1 << busBytes) : lanes,
      ],
    );
  }

  /// A legal Get, PutFullData or PutPartialData.
  TlMsg legal({int? op}) {
    final size = rng.nextDouble() < long
        ? beatLog2 + 8
        : rng.nextInt(beatLog2 + 5);
    final addr = _addr(size);
    final o = op ?? [tlGet, tlGet, tlPutFull, tlPutPartial][rng.nextInt(4)];
    if (o == tlGet) {
      return TlMsg(
        op: tlGet,
        size: size,
        addr: addr,
        mask: [laneMask(addr, size, busBytes)],
      );
    }
    return _put(o, size, addr, partial: o == tlPutPartial);
  }

  /// A message the slave port denies.
  TlMsg deniedMsg() {
    final size = rng.nextInt(beatLog2 + 3);
    final addr = _addr(size);
    switch (rng.nextInt(7)) {
      case 0:
        return _put(tlArithmetic, size, addr);
      case 1:
        return _put(tlLogical, size, addr);
      case 2:
        return TlMsg(op: tlIntent, size: size, addr: addr);
      case 3:
        return TlMsg(op: tlAcquire, size: size, addr: addr);
      case 4:
        // Larger than 256 beats.
        final big = beatLog2 + 9;
        return rng.nextBool()
            ? TlMsg(op: tlGet, size: big, addr: 0, mask: [(1 << busBytes) - 1])
            : _put(tlPutFull, big, 0);
      default:
        // Not aligned to its size.
        final s = beatLog2 + 1 + rng.nextInt(2);
        final bad = (addr & ~((1 << s) - 1)) + busBytes;
        return rng.nextBool()
            ? TlMsg(op: tlGet, size: s, addr: bad, mask: [(1 << busBytes) - 1])
            : _put(tlPutFull, s, bad);
    }
  }

  TlMsg next() => rng.nextDouble() < denied ? deniedMsg() : legal();

  /// True when the slave port takes [m] to the waist.
  bool isLegal(TlMsg m) =>
      (m.op == tlGet || m.isPut) &&
      m.size <= beatLog2 + 8 &&
      m.addr % (1 << m.size) == 0;
}

/// The memory after the legal Puts of [msgs] below [errBase], in order.
WordMemory tlGolden(
  List<TlMsg> msgs,
  int busBytes,
  bool Function(TlMsg) legal, {
  int errBase = 0xf000,
}) {
  final m = WordMemory(busBytes);
  for (final x in msgs) {
    if (!x.isPut || !legal(x) || x.addr >= errBase) continue;
    for (var i = 0; i < x.data.length; i++) {
      if (x.corrupt[i] == 1) continue;
      m.write(x.addr + i * busBytes, x.data[i], x.mask[i]);
    }
  }
  return m;
}

/// A TileLink-UH memory on the ports `<p>_*` of a master.
///
/// Checks each A message against the TileLink rules: one message per
/// source in flight, an address aligned to the size, a Get mask of every
/// lane of the size, Put masks inside the lanes, and the same opcode, size,
/// source and address on every beat. Answers sources out of order. A
/// request from [errBase] is denied, and a Get from `errBase + 0x800` gets
/// corrupt data without denied.
class TlMemory {
  final Sim s;
  final String p;
  final Random rng;
  final int busBytes;
  final int errBase;
  final List<String> errors;
  final WordMemory mem;
  late final Sink a;
  late final Source d;
  final List<TlMsg> msgs = [];
  final List<(TlMsg, List<DBeat>)> _pend = [];
  final Set<int> _inflight = {};
  int maxInflight = 0;
  TlMsg? _cur;
  final List<int> _curData = [];
  final List<int> _curMask = [];

  /// Stops D from going out.
  bool holdResponses = false;

  /// Answered first whenever it is pending.
  int? preferSource;

  TlMemory(
    this.s,
    this.p,
    this.rng, {
    required this.busBytes,
    required this.errors,
    this.errBase = 0xf000,
    double stall = 0.3,
  }) : mem = WordMemory(busBytes) {
    a = Sink(
      s,
      '${p}_A_VALID',
      '${p}_A_READY',
      [
        for (final f in [
          'OPCODE',
          'SIZE',
          'SOURCE',
          'ADDRESS',
          'MASK',
          'DATA',
          'CORRUPT',
        ])
          '${p}_A_$f',
      ],
      rng,
      _onA,
      stall: stall,
      latchOnFall: true,
    );
    d = Source(s, '${p}_D_VALID', '${p}_D_READY', rng, idle: stall)
      ..onFire = (f) {
        final src = f['${p}_D_SOURCE']!;
        final left = _left[src]! - 1;
        _left[src] = left;
        if (left == 0) _inflight.remove(src);
      };
    s.onFall(_feed);
  }

  final Map<int, int> _left = {};

  void _onA(Map<String, int> f) {
    int g(String n) => f['${p}_A_$n']!;
    if (_cur == null) {
      final m = TlMsg(
        op: g('OPCODE'),
        size: g('SIZE'),
        addr: g('ADDRESS'),
        source: g('SOURCE'),
      );
      if (_inflight.contains(m.source)) {
        errors.add('source ${m.source} reused while in flight');
      }
      if (m.addr % (1 << m.size) != 0) errors.add('$m not aligned');
      _cur = m;
      _curData.clear();
      _curMask.clear();
    } else {
      final m = _cur!;
      if (g('OPCODE') != m.op ||
          g('SIZE') != m.size ||
          g('SOURCE') != m.source ||
          g('ADDRESS') != m.addr) {
        errors.add('A fields changed inside $m');
      }
    }
    final m = _cur!;
    final lanes = laneMask(m.addr, m.size, busBytes);
    final mask = g('MASK');
    if (m.op == tlGet && mask != lanes) errors.add('Get mask $mask in $m');
    if (m.isPut && mask & ~lanes != 0) errors.add('Put mask $mask in $m');
    if (m.op == tlPutFull && mask != lanes) {
      errors.add('PutFullData mask $mask in $m');
    }
    if (g('CORRUPT') != 0) errors.add('a_corrupt set in $m');
    _curData.add(g('DATA'));
    _curMask.add(mask);
    final beats = m.isPut ? tlBeats(m.size, busBytes) : 1;
    if (_curData.length < beats) return;

    final done = TlMsg(
      op: m.op,
      size: m.size,
      addr: m.addr,
      source: m.source,
      data: List.of(_curData),
      mask: List.of(_curMask),
    );
    _cur = null;
    msgs.add(done);
    _inflight.add(done.source);
    maxInflight = max(maxInflight, _inflight.length);
    final region = done.addr < errBase
        ? 0
        : done.addr < errBase + 0x800
        ? 1
        : 2;
    final List<DBeat> resp;
    if (done.op == tlGet) {
      final n = tlBeats(done.size, busBytes);
      final denied = region == 1 ? 1 : 0;
      final corrupt = region == 0 ? 0 : 1;
      resp = [
        for (var i = 0; i < n; i++)
          (
            tlAccessAckData,
            done.size,
            done.source,
            region == 0 ? mem.read(done.addr + i * busBytes) : 0,
            denied,
            corrupt,
          ),
      ];
    } else {
      if (region == 0) {
        for (var i = 0; i < done.data.length; i++) {
          mem.write(done.addr + i * busBytes, done.data[i], done.mask[i]);
        }
      }
      resp = [(tlAccessAck, done.size, done.source, 0, region == 0 ? 0 : 1, 0)];
    }
    _pend.add((done, resp));
  }

  void _feed() {
    if (holdResponses || d.queue.isNotEmpty || _pend.isEmpty) return;
    var i = rng.nextInt(_pend.length);
    if (preferSource != null) {
      final k = _pend.indexWhere((e) => e.$1.source == preferSource);
      if (k != -1) i = k;
    }
    final (m, resp) = _pend.removeAt(i);
    m.d.addAll(resp);
    _left[m.source] = resp.length;
    for (final b in resp) {
      d.queue.add({
        '${p}_D_OPCODE': b.$1,
        '${p}_D_PARAM': 0,
        '${p}_D_SIZE': b.$2,
        '${p}_D_SOURCE': b.$3,
        '${p}_D_SINK': 0,
        '${p}_D_DATA': b.$4,
        '${p}_D_DENIED': b.$5,
        '${p}_D_CORRUPT': b.$6,
      });
    }
  }
}

/// The TileLink messages the master port sends for [b], by its rules.
List<TlMsg> tlExpect(Burst b, int busBytes) {
  final bl = log2(busBytes);
  final n = b.len + 1;
  final pow2 = n & (n - 1) == 0;
  final whole =
      b.len == 0 ||
      (b.burst != 0 && b.size == bl && pow2 && b.addr % (n * busBytes) == 0);
  final piece = min(b.size, bl);
  int put(int strb, int lanes, bool single) =>
      single && strb & lanes == lanes ? tlPutFull : tlPutPartial;
  if (whole) {
    final size = b.len == 0 ? piece : bl + log2(n);
    final addr = b.addr & ~((1 << size) - 1);
    final lanes = laneMask(b.addr, piece, busBytes);
    return [
      TlMsg(
        op: b.write ? put(b.strb[0], lanes, b.len == 0) : tlGet,
        size: size,
        addr: addr,
        source: b.id,
        data: b.write ? b.data : const [0],
        mask: b.write ? [for (final x in b.strb) x & lanes] : [lanes],
      ),
    ];
  }
  final addrs = beatAddrs(b.addr, b.len, b.size, b.burst);
  return [
    for (var i = 0; i < n; i++)
      () {
        final lanes = laneMask(addrs[i], piece, busBytes);
        return TlMsg(
          op: b.write ? put(b.strb[i], lanes, true) : tlGet,
          size: piece,
          addr: addrs[i] & ~((1 << piece) - 1),
          source: b.id,
          data: b.write ? [b.data[i]] : const [0],
          mask: b.write ? [b.strb[i] & lanes] : [lanes],
        );
      }(),
  ];
}

/// Mismatches between the A side fields of two messages.
String? diffTl(TlMsg want, TlMsg got) {
  final ok =
      want.op == got.op &&
      want.size == got.size &&
      want.addr == got.addr &&
      want.source == got.source &&
      want.mask.toString() == got.mask.toString() &&
      (!want.isPut || want.data.toString() == got.data.toString());
  return ok ? null : 'A message $got ${got.mask}, want $want ${want.mask}';
}

// ---------------------------------------------------------------------------
// Wishbone

/// One beat a Wishbone master runs.
class WbBeat {
  final int addr;
  final int data;
  final int sel;
  int ack = 0;
  int err = 0;
  int rdata = 0;

  WbBeat(this.addr, {this.data = 0, this.sel = 0});

  @override
  String toString() =>
      'beat(0x${addr.toRadixString(16)} ack $ack err $err '
      'rdata 0x${rdata.toRadixString(16)})';
}

enum WbMode { classic, burst, wrap4 }

/// One Wishbone bus cycle a master runs.
class WbTxn {
  final bool write;
  final WbMode mode;
  final List<WbBeat> beats;

  /// Drop CYC after this many beats, before the end.
  final int? abortAfter;

  /// Drop CYC when a beat waits this many cycles for its answer.
  final int? giveUpAfter;

  /// Beats that ended, with ACK or ERR.
  int done = 0;

  /// Use CTI 111 on a classic cycle instead of 000.
  final bool classicEnd;

  /// The master dropped CYC while a beat waited.
  bool gaveUp = false;

  WbTxn(
    this.write,
    this.mode,
    this.beats, {
    this.abortAfter,
    this.giveUpAfter,
    this.classicEnd = false,
  });

  @override
  String toString() =>
      'WB(${write ? 'W' : 'R'} $mode ${beats.length} beats '
      'abort $abortAfter done $done)';
}

/// A Wishbone master on the ports `<p>_*` of a slave with registered
/// feedback bursts. Runs [WbTxn]s in order. Inserts STB wait states inside
/// bursts with chance [gap], and holds CYC from one cycle to the next with
/// chance [keepCyc].
class WbMaster {
  final Sim s;
  final String p;
  final Random rng;
  final double gap;
  final double keepCyc;
  final Queue<WbTxn> queue = Queue();
  final List<WbTxn> finished = [];
  WbTxn? _cur;
  bool _stb = false;
  int _idle = 0;
  int _waited = 0;
  bool _keep = false;

  /// Called when a beat ends, in order.
  void Function(WbTxn txn, WbBeat beat)? onBeat;

  WbMaster(this.s, this.p, this.rng, {this.gap = 0.2, this.keepCyc = 0.3}) {
    s.onRise(_rise);
    s.onFall(_fall);
  }

  void _rise() {
    final t = _cur;
    if (t == null || !_stb) return;
    final ack = s.pre('${p}_ACK');
    final err = s.dut.tryOutput('${p}_ERR') == null ? 0 : s.pre('${p}_ERR');
    _waited++;
    if (ack == 1 || err == 1) {
      final b = t.beats[t.done];
      b.ack = ack;
      b.err = err;
      b.rdata = s.pre('${p}_DAT_MISO');
      t.done++;
      _waited = 0;
      onBeat?.call(t, b);
      if (err == 1 ||
          t.done == t.beats.length ||
          (t.abortAfter != null && t.done == t.abortAfter)) {
        _finish(err == 0 && t.done == t.beats.length);
      }
    } else if (t.giveUpAfter != null && _waited >= t.giveUpAfter!) {
      t.gaveUp = true;
      _finish(false);
    }
  }

  void _finish(bool clean) {
    finished.add(_cur!);
    _cur = null;
    _waited = 0;
    _keep = clean && rng.nextDouble() < keepCyc;
    _idle = _keep ? 0 : 1 + rng.nextInt(2);
  }

  void _fall() {
    if (_cur == null && _idle > 0) {
      _idle--;
      s.set('${p}_CYC', 0);
      s.set('${p}_STB', 0);
      return;
    }
    if (_cur == null && queue.isNotEmpty) {
      _cur = queue.removeFirst();
    }
    final t = _cur;
    if (t == null) {
      s.set('${p}_CYC', _keep && queue.isNotEmpty ? 1 : 0);
      s.set('${p}_STB', 0);
      return;
    }
    final b = t.beats[t.done];
    final inBurst = t.mode != WbMode.classic && t.done > 0;
    _stb = !(inBurst && _waited == 0 && rng.nextDouble() < gap);
    final lastBeat = t.done == t.beats.length - 1;
    s.set('${p}_CYC', 1);
    s.set('${p}_STB', _stb ? 1 : 0);
    s.set('${p}_WE', t.write ? 1 : 0);
    s.set('${p}_ADR', b.addr);
    s.set('${p}_DAT_MOSI', b.data);
    s.set('${p}_SEL', b.sel);
    if (s.dut.inputs.containsKey('${p}_CTI')) {
      s.set(
        '${p}_CTI',
        t.mode == WbMode.classic
            ? (t.classicEnd ? 7 : 0)
            : lastBeat
            ? 7
            : 2,
      );
      s.set('${p}_BTE', t.mode == WbMode.wrap4 ? 1 : 0);
    }
  }

  bool get done => _cur == null && queue.isEmpty;
}

/// A Wishbone memory on the ports `<p>_*` of a master. Answers each beat
/// after a random wait. Beats from [errBase] get ERR. Groups the beats it
/// answers by CYC.
class WbMemory {
  final Sim s;
  final String p;
  final Random rng;
  final int errBase;
  final double wait;
  final WordMemory mem;
  final List<List<Map<String, int>>> sessions = [];
  bool _inCyc = false;
  bool _answering = false;

  /// Stops all answers.
  bool hold = false;

  WbMemory(
    this.s,
    this.p,
    this.rng, {
    required int busBytes,
    this.errBase = 0xf000,
    this.wait = 0.3,
  }) : mem = WordMemory(busBytes) {
    final hasErr = s.dut.inputs.containsKey('${p}_ERR');
    s.onRise(() {
      final cyc = s.pre('${p}_CYC');
      if (cyc == 1 && !_inCyc) sessions.add([]);
      _inCyc = cyc == 1;
      if (_answering && cyc == 1 && s.pre('${p}_STB') == 1) {
        final f = {
          for (final n in ['WE', 'ADR', 'SEL', 'CTI', 'BTE', 'DAT_MOSI'])
            n: s.dut.tryOutput('${p}_$n') == null ? 0 : s.pre('${p}_$n'),
          'ACK': s.pre('${p}_ACK'),
          'ERR': hasErr ? s.pre('${p}_ERR') : 0,
          'DAT_MISO': s.pre('${p}_DAT_MISO'),
        };
        if (f['ACK'] == 1 && f['WE'] == 1) {
          mem.write(f['ADR']!, f['DAT_MOSI']!, f['SEL']!);
        }
        sessions.last.add(f);
      }
    });
    // Answers one time unit after the falling edge, so a request a test
    // master drove at that edge through combinational logic has settled.
    s.onFall(
      () => Simulator.registerAction(Simulator.time + 1, () {
        final cyc = now(s, '${p}_CYC') == 1 && now(s, '${p}_STB') == 1;
        _answering = cyc && !hold && rng.nextDouble() >= wait;
        final adr = _answering ? now(s, '${p}_ADR')! : 0;
        final err = _answering && adr >= errBase;
        s.set('${p}_ACK', _answering && !err ? 1 : 0);
        if (hasErr) s.set('${p}_ERR', err ? 1 : 0);
        s.set('${p}_DAT_MISO', _answering && !err ? mem.read(adr) : 0);
      }),
    );
  }
}
