import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Drives [update] high for one rising edge of [clk], as a register block
/// does after a write.
void pulseUpdate(Logic update, Logic clk) {
  update.inject(1);
  unawaited(clk.nextPosedge.then((_) => update.inject(0)));
}

bool _high(Logic s) {
  final v = s.previousValue ?? s.value;
  return v.isValid && v.toBool();
}

int _prev(Logic s) => (s.previousValue ?? s.value).toInt();

/// A read only memory model on the slave side of a memory master waist.
///
/// It takes up to [depth] requests. The first beat of a request comes
/// [latency] cycles after the take, then one beat each cycle, in request
/// order. A beat returns [data] of its byte address, the address itself by
/// default. Peak bandwidth is one 32-bit beat each cycle.
class WaistMemory {
  final HarborMemoryWaist waist;

  /// Cycles from a take to the first beat, for requests taken from now on.
  int latency;
  final int depth;
  final int Function(int addr) data;

  /// Every request taken as (byte address, beats).
  final requests = <(int, int)>[];

  final _queue = <(int, int, int)>[];
  int _beat = 0;
  int _cycle = 0;
  bool _ready = false;
  bool _valid = false;

  WaistMemory(
    this.waist,
    Logic clk, {
    this.latency = 0,
    this.depth = 4,
    int Function(int addr)? data,
  }) : data = data ?? ((a) => a) {
    waist.reqReady.inject(0);
    waist.rdataValid.inject(0);
    waist.rdataData.inject(0);
    waist.rdataLast.inject(0);
    waist.rdataId.inject(0);
    waist.rdataErr.inject(0);
    waist.rdataExOkay.inject(0);
    waist.wdataReady.inject(0);
    waist.wrespValid.inject(0);
    waist.wrespId.inject(0);
    waist.wrespErr.inject(0);
    waist.wrespExOkay.inject(0);
    clk.posedge.listen((_) => _edge());
    clk.negedge.listen((_) => _drive());
  }

  void _edge() {
    _cycle++;
    if (_valid && _high(waist.rdataReady)) {
      _beat++;
      if (_beat == _queue.first.$2) {
        _queue.removeAt(0);
        _beat = 0;
      }
    }
    if (_ready && _high(waist.reqValid)) {
      final r = (_prev(waist.reqAddr), _prev(waist.reqLen) + 1);
      requests.add(r);
      _queue.add((r.$1, r.$2, _cycle + latency));
    }
  }

  void _drive() {
    _ready = _queue.length < depth;
    waist.reqReady.inject(_ready ? 1 : 0);
    _valid = _queue.isNotEmpty && _cycle >= _queue.first.$3;
    waist.rdataValid.inject(_valid ? 1 : 0);
    if (_valid) {
      final (addr, beats, _) = _queue.first;
      waist.rdataData.inject(data(addr + 4 * _beat) & 0xffffffff);
      waist.rdataLast.inject(_beat == beats - 1 ? 1 : 0);
    }
  }
}

/// A model of a scanout port (`rq_*`, `rd_*`) such as a [HarborSdram]
/// scanout port.
///
/// It takes a request on any cycle. The first 16-bit word comes [latency]
/// cycles after the take, then one word each cycle with no back pressure.
/// Word i of a request at byte address a is the low or high half of
/// [data] of `a + 2 * i` rounded down to 4 bytes.
class PortMemory {
  final Logic rqValid;
  final Logic rqAddr;
  final Logic rqWords;
  final Logic rqReady;
  final Logic rdValid;
  final Logic rdData;

  /// Cycles from a take to the first word, for requests taken from now on.
  int latency;
  final int Function(int addr) data;

  /// Every request taken as (byte address, 16-bit words).
  final requests = <(int, int)>[];

  final _queue = <(int, int, int)>[];
  int _word = 0;
  int _cycle = 0;

  PortMemory({
    required this.rqValid,
    required this.rqAddr,
    required this.rqWords,
    required this.rqReady,
    required this.rdValid,
    required this.rdData,
    required Logic clk,
    this.latency = 4,
    int Function(int addr)? data,
  }) : data = data ?? ((a) => a) {
    rqReady.inject(1);
    rdValid.inject(0);
    rdData.inject(0);
    clk.posedge.listen((_) => _edge());
    clk.negedge.listen((_) => _drive());
  }

  void _edge() {
    _cycle++;
    if (_high(rqValid)) {
      final r = (_prev(rqAddr), _prev(rqWords));
      requests.add(r);
      _queue.add((r.$1, r.$2, _cycle + latency));
    }
  }

  void _drive() {
    final valid = _queue.isNotEmpty && _cycle >= _queue.first.$3;
    rdValid.inject(valid ? 1 : 0);
    if (!valid) return;
    final (addr, words, _) = _queue.first;
    final a = addr + 2 * _word;
    final w = data(a & ~3) & 0xffffffff;
    rdData.inject(a & 2 == 0 ? w & 0xffff : w >> 16);
    _word++;
    if (_word == words) {
      _queue.removeAt(0);
      _word = 0;
    }
  }
}

/// Checks that chroma line n starts only after all of luma line 2n - 1,
/// the luma line fetched at the same line start, was requested.
///
/// Each request is (byte address, bytes). A luma line is [lineBytes0]
/// bytes. A request at [luma] starts a new frame.
void expectLumaFirst(
  Iterable<(int, int)> requests, {
  required int luma,
  required int chroma,
  required int pitch0,
  required int pitch1,
  required int lineBytes0,
}) {
  final got = <int, int>{};
  var chromaLines = 0;
  for (final (a, n) in requests) {
    if (a == luma) got.clear();
    if (a >= chroma) {
      final c = (a - chroma) ~/ pitch1;
      if (c == 0) continue;
      expect(got[2 * c - 1], lineBytes0, reason: 'chroma line $c before luma');
      chromaLines++;
    } else {
      final y = (a - luma) ~/ pitch0;
      got[y] = (got[y] ?? 0) + n;
    }
  }
  expect(chromaLines, greaterThan(0));
}
