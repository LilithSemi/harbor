import 'dart:math';

import 'package:rohd/rohd.dart';

/// Byte memory on the `t_*` beat ports of a `MasterTop` built with
/// `withErr`, with random latency and error beats.
class PcieFabricMemory {
  final Module top;
  final Logic clk;
  final int busBytes;
  final int Function(int address) fill;
  final Random _random;
  final Map<int, int> bytes = {};

  /// Beat addresses that answer with an error.
  final Set<int> errorBeats = {};

  /// When set, write beats after this many get no answer.
  int? writeLimit;

  /// Write beats answered.
  int writeBeats = 0;
  final Logic _ack = Logic(name: 'tb_ack');
  final Logic _err = Logic(name: 'tb_err');
  final Logic _rdata;
  int _wait = -1;

  PcieFabricMemory(this.top, this.clk, {required int seed, required this.fill})
    : busBytes = top.output('t_wdata').width ~/ 8,
      _random = Random(seed),
      _rdata = Logic(name: 'tb_rdata', width: top.output('t_wdata').width) {
    top.input('t_ack').srcConnection! <= _ack;
    top.input('t_err').srcConnection! <= _err;
    top.input('t_rdata').srcConnection! <= _rdata;
  }

  int byte(int address) => bytes[address] ?? fill(address);

  void start() {
    _ack.inject(0);
    _err.inject(0);
    _rdata.inject(0);
    clk.negedge.listen((_) => _step());
  }

  void _step() {
    if (_ack.value.toBool()) {
      _ack.inject(0);
      _err.inject(0);
      return;
    }
    final stb = top.output('t_stb').value;
    if (!stb.isValid || !stb.toBool()) {
      _wait = -1;
      return;
    }
    final limit = writeLimit;
    if (limit != null &&
        writeBeats >= limit &&
        top.output('t_we').value.toBool()) {
      _wait = -1;
      return;
    }
    if (_wait < 0) _wait = _random.nextInt(3);
    if (_wait > 0) {
      _wait--;
      return;
    }
    _wait = -1;
    final base = top.output('t_addr').value.toInt() & ~(busBytes - 1);
    final fail = errorBeats.contains(base);
    if (top.output('t_we').value.toBool()) {
      writeBeats++;
      // Lanes with no strobe can hold X.
      final data = top.output('t_wdata').value;
      final sel = top.output('t_sel').value.toInt();
      for (var b = 0; b < busBytes && !fail; b++) {
        if ((sel >> b) & 1 == 1) {
          bytes[base + b] = data.getRange(8 * b, 8 * b + 8).toInt();
        }
      }
    } else {
      var data = BigInt.zero;
      for (var b = 0; b < busBytes; b++) {
        data |= BigInt.from(byte(base + b)) << (8 * b);
      }
      _rdata.inject(data);
    }
    _err.inject(fail ? 1 : 0);
    _ack.inject(1);
  }
}
