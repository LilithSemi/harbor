import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

const _fromPort = [
  ('req_valid', 'REQ_VALID'),
  ('req_id', 'REQ_ID'),
  ('req_write', 'REQ_WRITE'),
  ('req_addr', 'REQ_ADDR'),
  ('req_len', 'REQ_LEN'),
  ('req_size', 'REQ_SIZE'),
  ('req_burst', 'REQ_BURST'),
  ('wdata_valid', 'WDATA_VALID'),
  ('wdata_data', 'WDATA_DATA'),
  ('wdata_strb', 'WDATA_STRB'),
  ('wdata_last', 'WDATA_LAST'),
  ('rdata_ready', 'RDATA_READY'),
  ('wresp_ready', 'WRESP_READY'),
];

const _toPort = [
  ('req_ready', 'REQ_READY'),
  ('wdata_ready', 'WDATA_READY'),
  ('rdata_valid', 'RDATA_VALID'),
  ('rdata_id', 'RDATA_ID'),
  ('rdata_data', 'RDATA_DATA'),
  ('rdata_err', 'RDATA_ERR'),
  ('rdata_last', 'RDATA_LAST'),
  ('rdata_exokay', 'RDATA_EXOKAY'),
  ('wresp_valid', 'WRESP_VALID'),
  ('wresp_id', 'WRESP_ID'),
  ('wresp_err', 'WRESP_ERR'),
  ('wresp_exokay', 'WRESP_EXOKAY'),
];

/// A memory slave port of [kind] with its slave waist on plain ports `w_*`.
class WaistTarget extends BridgeModule {
  WaistTarget(HarborFabricKind kind, HarborMemoryWaistConfig config)
    : super(
        'WaistTarget_${kind.name}_a${config.addressWidth}'
        '_d${config.dataWidth}_i${config.idWidth}_n${config.outstanding}',
        name: 'waist_target',
      ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final port = HarborMemorySlavePort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    final w = port.waist;
    for (final (name, signal) in _fromPort) {
      final s = w.port(signal);
      addOutput('w_$name', width: s.width) <= s;
    }
    for (final (name, signal) in _toPort) {
      final s = w.port(signal);
      s <= addInput('w_$name', Logic(width: s.width), width: s.width);
    }
  }

  /// Port names to pull up to a parent.
  static Iterable<String> get portNames => [
    for (final (n, _) in [..._fromPort, ..._toPort]) 'w_$n',
  ];
}

/// Byte memory on the `<prefix>*` waist ports of [top], one request at a
/// time and up to one beat per cycle.
///
/// Each ready and valid it drives is high with chance [rate].
class WaistMemory {
  final Module top;
  final Logic clk;
  final String prefix;
  final int busBytes;
  final Map<int, int> bytes;
  final int Function(int address) fill;
  final double rate;
  final Random _random;
  final Map<String, Logic> _in = {};

  // The request in progress.
  bool _busy = false;
  bool _write = false;
  int _id = 0;
  int _addr = 0;
  int _len = 0;
  int _size = 0;
  int _burst = 1;
  int _beat = 0;
  bool _resp = false;
  bool _running = true;

  WaistMemory(
    this.top,
    this.clk, {
    required this.prefix,
    required this.bytes,
    required this.fill,
    required int seed,
    this.rate = 0.9,
  }) : busBytes = top.output('${prefix}wdata_data').width ~/ 8,
       _random = Random(seed) {
    for (final (n, _) in _toPort) {
      final p = top.input('$prefix$n');
      final l = Logic(name: 'tb_$prefix$n', width: p.width);
      p.srcConnection! <= l;
      _in[n] = l;
    }
  }

  int byte(int address) => bytes[address] ?? fill(address);

  int _out(String n) => top.output('$prefix$n').value.toInt();

  bool _high(String n) {
    final v = top.output('$prefix$n').value;
    return v.isValid && v.toBool();
  }

  void _set(String n, Object value) => _in[n]!.inject(value);

  int _beatAddress(int beat) {
    final step = 1 << _size;
    final start = _addr & ~(step - 1);
    if (_burst == HarborMemoryBurst.fixed.value) return _addr;
    if (_burst == HarborMemoryBurst.wrap.value) {
      final span = step * (_len + 1);
      final base = _addr & ~(span - 1);
      return base + ((start - base + beat * step) % span);
    }
    return beat == 0 ? _addr : start + beat * step;
  }

  void _drive() {
    _set('req_ready', !_busy && _random.nextDouble() < rate ? 1 : 0);
    _set(
      'wdata_ready',
      _busy && _write && !_resp && _random.nextDouble() < rate ? 1 : 0,
    );
    final rValid = _busy && !_write && _random.nextDouble() < rate;
    _set('rdata_valid', rValid ? 1 : 0);
    if (_busy && !_write) {
      final base = _beatAddress(_beat) & ~(busBytes - 1);
      var data = BigInt.zero;
      for (var b = 0; b < busBytes; b++) {
        data |= BigInt.from(byte(base + b)) << (8 * b);
      }
      _set('rdata_data', data);
      _set('rdata_last', _beat == _len ? 1 : 0);
    }
    _set('wresp_valid', _resp ? 1 : 0);
  }

  void start() {
    for (final l in _in.values) {
      l.inject(0);
    }
    _run();
  }

  void stop() => _running = false;

  Future<void> _run() async {
    while (_running) {
      _drive();
      await clk.nextNegedge;
      final reqFire = _in['req_ready']!.value.toBool() && _high('req_valid');
      final wFire = _in['wdata_ready']!.value.toBool() && _high('wdata_valid');
      final rFire = _in['rdata_valid']!.value.toBool() && _high('rdata_ready');
      final bFire = _resp && _high('wresp_ready');
      final req = reqFire
          ? (
              _out('req_id'),
              _high('req_write'),
              _out('req_addr'),
              _out('req_len'),
              _out('req_size'),
              _out('req_burst'),
            )
          : null;
      final wLast = wFire && _high('wdata_last');
      if (wFire) {
        final base = _beatAddress(_beat) & ~(busBytes - 1);
        final data = top.output('${prefix}wdata_data').value;
        final strb = _out('wdata_strb');
        for (var b = 0; b < busBytes; b++) {
          if ((strb >> b) & 1 == 1) {
            bytes[base + b] = data.getRange(8 * b, 8 * b + 8).toInt();
          }
        }
      }
      await clk.nextPosedge;
      if (req != null) {
        final (id, write, addr, len, size, burst) = req;
        _id = id;
        _write = write;
        _addr = addr;
        _len = len;
        _size = size;
        _burst = burst;
        _busy = true;
        _beat = 0;
        _set('rdata_id', _id);
        _set('wresp_id', _id);
        _set('rdata_err', 0);
        _set('rdata_exokay', 0);
        _set('wresp_err', 0);
        _set('wresp_exokay', 0);
      }
      if (wFire) {
        _beat++;
        if (wLast) _resp = true;
      }
      if (rFire) {
        if (_beat == _len) {
          _busy = false;
        } else {
          _beat++;
        }
      }
      if (bFire) {
        _resp = false;
        _busy = false;
      }
    }
  }
}
