import 'dart:async';

import 'package:rohd/rohd.dart';

/// A standard-mode SPI NOR model: 0x03 read, 0x06 WREN, 0x05 RDSR, 0x20
/// sector erase and 0x02 page program with a 3-byte address. WIP stays set
/// for [wipPolls] status reads after each erase or program. Every erase and
/// program goes in [log] as (opcode, address) when its frame ends.
class SpiNorModel {
  SpiNorModel({this.wipPolls = 3, this.stuckWip = false});

  final int wipPolls;

  /// WIP never clears, as on a dead part.
  final bool stuckWip;
  final storage = <int, int>{};
  final log = <(int, int)>[];
  bool wel = false;
  int wipCounter = 0;

  int _curByte = 0;
  int _bitsInByte = 0;
  final _cmdBytes = <int>[];
  int _cmd = 0;
  int _addr = 0;
  bool _servingStatus = false;
  int _statusByte = 0;
  int _eraseAddr = 0;
  final _programAddrs = <int>[];

  int read(int a) => storage[a] ?? 0xFF;

  void _begin() {
    _curByte = 0;
    _bitsInByte = 0;
    _cmdBytes.clear();
    _cmd = 0;
    _addr = 0;
    _servingStatus = false;
    _statusByte = 0;
  }

  void csFall() => _begin();

  void csRise() {
    if (_cmd == 0x20) log.add((0x20, _eraseAddr));
    if (_cmd == 0x02 && _programAddrs.isNotEmpty) {
      log.add((0x02, _programAddrs.first));
    }
    _programAddrs.clear();
    if (_cmd == 0x20 || _cmd == 0x02) wel = false;
    _begin();
  }

  /// The MISO bit to present at the rising edge number [idx] of a frame.
  int misoBitAt(int idx) {
    if (_servingStatus) {
      final d = idx - 8;
      if (d >= 0 && d < 8) return (_statusByte >> (7 - d)) & 1;
    }
    if (_cmd == 0x03 && _cmdBytes.length >= 4) {
      final n = idx - 32;
      if (n >= 0) return (read(_addr + (n ~/ 8)) >> (7 - n % 8)) & 1;
    }
    return 0;
  }

  void clkRise(int mosi) {
    if (_servingStatus) return;
    _curByte = ((_curByte << 1) | (mosi & 1)) & 0xFF;
    _bitsInByte++;
    if (_bitsInByte == 8) {
      _byteComplete(_curByte);
      _curByte = 0;
      _bitsInByte = 0;
    }
  }

  void _byteComplete(int b) {
    _cmdBytes.add(b);
    if (_cmdBytes.length == 1) {
      _cmd = b;
      if (_cmd == 0x06) {
        wel = true;
      } else if (_cmd == 0x05) {
        final wip = (wipCounter > 0 || stuckWip) ? 1 : 0;
        if (wipCounter > 0) wipCounter--;
        _statusByte = wip | (wel ? 2 : 0);
        _servingStatus = true;
      }
      return;
    }
    if (_cmd != 0x20 && _cmd != 0x02 && _cmd != 0x03) return;
    if (_cmdBytes.length <= 4) {
      _addr = (_addr << 8) | b;
      if (_cmd == 0x20 && _cmdBytes.length == 4 && wel) {
        final base = _addr & ~0xFFF;
        _eraseAddr = _addr;
        for (var i = 0; i < 4096; i++) {
          storage[base + i] = 0xFF;
        }
        wipCounter = wipPolls;
      }
      return;
    }
    if (_cmd == 0x02 && wel) {
      final a = _addr + _cmdBytes.length - 5;
      if (_programAddrs.isEmpty) _programAddrs.add(_addr);
      storage[a] = (storage[a] ?? 0xFF) & b;
      wipCounter = wipPolls;
    }
  }

  /// Drives MISO from the SPI pins until stop is called.
  SpiNorPins attach({
    required Logic clk,
    required Logic csN,
    required Logic spiClk,
    required Logic mosi,
    required Logic miso,
  }) => SpiNorPins._(this, clk, csN, spiClk, mosi, miso);
}

/// The pin side of a [SpiNorModel].
class SpiNorPins {
  SpiNorPins._(
    this.model,
    this.clk,
    this.csN,
    this.spiClk,
    this.mosi,
    this.miso,
  ) {
    _proc = _run();
  }

  final SpiNorModel model;
  final Logic clk, csN, spiClk, mosi, miso;
  bool _running = true;
  late final Future<void> _proc;

  Future<void> _run() async {
    var prevClk = 0;
    var prevCs = 1;
    var riseIdx = 0;
    while (_running) {
      await clk.nextPosedge;
      final cs = csN.value.isValid ? csN.value.toInt() : 1;
      final sc = spiClk.value.isValid ? spiClk.value.toInt() : 0;
      final dq0 = mosi.value.isValid ? mosi.value.toInt() : 0;
      if (cs == 0 && prevCs == 1) {
        model.csFall();
        riseIdx = 0;
      }
      if (cs == 1 && prevCs == 0) {
        model.csRise();
        riseIdx = 0;
      }
      if (cs == 0 && sc == 1 && prevClk == 0) {
        miso.inject(model.misoBitAt(riseIdx));
        model.clkRise(dq0);
        miso.inject(model.misoBitAt(riseIdx));
        riseIdx++;
      }
      prevClk = cs == 0 ? sc : 0;
      prevCs = cs;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _proc;
  }
}
