/// MDIO PHY model for Ethernet MAC tests.
library;

import 'package:rohd/rohd.dart';

/// One frame the model saw.
class EthMdioFrame {
  /// The 64 line values at the rising edges of MDC.
  final List<int> bits;
  EthMdioFrame(this.bits);

  int field(int from, int n) {
    var v = 0;
    for (var i = from; i < from + n; i++) {
      v = (v << 1) | bits[i];
    }
    return v;
  }

  int get st => field(32, 2);
  int get op => field(34, 2);
  int get phy => field(36, 5);
  int get reg => field(41, 5);
  int get ta => field(46, 2);
  int get data => field(48, 16);
}

/// A PHY on the MDIO line, clause 22 and clause 45.
///
/// It reads the line at each rising edge of MDC. The line is the master
/// value when `mdio_oe` is high, the model value when the model drives,
/// and 1 (the pull-up) else. For a read, the model drives TA bit 2 low and
/// the 16 data bits, each one after a rising edge.
class EthMdioPhy {
  final Logic mdc;
  final Logic mdioOut;
  final Logic mdioOe;

  /// Line value into the master `mdio_in`.
  final Logic mdioIn = Logic(name: 'phy_mdio_in');

  /// PHY address the model answers.
  final int address;

  /// Clause 22 registers.
  final Map<int, int> c22 = {};

  /// Clause 45 registers by (devad << 16) | address.
  final Map<int, int> c45 = {};

  /// Every frame with its 64 bits.
  final List<EthMdioFrame> frames = [];

  /// Rising edges where the master and the model both drive.
  int contention = 0;

  /// Rising edges where the master drives in a read data window.
  final List<int> masterInRead = [];

  final Map<int, int> _c45Addr = {};
  final List<int> _bits = [];
  int? _drive;
  int _ones = 0;
  bool _inFrame = false;
  List<int> _readOut = [];

  EthMdioPhy(this.mdc, this.mdioOut, this.mdioOe, {this.address = 3}) {
    mdioIn.inject(1);
  }

  /// Starts the model. Call after the module is built.
  void start() {
    mdc.posedge.listen((_) => _rise());
  }

  void _rise() {
    final oe = mdioOe.value.isValid && mdioOe.value.toBool();
    if (oe && _drive != null) contention++;
    final line = oe ? mdioOut.value.toInt() : (_drive ?? 1);
    if (!_inFrame) {
      if (line == 1) {
        _ones++;
      } else if (_ones >= 32) {
        _inFrame = true;
        _bits
          ..clear()
          ..addAll(List.filled(32, 1))
          ..add(0);
      } else {
        _ones = 0;
      }
      _setIn();
      return;
    }
    if (oe && _bits.length >= 46 && _readOut.isNotEmpty) {
      masterInRead.add(_bits.length);
    }
    _bits.add(line);
    final n = _bits.length;
    if (n == 46) _decode();
    if (_readOut.isNotEmpty) {
      // Drive the next bit: TA bit 2 (index 47), then the data.
      _drive = n >= 47 && n < 64 ? _readOut[n - 47] : null;
    }
    if (n == 64) {
      final f = EthMdioFrame(List.of(_bits));
      frames.add(f);
      _finish(f);
      _inFrame = false;
      _ones = 0;
      _readOut = [];
      _drive = null;
    }
    _setIn();
  }

  void _setIn() {
    final oe = mdioOe.value.isValid && mdioOe.value.toBool();
    mdioIn.inject(oe ? mdioOut.value : (_drive ?? 1));
  }

  int _f(int from, int n) => EthMdioFrame(_bits).field(from, n);

  void _decode() {
    final st = _f(32, 2);
    final op = _f(34, 2);
    final phy = _f(36, 5);
    final r = _f(41, 5);
    if (phy != address) return;
    int? value;
    if (st == 1 && op == 2) value = c22[r] ?? 0xffff;
    if (st == 0 && (op == 3 || op == 2)) {
      value = c45[(r << 16) | (_c45Addr[r] ?? 0)] ?? 0xffff;
    }
    if (value == null) return;
    _readOut = [0, for (var i = 15; i >= 0; i--) (value >> i) & 1];
  }

  void _finish(EthMdioFrame f) {
    if (f.phy != address) return;
    if (f.st == 1 && f.op == 1) c22[f.reg] = f.data;
    if (f.st == 0) {
      final key = f.reg;
      switch (f.op) {
        case 0:
          _c45Addr[key] = f.data;
        case 1:
          c45[(key << 16) | (_c45Addr[key] ?? 0)] = f.data;
        case 2:
          _c45Addr[key] = ((_c45Addr[key] ?? 0) + 1) & 0xffff;
      }
    }
  }
}
